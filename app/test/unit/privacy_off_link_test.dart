import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';
import 'package:omi/services/privacy_capture/privacy_off_link.dart';

void main() {
  test('button events arrive while off and do not subscribe audio', () async {
    final ble = _Ble();
    final codes = <int>[];
    final diag = await armPrivacyOffLink(ble, onButton: codes.add);
    expect(diag.buttonSubscribed, isTrue);
    expect(diag.audioSubscribed, isFalse);
    expect(ble.audioSubscribes, 0);
    expect(ble.audioUnsubscribes, greaterThan(0));

    ble.emitButton(const [2, 0, 0, 0]);
    expect(codes, [2]);
    expect(ble.audioSubscribes, 0);
  });

  test('a button event cannot authorize audio without StartCaptureAck', () async {
    final ble = _Ble();
    final controller = PrivacyCaptureController(
      ble: ble,
      socket: _Socket(),
      credentials: _Empty(),
      sink: _Sink(),
      onHaptic: (_) {},
      onState: (_) {},
    );
    await armPrivacyOffLink(ble, onButton: (code) {
      if (code == 2) unawaited(controller.onDoubleTap());
    });
    ble.emitButton(const [2, 0, 0, 0]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, PrivacyCaptureState.off);
    expect(controller.admissionOpen, isFalse);
    expect(ble.audioSubscribes, 0);
    expect(privacyBlocksStockAudio(privacyMode: true, recordingAuthorized: false), isTrue);
    expect(privacyBlocksStockAudio(privacyMode: false, recordingAuthorized: false), isFalse);
    expect(decidePrivacyConnect(linkEstablished: false, name: 'Omi').armButton, isFalse);
    expect(decidePrivacyConnect(linkEstablished: false, name: 'Omi').label, 'Not connected');
    expect(decidePrivacyConnect(linkEstablished: true, name: 'Omi').armButton, isTrue);
  });
}

class _Empty implements PrivacyCredentialStore {
  @override
  Future<PrivacyCredentials?> read() async => null;
}

class _Sink implements PrivacyAudioSink {
  @override
  void admit(List<int> frame) {}
  @override
  void reject(List<int> frame) {}
}

class _Socket implements PrivacySocketPort {
  @override
  Future<PrivacySocketSession> connect({required Uri url, required String authorizationHeader}) async {
    throw StateError('no session');
  }
}

class _Ble implements PrivacyBlePort {
  var audioSubscribes = 0;
  var audioUnsubscribes = 0;
  void Function(List<int> payload)? _onButton;

  void emitButton(List<int> payload) => _onButton?.call(payload);

  @override
  Future<int> audioCodecId() async => 0;
  @override
  Future<bool> get isConnected async => true;
  @override
  Future<bool> maintainButtonNotifications({void Function(List<int> payload)? onButton}) async {
    _onButton = onButton;
    return true;
  }
  @override
  Future<Stream<List<int>>> subscribeAudio() async {
    audioSubscribes++;
    return const Stream.empty();
  }
  @override
  Future<void> unsubscribeAudio() async {
    audioUnsubscribes++;
  }
}
