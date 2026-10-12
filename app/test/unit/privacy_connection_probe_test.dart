import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/privacy_capture/privacy_capture_config.dart';
import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';
import 'package:omi/services/privacy_capture/privacy_connection_probe.dart';

void main() {
  const token = 'staging-bearer-secret';

  test('upgrade success closes without StartCapture or audio', () async {
    final socket = _Socket();
    final outcome = await probePrivacyConnection(
      credentials: _Store(PrivacyCaptureConfig.stagingLiveUrl, token),
      connect: socket.connect,
    );
    expect(outcome.result, PrivacyProbeResult.authenticated);
    expect(outcome.label, isNot(contains(token)));
    expect(socket.authorization, 'Bearer $token');
    expect(socket.texts, isEmpty);
    expect(socket.bytes, isEmpty);
    expect(socket.closed, isTrue);
    expect(socket.url.toString(), PrivacyCaptureConfig.stagingLiveUrl);
  });

  test('authentication and network failures stay distinct and closed', () async {
    final auth = await probePrivacyConnection(
      credentials: _Store(PrivacyCaptureConfig.stagingLiveUrl, token),
      connect: ({required url, required authorizationHeader}) async {
        throw Exception('WebSocketException: HTTP status code: 401');
      },
    );
    expect(auth.result, PrivacyProbeResult.authenticationFailed);
    expect(auth.label, isNot(contains(token)));

    final network = await probePrivacyConnection(
      credentials: _Store(PrivacyCaptureConfig.stagingLiveUrl, token),
      connect: ({required url, required authorizationHeader}) async {
        throw Exception('SocketException: Connection refused');
      },
    );
    expect(network.result, PrivacyProbeResult.networkFailed);
    expect(network.label, isNot(contains(token)));

    final missing = await probePrivacyConnection(
      credentials: _Store(PrivacyCaptureConfig.stagingLiveUrl, ''),
      connect: ({required url, required authorizationHeader}) async => throw StateError('should not connect'),
    );
    expect(missing.result, PrivacyProbeResult.notConfigured);
  });
}

class _Store implements PrivacyCredentialStore {
  _Store(this.url, this.token);
  final String url;
  final String token;
  @override
  Future<PrivacyCredentials?> read() async => PrivacyCredentials(url: url, bearerToken: token);
}

class _Socket {
  Uri? url;
  String? authorization;
  final texts = <String>[];
  final bytes = <List<int>>[];
  var closed = false;

  Future<PrivacySocketSession> connect({required Uri url, required String authorizationHeader}) async {
    this.url = url;
    authorization = authorizationHeader;
    return _Session(this);
  }
}

class _Session implements PrivacySocketSession {
  _Session(this.socket);
  final _Socket socket;
  @override
  Stream<Object?> get messages => const Stream.empty();
  @override
  void sendText(String text) => socket.texts.add(text);
  @override
  void sendBytes(List<int> bytes) => socket.bytes.add(bytes);
  @override
  Future<void> close() async {
    socket.closed = true;
  }
}
