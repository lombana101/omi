import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';
import 'package:omi/services/privacy_capture/privacy_journal.dart';
import 'package:omi/services/privacy_capture/privacy_pcm16.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('local websocket fixture fails closed and persists before completion', () async {
    final dir = await Directory.systemTemp.createTemp('privacy-fixture');
    final store = await PrivacyStore.open(dir);
    await store.setRetention(PrivacyRetentionChoice.untilDeleted);
    final server = await _FixtureServer.bind();
    addTearDown(server.close);
    final ble = _Ble();
    final socket = _ClientSocket(server.uri);
    final controller = PrivacyCaptureController(
      ble: ble,
      socket: socket,
      credentials: _Creds(server.uri.toString(), 'fixture-token'),
      sink: _Sink(),
      onHaptic: (_) {},
      onState: (_) {},
      journal: PrivacyStoreJournal(store),
      now: () => DateTime.utc(2026, 10, 10, 12),
      newCaptureId: () => '11111111-1111-4111-8111-111111111111',
      requireConsentAssertion: true,
      ownerPurpose: 'self check',
    );
    controller.assertSelfOnly();
    server.arm();

    final start = controller.start();
    await server.startSeen.future.timeout(const Duration(seconds: 3));
    expect(controller.state, PrivacyCaptureState.authorizing);
    expect(ble.audioSubscribes, 0);
    expect(server.bytesBeforeAck, isEmpty);
    expect(server.sawStartBeforeAck, isTrue);

    server.ack();
    await start;
    expect(controller.state, PrivacyCaptureState.recording);
    expect(ble.audioSubscribes, 1);
    ble.audio.add(const [1, 0, 0, 9, 0]);
    await _until(() => server.bytesAfterAck.isNotEmpty);
    expect(server.bytesAfterAck, isNotEmpty);

    await controller.stop();
    expect(controller.admissionOpen, isFalse);
    expect(ble.audioUnsubscribes, greaterThan(0));
    server.finish(sequence: 1, text: 'I will send the draft');
    server.finish(sequence: 1, text: 'I will send the draft');
    await _until(() => controller.localTranscripts.isNotEmpty);
    expect(controller.localTranscripts, ['I will send the draft']);
    server.complete('transcribed');
    await _until(() => controller.state == PrivacyCaptureState.off);
    expect(controller.state, PrivacyCaptureState.off);
    final chunks = await store.chunks((await store.sessions()).single.localId);
    expect(chunks.single.machineText, 'I will send the draft');
    expect(chunks.single.origin, 'machine_transcription');
    expect(server.texts.any((item) => item.contains('fixture-token')), isFalse);
  });

  test('fixture rejects bad auth, mismatch, malformed, duplicate, and out of order', () async {
    final server = await _FixtureServer.bind(token: 'expected');
    addTearDown(server.close);
    final denied = PrivacyCaptureController(
      ble: _Ble(),
      socket: _ClientSocket(server.uri),
      credentials: _Creds(server.uri.toString(), 'wrong'),
      sink: _Sink(),
      onHaptic: (_) {},
      onState: (_) {},
    );
    await denied.start();
    expect(denied.state, PrivacyCaptureState.off);
    expect(denied.audioSubscriptionCount, 0);

    final mismatch = await _started(server);
    server.emit('{"type":"StartCaptureAck","version":1,"capture_id":"22222222-2222-4222-8222-222222222222"}');
    await mismatch.pending;
    expect(mismatch.controller.audioSubscriptionCount, 0);

    final bad = await _started(server);
    server.emit('{');
    await bad.pending;
    expect(bad.controller.state, PrivacyCaptureState.off);

    final ordered = await _recording(server);
    server.emit(jsonEncode({
      'type': 'TranscriptResult',
      'version': 1,
      'capture_id': '11111111-1111-4111-8111-111111111111',
      'sequence': 2,
      'text': 'too soon',
    }));
    await _until(() => ordered.controller.state == PrivacyCaptureState.error);
    expect(ordered.controller.state, PrivacyCaptureState.error);
    expect(ordered.controller.admissionOpen, isFalse);

    final duplicate = await _recording(server);
    final chunk = {
      'type': 'TranscriptResult',
      'version': 1,
      'capture_id': '11111111-1111-4111-8111-111111111111',
      'sequence': 1,
      'text': 'same line',
    };
    server.emit(jsonEncode(chunk));
    server.emit(jsonEncode(chunk));
    await _until(() => duplicate.controller.localTranscripts.isNotEmpty);
    expect(duplicate.controller.localTranscripts, ['same line']);
    server.emit(jsonEncode({...chunk, 'text': 'changed line'}));
    await _until(() => duplicate.controller.state == PrivacyCaptureState.error);
    expect(duplicate.controller.state, PrivacyCaptureState.error);
  });
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<_Live> _started(_FixtureServer server) async {
  final ble = _Ble();
  final controller = PrivacyCaptureController(
    ble: ble,
    socket: _ClientSocket(server.uri),
    credentials: _Creds(server.uri.toString(), 'expected'),
    sink: _Sink(),
    onHaptic: (_) {},
    onState: (_) {},
    newCaptureId: () => '11111111-1111-4111-8111-111111111111',
  );
  server.arm();
  final pending = controller.start();
  await server.startSeen.future.timeout(const Duration(seconds: 3));
  return _Live(controller, pending);
}

