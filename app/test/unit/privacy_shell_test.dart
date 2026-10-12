import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';
import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_shell.dart';

void main() {
  testWidgets('privacy shell state is textual, labeled, and survives large type', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(2)),
        child: MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: PrivacyShell(findPendant: _noPendant),
        ),
      ),
    );
    await tester.pump();
    expect(find.text(PrivacyCopy.recordingOff), findsOneWidget);
    expect(find.byKey(const Key('privacy_start')), findsOneWidget);
    expect(find.text(PrivacyCopy.start), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('consent assertion is required before a privacy start', () async {
    final controller = PrivacyCaptureController(
      ble: _Ble(),
      socket: _Socket(),
      credentials: _Creds(),
      sink: _Sink(),
      onHaptic: (_) {},
      onState: (_) {},
      requireConsentAssertion: true,
    );
    await controller.start();
    expect(controller.state, PrivacyCaptureState.off);
    expect(controller.audioSubscriptionCount, 0);
    controller.ownerPurpose = 'self check';
    controller.assertSelfOnly();
    await controller.onBackground();
    expect(controller.state, PrivacyCaptureState.off);
    expect(controller.recording, isFalse);
  });
}

Future<String> _noPendant() async => PrivacyCopy.notConnected;

class _Creds implements PrivacyCredentialStore {
  @override
  Future<PrivacyCredentials?> read() async => null;
}

class _Sink implements PrivacyAudioSink {
  @override
  void admit(List<int> frame) {}
  @override
  void reject(List<int> frame) {}
}

class _Ble implements PrivacyBlePort {
  @override
  Future<int> audioCodecId() async => 1;
  @override
  Future<bool> get isConnected async => false;
  @override
  Future<bool> maintainButtonNotifications({void Function(List<int> payload)? onButton}) async => true;
  @override
  Future<Stream<List<int>>> subscribeAudio() async => const Stream.empty();
  @override
  Future<void> unsubscribeAudio() async {}
}

class _Socket implements PrivacySocketPort {
  @override
  Future<PrivacySocketSession> connect({required Uri url, required String authorizationHeader}) {
    throw StateError('no network');
  }
}
