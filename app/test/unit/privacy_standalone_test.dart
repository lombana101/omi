import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';
import 'package:omi/services/privacy_capture/privacy_standalone.dart';

void main() {
  test('privacy mode does not enter Omi sign-in', () {
    expect(selectPrivacyAppRoot(privacyMode: true, signedIn: false), PrivacyAppRoot.standalone);
    expect(selectPrivacyAppRoot(privacyMode: true, signedIn: true), PrivacyAppRoot.standalone);
    expect(selectPrivacyAppRoot(privacyMode: false, signedIn: false), PrivacyAppRoot.signedOut);
    expect(selectPrivacyAppRoot(privacyMode: false, signedIn: true), PrivacyAppRoot.signedIn);
  });

  testWidgets('standalone page shows off and the staging endpoint without a session', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PrivacyStandalonePage(findPendant: _noPendant)));
    expect(find.text('Recording: Off'), findsOneWidget);
    expect(find.text('Sign in (local dev)'), findsNothing);
    expect(find.textContaining('127.0.0.1'), findsNothing);
  });

  test('standalone navigation does not admit audio', () async {
    final ble = _Ble();
    final controller = PrivacyCaptureController(
      ble: ble,
      socket: _Socket(),
      credentials: _EmptyCredentials(),
      sink: _Sink(),
      onHaptic: (_) {},
      onState: (_) {},
    );
    await controller.start();
    expect(controller.state, PrivacyCaptureState.off);
    expect(controller.admissionOpen, isFalse);
    expect(ble.audioSubscribes, 0);
  });
}

Future<String> _noPendant() async => 'No pendant found';

class _EmptyCredentials implements PrivacyCredentialStore {
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
  var audioSubscribes = 0;
  @override
  Future<int> audioCodecId() async => 0;
  @override
  Future<bool> get isConnected async => true;
  @override
  Future<bool> maintainButtonNotifications({void Function(List<int> payload)? onButton}) async => true;
  @override
  Future<Stream<List<int>>> subscribeAudio() async {
    audioSubscribes++;
    return const Stream.empty();
  }

  @override
  Future<void> unsubscribeAudio() async {}
}

class _Socket implements PrivacySocketPort {
  @override
  Future<PrivacySocketSession> connect({required Uri url, required String authorizationHeader}) async {
    throw StateError('no session');
  }
}