Future<_Live> _recording(_FixtureServer server) async {
  final live = await _started(server);
  server.ack();
  await live.pending;
  return live;
}

class _Live {
  _Live(this.controller, this.pending);
  final PrivacyCaptureController controller;
  final Future<void> pending;
}

class _Creds implements PrivacyCredentialStore {
  _Creds(this.url, this.token);
  final String url;
  final String token;
  @override
  Future<PrivacyCredentials?> read() async => PrivacyCredentials(url: url, bearerToken: token);
}

class _Sink implements PrivacyAudioSink {
  @override
  void admit(List<int> frame) {}
  @override
  void reject(List<int> frame) {}
}

class _Ble implements PrivacyBlePort {
  var audioSubscribes = 0;
  var audioUnsubscribes = 0;
  final audio = StreamController<List<int>>.broadcast();
  @override
  Future<int> audioCodecId() async => PrivacyPcm16.pcm16CodecId;
  @override
  Future<bool> get isConnected async => true;
  @override
  Future<bool> maintainButtonNotifications({void Function(List<int> payload)? onButton}) async => true;
  @override
  Future<Stream<List<int>>> subscribeAudio() async {
    audioSubscribes++;
    return audio.stream;
  }

  @override
  Future<void> unsubscribeAudio() async {
    audioUnsubscribes++;
  }
}

class _ClientSocket implements PrivacySocketPort {
  _ClientSocket(this.url);
  final Uri url;
  @override
  Future<PrivacySocketSession> connect({required Uri url, required String authorizationHeader}) async {
    final channel = IOWebSocketChannel.connect(url, headers: {'Authorization': authorizationHeader});
    await channel.ready;
    return _ClientSession(channel);
  }
}

class _ClientSession implements PrivacySocketSession {
  _ClientSession(this._channel) {
    _channel.stream.listen(_incoming.add,
        onError: (_) => _incoming.add(const PrivacySocketClosed(1008)),
        onDone: () {
          _incoming.add(PrivacySocketClosed(_channel.closeCode, reason: _channel.closeReason));
        });
  }
  final WebSocketChannel _channel;
  final _incoming = StreamController<Object?>.broadcast();
  @override
  Stream<Object?> get messages => _incoming.stream;
  @override
  void sendText(String text) => _channel.sink.add(text);
  @override
  void sendBytes(List<int> bytes) => _channel.sink.add(bytes);
  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
}

class _FixtureServer {
  _FixtureServer(this._server, this.uri, this.token);
  final HttpServer _server;
  final Uri uri;
  final String token;
  WebSocket? _socket;
  var sawStartBeforeAck = false;
  final bytesBeforeAck = <List<int>>[];
  final bytesAfterAck = <List<int>>[];
  final texts = <String>[];
  var _acked = false;
  var startSeen = Completer<void>();

  static Future<_FixtureServer> bind({String token = 'fixture-token'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _FixtureServer(server, Uri.parse('ws://127.0.0.1:${server.port}/live'), token);
    server.listen(fixture._handle);
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    final auth = request.headers.value('authorization');
    if (auth != 'Bearer $token') {
      request.response.statusCode = 401;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _socket = socket;
    socket.listen((event) {
      if (event is String) {
        texts.add(event);
        if (!_acked && event.contains('StartCapture')) {
          sawStartBeforeAck = true;
          if (!startSeen.isCompleted) startSeen.complete();
        }
      } else {
        (_acked ? bytesAfterAck : bytesBeforeAck).add(event is List<int> ? List<int>.from(event) : const [1]);
      }
    });
  }

  void arm() {
    startSeen = Completer<void>();
    _acked = false;
    sawStartBeforeAck = false;
    bytesBeforeAck.clear();
  }

  void ack() {
    _acked = true;
    _socket?.add(jsonEncode({
      'type': 'StartCaptureAck',
      'version': 1,
      'capture_id': '11111111-1111-4111-8111-111111111111',
    }));
  }

  void emit(String message) => _socket?.add(message);

  void finish({required int sequence, required String text}) {
    _socket?.add(jsonEncode({
      'type': 'TranscriptResult',
      'version': 1,
      'capture_id': '11111111-1111-4111-8111-111111111111',
      'sequence': sequence,
      'text': text,
    }));
  }

  void complete(String outcome) {
    _socket?.add(jsonEncode({
      'type': 'CaptureComplete',
      'version': 1,
      'capture_id': '11111111-1111-4111-8111-111111111111',
      'outcome': outcome,
    }));
  }

  Future<void> close() => _server.close(force: true);
}
