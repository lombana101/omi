import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:omi/services/devices/models.dart';
import 'package:omi/services/devices/connectors/device_connection.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/privacy_capture/privacy_capture_config.dart';
import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';
import 'package:omi/services/privacy_capture/privacy_capture_io.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_journal.dart';
import 'package:omi/services/privacy_capture/privacy_off_link.dart';
import 'package:omi/services/privacy_capture/privacy_pendant_battery.dart';
import 'package:omi/services/privacy_capture/privacy_quick_capture.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';

const privacyCaptureEnabled = bool.fromEnvironment('OMI_PRIVACY_CAPTURE', defaultValue: false);

class SecurePrivacyCredentialStore implements PrivacyCredentialStore {
  SecurePrivacyCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
              ),
            );

  static const urlKey = 'omi_privacy_ws_url';
  static const tokenKey = 'omi_privacy_bearer';

  final FlutterSecureStorage _storage;

  Future<void> write({required String url, required String bearerToken}) async {
    await _storage.write(key: urlKey, value: url);
    await _storage.write(key: tokenKey, value: bearerToken);
  }

  @override
  Future<PrivacyCredentials?> read() async {
    final url = await _storage.read(key: urlKey);
    final token = await _storage.read(key: tokenKey);
    if (url == null || token == null) return null;
    return PrivacyCredentials(url: url, bearerToken: token);
  }
}

void playPrivacyHaptic(PrivacyHaptic haptic) {
  switch (haptic) {
    case PrivacyHaptic.start:
      HapticFeedback.heavyImpact();
    case PrivacyHaptic.stop:
      HapticFeedback.lightImpact();
    case PrivacyHaptic.error:
      HapticFeedback.vibrate();
  }
}

class _LatestTransportBle implements PrivacyBlePort {
  DeviceTransport? transport;
  TransportPrivacyBle? _bound;

  TransportPrivacyBle? get _ble {
    final current = transport;
    if (current == null) return null;
    if (_bound?.transport != current) _bound = TransportPrivacyBle(current);
    return _bound;
  }

  @override
  Future<bool> get isConnected async => await _ble?.isConnected ?? false;

  void Function(List<int> payload)? onButton;

  @override
  Future<bool> maintainButtonNotifications({void Function(List<int> payload)? onButton}) async {
    if (onButton != null) this.onButton = onButton;
    final ble = _ble;
    if (ble == null) return false;
    return ble.maintainButtonNotifications(onButton: this.onButton);
  }

  @override
  Future<Stream<List<int>>> subscribeAudio() async {
    final ble = _ble;
    if (ble == null) return const Stream<List<int>>.empty();
    return ble.subscribeAudio();
  }

  @override
  Future<int> audioCodecId() async => await _ble?.audioCodecId() ?? -1;

  @override
  Future<void> unsubscribeAudio() async {
    await _ble?.unsubscribeAudio();
  }

  Future<void> playHaptic(PrivacyHaptic haptic) async {
    final current = transport;
    if (current == null) return;
    final level = switch (haptic) {
      PrivacyHaptic.start => 2,
      PrivacyHaptic.stop => 1,
      PrivacyHaptic.error => 3,
    };
    try {
      if (!await current.isConnected()) return;
      await current.writeCharacteristic(
        speakerDataStreamServiceUuid,
        speakerDataStreamCharacteristicUuid,
        [level],
      );
    } catch (_) {
      // Feedback must never weaken or delay the authorization gate.
    }
  }
}

/// Compile-time privacy build. Stock builds leave this unused.
class PrivacyCaptureHost {
  static final state = ValueNotifier<PrivacyCaptureState>(PrivacyCaptureState.off);
  static final transcriptTick = ValueNotifier<int>(0);
  static final diagnostics = ValueNotifier<PrivacyLinkDiagnostics>(
    const PrivacyLinkDiagnostics(buttonSubscribed: false, audioSubscribed: false),
  );
  static final quickSettings = ValueNotifier<QuickSelfCaptureSettings>(
    const QuickSelfCaptureSettings(),
  );
  static final quickMessage = ValueNotifier<String?>(null);
  static final pendantBattery = PrivacyPendantBatteryMonitor();
  static QuickSelfCapturePreferences quickPreferences = PrefsQuickSelfCapturePreferences();
  static final _ble = _LatestTransportBle();
  static final devices = DeviceService();
  static bool _devicesStarted = false;
  static PrivacyCaptureController? _controller;
  static PrivacyStore? store;
  static Future<void>? _ready;
  static bool get captureInitialized => privacyCaptureEnabled && _controller != null;

  static void startDeviceRuntime() {
    if (_devicesStarted) return;
    devices.start();
    _devicesStarted = true;
  }

  /// Stock builds return before any capture object is created.
  static Future<void> ensureReady() {
    if (!privacyCaptureEnabled) return Future<void>.value();
    return _ready ??= _open();
  }

  static String? bootError;

  static Future<void> _open() async {
    try {
      quickSettings.value = await quickPreferences.load();
      quickMessage.value = null;
    } catch (_) {
      quickSettings.value = const QuickSelfCaptureSettings();
      quickMessage.value = PrivacyCopy.quickNeedsConfiguration;
    }
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/privacy_v1');
      store = await PrivacyStore.open(dir, protect: PrivacyFileProtection.protect);
      await store!.recoverLaunch(DateTime.now());
      await store!.expireDue(DateTime.now());
      final live = controller;
      live.requireConsentAssertion = true;
      live.journal = PrivacyStoreJournal(store!);
      await live.onAppStart();
      bootError = null;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Privacy store startup failed: ${error.runtimeType}');
      }
      store = null;
      bootError = PrivacyCopy.storeUnavailable;
    }
  }

  static PrivacyCaptureController get controller {
    if (!privacyCaptureEnabled) {
      throw StateError('privacy capture is not enabled');
    }
    return _controller ??= PrivacyCaptureController(
      ble: _ble,
      socket: IoPrivacySocket(),
      credentials: SecurePrivacyCredentialStore(),
      sink: const DroppingAudioSink(),
      onHaptic: (haptic) {
        playPrivacyHaptic(haptic);
        unawaited(_ble.playHaptic(haptic));
      },
      onState: (next) {
        state.value = next;
        final current = diagnostics.value;
        diagnostics.value = PrivacyLinkDiagnostics(
          buttonSubscribed: current.buttonSubscribed,
          audioSubscribed: next == PrivacyCaptureState.recording,
          lastButtonCode: current.lastButtonCode,
        );
      },
      onTrace: () => transcriptTick.value++,
      decodeOpus: decodePendantOpus,
      requireConsentAssertion: true,
    );
  }

  static Future<void> updateQuickSettings(QuickSelfCaptureSettings settings) async {
    await quickPreferences.save(settings);
    final live = _controller;
    if (!settings.enabled &&
        live != null &&
        live.captureOrigin == PrivacyCaptureConfig.pendantQuickCaptureOrigin &&
        live.state != PrivacyCaptureState.off) {
      await live.onBackground();
    }
    quickSettings.value = settings;
    quickMessage.value = null;
  }

  static Future<void> onDoubleTap(Future<DeviceTransport?> Function() lookup) async {
    if (!privacyCaptureEnabled) return;
    await ensureReady();
    await _handlePendantDoubleTap(lookup: lookup);
  }

  static Future<void> _handlePendantDoubleTap({
    Future<DeviceTransport?> Function()? lookup,
  }) async {
    final live = controller;
    if (live.state == PrivacyCaptureState.recording ||
        live.state == PrivacyCaptureState.authorizing ||
        live.state == PrivacyCaptureState.finalizing) {
      await live.onDoubleTap();
      return;
    }

    final settings = quickSettings.value;
    if (!settings.ready || store == null || bootError != null) {
      quickMessage.value = PrivacyCopy.quickNeedsConfiguration;
      await live.onDoubleTap();
      return;
    }

    if (lookup != null) _ble.transport = await lookup();
    await live.onDoubleTap(
      quickCapture: QuickSelfCaptureIntent(
        purpose: settings.purpose!,
        retention: settings.retention!,
        assertedAt: DateTime.now(),
      ),
    );
  }

  static Future<void> armConnectedLink(DeviceTransport? transport, {required String deviceId}) async {
    if (transport != null) _ble.transport = transport;
    try {
      if (deviceId.isNotEmpty) await BleHostApi().setCaptureAuthorized(deviceId, false);
    } catch (_) {}
    final link = await armPrivacyOffLink(_ble, onButton: (code) {
      diagnostics.value = PrivacyLinkDiagnostics(
        buttonSubscribed: true,
        audioSubscribed: controller.state == PrivacyCaptureState.recording,
        lastButtonCode: code,
      );
      if (code == 2) unawaited(_handlePendantDoubleTap());
    });
    diagnostics.value = link;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('privacy_ble_diag', jsonEncode(link.toJson()));
    } catch (_) {}
    if (controller.state != PrivacyCaptureState.off) {
      await controller.onReconnect();
      await armPrivacyOffLink(_ble, onButton: (code) {
        if (code == 2) unawaited(_handlePendantDoubleTap());
      });
    }
  }

  static Future<void> observePendantBattery(DeviceConnection connection) async {
    await pendantBattery.bind(connection);
  }

  static Future<void> ensureAudioOff(DeviceTransport? transport) async {
    if (transport != null) _ble.transport = transport;
    final live =
        _controller?.state == PrivacyCaptureState.recording || _controller?.state == PrivacyCaptureState.authorizing;
    if (live) return;
    await _ble.unsubscribeAudio();
    await _ble.maintainButtonNotifications();
    final current = diagnostics.value;
    diagnostics.value = PrivacyLinkDiagnostics(
      buttonSubscribed: current.buttonSubscribed,
      audioSubscribed: false,
      lastButtonCode: current.lastButtonCode,
    );
  }
}
