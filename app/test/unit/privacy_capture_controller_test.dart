import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/privacy_capture/privacy_capture_config.dart';
import 'package:omi/services/privacy_capture/privacy_pcm16.dart';
import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';

void main() {
  test('recording stays off and audio stays unsubscribed until StartCaptureAck', () async {
    final harness = _Harness();
    await harness.controller.onAppStart();

    expect(harness.controller.state, PrivacyCaptureState.off);
    expect(harness.ble.audioSubscribes, 0);
    expect(harness.ble.audioUnsubscribes, greaterThan(0));
    expect(harness.ble.buttonSubscribes, greaterThan(0));
    expect(harness.socket.connects, 0);

    final start = harness.controller.onDoubleTap();
    await harness.pump();
    expect(harness.controller.state, PrivacyCaptureState.authorizing);
    expect(harness.ble.audioSubscribes, 0);
    expect(harness.socket.authorization, 'Bearer secret-token');
    expect(harness.socket.url.toString(), 'wss://stt.home.internal/live');

    final sent = jsonDecode(harness.socket.texts.single) as Map<String, dynamic>;
    expect(sent.keys.toList(), PrivacyCaptureConfig.startCaptureFields);
    expect(sent['type'], 'StartCapture');
    expect(sent['version'], 1);
    expect(sent['purpose'], 'personal_memory');
    expect(sent['consent_basis'], 'self_only');
    expect(sent['policy_revision'], 1);
    expect(sent['capture_id'], '11111111-1111-4111-8111-111111111111');
    expect(sent['client_timestamp'], '2026-10-09T12:00:00Z');

    harness.ble.audio.add(const [1, 2, 3]);
    await harness.pump();
    expect(harness.sink.admitted, isEmpty);
    expect(harness.socket.bytes, isEmpty);

    harness.socket.emit(jsonEncode({
      'type': 'StartCaptureAck',
      'version': 1,
      'capture_id': sent['capture_id'],
      'authorized_at': '2026-10-09T12:00:01Z',
    }));
    await start;
    expect(harness.controller.state, PrivacyCaptureState.recording);
    expect(harness.ble.audioSubscribes, 1);
    expect(harness.haptics, [PrivacyHaptic.start]);

    harness.ble.audio.add(const [1, 0, 0, 9, 0]);
    await harness.pump();
    expect(harness.sink.admitted, [
      [9, 0]
    ]);
    expect(harness.socket.bytes, [
      [9, 0]
    ]);
  });

  test('stop, failure, reconnect, and restart do not resume or retain audio', () async {
    final harness = _Harness();
    final start = harness.controller.start();
    await harness.pump();
    harness.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"11111111-1111-4111-8111-111111111111"}');
    await start;
    harness.ble.audio.add(const [1, 0, 0, 4, 0]);
    await harness.pump();
    harness.controller.closeAdmissionForTesting();
    harness.ble.audio.add(const [1, 0, 0, 8, 0]);
    await harness.pump();
    expect(harness.sink.rejected, [
      [1, 0, 0, 8, 0]
    ]);
    expect(harness.socket.bytes, [
      [4, 0]
    ]);

    await harness.controller.stop();
    harness.ble.audio.add(const [5]);
    await harness.pump();
    expect(harness.controller.state, PrivacyCaptureState.finalizing);
    expect(harness.controller.admissionOpen, isFalse);
    expect(harness.socket.closed, isFalse);
    expect(jsonDecode(harness.socket.texts.last)['type'], 'CloseStream');
    harness.socket.emit(jsonEncode({
      'type': 'CaptureComplete',
      'version': 1,
      'capture_id': '11111111-1111-4111-8111-111111111111',
      'outcome': 'no_speech',
    }));
    await harness.pump();
    expect(harness.controller.state, PrivacyCaptureState.off);
    expect(harness.controller.admissionOpen, isFalse);
    expect(harness.sink.admitted, [
      [4, 0]
    ]);
    expect(harness.socket.bytes, [
      [4, 0]
    ]);
    expect(harness.haptics, contains(PrivacyHaptic.stop));
    expect(harness.socket.closed, isTrue);
    expect(harness.ble.audioSubscribes, 1);

    await harness.controller.onReconnect();
    expect(harness.controller.recording, isFalse);
    expect(harness.socket.connects, 1);
    expect(harness.ble.buttonSubscribes, greaterThan(0));

    final restarted = _Harness(credentials: harness.credentials);
    await restarted.controller.onAppStart();
    expect(restarted.controller.state, PrivacyCaptureState.off);
    expect(restarted.socket.connects, 0);
    expect(restarted.ble.audioSubscribes, 0);
  });

  test('policy violations never subscribe or forward audio', () async {
    final closed = _Harness();
    final attempt = closed.controller.start();
    await closed.pump();
    closed.socket.emit(const PrivacySocketClosed(1008));
    await attempt;
    expect(closed.controller.state, PrivacyCaptureState.off);
    expect(closed.controller.admissionOpen, isFalse);
    expect(closed.ble.audioSubscribes, 0);
    expect(closed.sink.admitted, isEmpty);
    expect(closed.haptics.last, PrivacyHaptic.error);

    final mismatch = _Harness();
    final other = mismatch.controller.start();
    await mismatch.pump();
    mismatch.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"other"}');
    await other;
    expect(mismatch.controller.state, PrivacyCaptureState.off);
    expect(mismatch.controller.admissionOpen, isFalse);
    expect(mismatch.ble.audioSubscribes, 0);

    final remote = _Harness(credentials: _MemoryCredentials('ws://203.0.113.8:8766/live', 'secret-token'));
    await remote.controller.start();
    expect(remote.socket.connects, 0);
    expect(remote.ble.audioSubscribes, 0);

    final enrollment = _Harness(purpose: 'self_voice_enrollment');
    enrollment.controller.armParticipantsConsented(consentObtained: true);
    await enrollment.controller.start();
    expect(enrollment.socket.connects, 0);

    final consented = _Harness();
    consented.controller.armParticipantsConsented(consentObtained: true);
    final consentedStart = consented.controller.start();
    await consented.pump();
    expect(jsonDecode(consented.socket.texts.single)['consent_basis'], 'participants_consented');
    consented.socket.emit(const PrivacySocketClosed(1008));
    await consentedStart;
    expect(consented.controller.consentBasis, 'self_only');
    expect(consented.controller.participantsConsentArmed, isFalse);
  });

  test('StartCaptureAck uses UUID identity and ignores optional metadata', () async {
    const id = '11111111-1111-4111-8111-111111111111';
    Future<void> expectAdmitted(Map<String, Object?> ack) async {
      final harness = _Harness();
      final start = harness.controller.start();
      await harness.pump();
      harness.socket.emit(jsonEncode(ack));
      await start;
      expect(harness.controller.state, PrivacyCaptureState.recording);
      expect(harness.ble.audioSubscribes, 1);
    }

    Future<void> expectRejected(Map<String, Object?> ack) async {
      final harness = _Harness();
      final start = harness.controller.start();
      await harness.pump();
      harness.socket.emit(jsonEncode(ack));
      await start;
      expect(harness.controller.state, PrivacyCaptureState.off);
      expect(harness.controller.admissionOpen, isFalse);
      expect(harness.ble.audioSubscribes, 0);
      expect(harness.sink.admitted, isEmpty);
    }

    await expectAdmitted({
      'type': 'StartCaptureAck',
      'version': 1,
      'capture_id': id,
      'authorized_at': '2026-10-09T12:00:01Z',
    });
    await expectAdmitted({
      'type': 'StartCaptureAck',
      'version': 1,
      'capture_id': id.toUpperCase(),
    });
    await expectAdmitted({
      'type': 'StartCaptureAck',
      'version': 1,
      'capture_id': id,
      'authorized_at': '2026-10-09T12:00:01Z',
      'session': 'ignored',
    });
    await expectRejected({
      'type': 'StartCaptureAck',
      'version': 1,
      'capture_id': '22222222-2222-4222-8222-222222222222',
      'authorized_at': '2026-10-09T12:00:01Z',
    });
    await expectRejected({
      'version': 1,
      'capture_id': id,
      'authorized_at': '2026-10-09T12:00:01Z',
    });
    await expectRejected({
      'type': 'StartCaptureAck',
      'capture_id': id,
      'authorized_at': '2026-10-09T12:00:01Z',
    });
    await expectRejected({
      'type': 'StartCaptureAck',
      'version': 1,
      'authorized_at': '2026-10-09T12:00:01Z',
    });
    await expectRejected({
      'type': 'CaptureStarted',
      'version': 1,
      'capture_id': id,
    });
    await expectRejected({
      'type': 'StartCaptureAck',
      'version': 2,
      'capture_id': id,
    });
  });

  test('staging audio is 16 kHz mono PCM16 LE and sessions close', () async {
    final uri = Uri.parse(PrivacyCaptureConfig.stagingLiveUrl);
    expect(uri.scheme, 'wss');
    expect(uri.path, '/live');
    expect(uri.port, 8443);
    expect(PrivacyPcm16.encode(const [1, 2, 3, 128], codecId: PrivacyPcm16.pcm8CodecId), [0, 0, 0, 0]);

    final pcm = _Harness(credentials: _MemoryCredentials(PrivacyCaptureConfig.stagingLiveUrl, 'secret-token'));
    final start = pcm.controller.start();
    await pcm.pump();
    pcm.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"11111111-1111-4111-8111-111111111111","authorized_at":"2026-10-09T12:00:01Z"}');
    await start;
    expect(pcm.socket.url.toString(), PrivacyCaptureConfig.stagingLiveUrl);
    pcm.ble.audio.add(const [9, 9, 9]);
    await pcm.pump();
    expect(pcm.socket.bytes, isEmpty);
    pcm.ble.audio.add(const [1, 2, 3, 0x34, 0x12, 0xff, 0xff]);
    await pcm.pump();
    expect(pcm.socket.bytes.single, [0x34, 0x12, 0xff, 0xff]);
    await pcm.controller.stop();
    expect(pcm.socket.closed, isFalse);
    expect(pcm.controller.state, PrivacyCaptureState.finalizing);
    pcm.socket.emit(jsonEncode({
      'type': 'CaptureComplete',
      'version': 1,
      'capture_id': '11111111-1111-4111-8111-111111111111',
      'outcome': 'no_speech',
    }));
    await pcm.pump();
    expect(pcm.socket.closed, isTrue);
    expect(pcm.controller.state, PrivacyCaptureState.off);

    final opus = _Harness(codecId: PrivacyPcm16.opusFs320CodecId, decodeOpus: (_) => [1, -1]);
    final opusStart = opus.controller.start();
    await opus.pump();
    opus.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"11111111-1111-4111-8111-111111111111"}');
    await opusStart;
    opus.ble.audio.add(const [0, 0, 0, 1, 2, 3]);
    await opus.pump();
    expect(opus.socket.bytes.single, [1, 0, 0xff, 0xff]);

    final unknown = _Harness(codecId: 99);
    final denied = unknown.controller.start();
    await unknown.pump();
    unknown.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"11111111-1111-4111-8111-111111111111"}');
    await denied;
    expect(unknown.ble.audioSubscribes, 0);
    expect(unknown.controller.state, PrivacyCaptureState.off);
  });

  test('finalization keeps the socket open until CaptureComplete', () async {
    expect(const PrivacyCaptureConfig().finalizationTimeout, const Duration(seconds: 55));
    final harness = _Harness();
    final start = harness.controller.start();
    await harness.pump();
    const id = '11111111-1111-4111-8111-111111111111';
    harness.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"$id"}');
    await start;
    final subscribes = harness.ble.audioSubscribes;

    await harness.controller.stop();
    await harness.controller.stop();
    harness.ble.audio.add(const [1, 0, 9, 0]);
    await harness.pump();
    final close = harness.socket.texts.where((text) => jsonDecode(text)['type'] == 'CloseStream').toList();
    expect(close, hasLength(1));
    expect(jsonDecode(close.single), {'type': 'CloseStream', 'version': 1, 'capture_id': id});
    expect(harness.socket.closed, isFalse);
    expect(harness.controller.state, PrivacyCaptureState.finalizing);
    expect(harness.controller.admissionOpen, isFalse);
    expect(harness.socket.bytes, isEmpty);
    expect(harness.ble.audioSubscribes, subscribes);

    harness.socket.emit(jsonEncode({
      'type': 'CaptureFinalizing',
      'version': 1,
      'capture_id': id,
      'accepted_pcm_bytes': 4,
    }));
    await harness.pump();
    expect(harness.socket.closed, isFalse);
    expect(harness.controller.state, PrivacyCaptureState.finalizing);

    harness.socket.emit(jsonEncode({
      'type': 'TranscriptResult',
      'version': 1,
      'capture_id': id.toUpperCase(),
      'text': 'local only',
      'is_final': true,
    }));
    await harness.pump();
    expect(harness.socket.closed, isFalse);
    expect(harness.controller.localTranscripts, ['local only']);
    expect(harness.socket.connects, 1);

    harness.socket.emit(jsonEncode({
      'type': 'CaptureComplete',
      'version': 1,
      'capture_id': id,
      'outcome': 'transcribed',
    }));
    await harness.pump();
    expect(harness.controller.state, PrivacyCaptureState.off);
    expect(harness.controller.lastOutcome, 'transcribed');
    expect(harness.socket.closed, isTrue);
    expect(harness.socket.connects, 1);
    expect(harness.ble.audioSubscribes, subscribes);

    harness.socket.emit(jsonEncode({
      'type': 'StartCaptureAck',
      'version': 1,
      'capture_id': id,
    }));
    await harness.pump();
    expect(harness.controller.admissionOpen, isFalse);
    expect(harness.ble.audioSubscribes, subscribes);
  });

  test('finalization failures do not resume or admit audio', () async {
    const id = '11111111-1111-4111-8111-111111111111';

    Future<void> finish(String outcome) async {
      final harness = _Harness();
      final start = harness.controller.start();
      await harness.pump();
      harness.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"$id"}');
      await start;
      await harness.controller.stop();
      harness.socket.emit(jsonEncode({
        'type': 'CaptureComplete',
        'version': 1,
        'capture_id': id,
        'outcome': outcome,
      }));
      await harness.pump();
      expect(
        harness.controller.state,
        outcome == 'no_speech' ? PrivacyCaptureState.off : PrivacyCaptureState.error,
      );
      expect(harness.controller.lastOutcome, outcome);
      expect(harness.controller.recording, isFalse);
      expect(harness.socket.connects, 1);
      expect(harness.ble.audioSubscribes, 1);
    }

    await finish('no_speech');
    await finish('processing_failed');
    await finish('delivery_failed');

    final dropped = _Harness();
    final droppedStart = dropped.controller.start();
    await dropped.pump();
    dropped.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"$id"}');
    await droppedStart;
    await dropped.controller.stop();
    dropped.socket.emit(const PrivacySocketClosed(1011));
    await dropped.pump();
    expect(dropped.controller.state, PrivacyCaptureState.error);
    expect(dropped.controller.admissionOpen, isFalse);
    expect(dropped.socket.connects, 1);
    expect(dropped.ble.audioSubscribes, 1);

    final malformed = _Harness();
    final malformedStart = malformed.controller.start();
    await malformed.pump();
    malformed.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"$id"}');
    await malformedStart;
    await malformed.controller.stop();
    malformed.socket.emit('{');
    await malformed.pump();
    expect(malformed.controller.state, PrivacyCaptureState.error);
    expect(malformed.ble.audioSubscribes, 1);
    expect(malformed.socket.closed, isTrue);

    final mismatch = _Harness();
    final mismatchStart = mismatch.controller.start();
    await mismatch.pump();
    mismatch.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"$id"}');
    await mismatchStart;
    await mismatch.controller.stop();
    mismatch.socket.emit(jsonEncode({
      'type': 'CaptureComplete',
      'version': 1,
      'capture_id': '22222222-2222-4222-8222-222222222222',
      'outcome': 'transcribed',
    }));
    await mismatch.pump();
    expect(mismatch.controller.state, PrivacyCaptureState.error);
    expect(mismatch.controller.admissionOpen, isFalse);
    expect(mismatch.ble.audioSubscribes, 1);
    expect(mismatch.controller.localTranscripts, isEmpty);

    final timedOut = _Harness();
    final timedStart = timedOut.controller.start();
    await timedOut.pump();
    timedOut.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"$id"}');
    await timedStart;
    await timedOut.controller.stop();
    timedOut.controller.expireFinalizationForTesting();
    await timedOut.pump();
    expect(timedOut.controller.lastOutcome, 'timeout');
    expect(timedOut.controller.state, PrivacyCaptureState.error);
    expect(timedOut.socket.closed, isTrue);
    expect(timedOut.socket.connects, 1);
    expect(timedOut.ble.audioSubscribes, 1);
  });

  test('protocol transcript survives completion and close', () async {
    const id = '11111111-1111-4111-8111-111111111111';
    Map<String, Object?> result(int sequence, String text) => {
          'type': 'TranscriptResult',
          'version': 1,
          'capture_id': id,
          'sequence': sequence,
          'text': text,
          'segments': [
            {'text': text, 'start': 0.1, 'end': 1.2}
          ],
        };

    final harness = _Harness();
    final start = harness.controller.start();
    await harness.pump();
    harness.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"$id"}');
    await start;
    await harness.controller.stop();
    harness.socket.emit(jsonEncode(result(1, 'first utterance')));
    harness.socket.emit(jsonEncode(result(2, 'second utterance')));
    harness.socket.emit(jsonEncode({
      'type': 'CaptureComplete',
      'version': 1,
      'capture_id': id,
      'outcome': 'transcribed',
      'transcript_results': 2,
      'error': null,
    }));
    harness.socket.emit(const PrivacySocketClosed(1000, reason: 'success'));
    harness.socket.emit(jsonEncode(result(3, 'late')));
    await harness.pump();
    await harness.pump();

    expect(harness.controller.state, PrivacyCaptureState.off);
    expect(harness.controller.lastOutcome, 'transcribed');
    expect(harness.controller.localTranscripts, ['first utterance', 'second utterance']);
    expect(harness.controller.transcripts.map((item) => item.captureId), [id, id]);
    expect(harness.controller.recording, isFalse);
    expect(harness.socket.connects, 1);
    expect(harness.ble.audioSubscribes, 1);
    expect(harness.controller.traces.any((item) => item.type == 'TranscriptResult' && item.decoded && item.captureIdMatched), isTrue);
    expect(harness.controller.traces.any((item) => item.type == 'socket_close' && item.closeCode == 1000), isTrue);
  });

  test('transport loss fails closed and stays distinct from success', () async {
    const id = '11111111-1111-4111-8111-111111111111';
    expect(PrivacyCaptureConfig.socketPingInterval, const Duration(seconds: 20));

    Future<_Harness> recording() async {
      final harness = _Harness();
      final start = harness.controller.start();
      await harness.pump();
      harness.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"$id"}');
      await start;
      return harness;
    }

    final closed = await recording();
    closed.socket.emit(jsonEncode({
      'type': 'TranscriptResult',
      'version': 1,
      'capture_id': id,
      'sequence': 1,
      'text': 'partial',
    }));
    await closed.pump();
    closed.socket.emit(const PrivacySocketClosed(1006));
    await closed.pump();
    expect(closed.controller.state, PrivacyCaptureState.error);
    expect(closed.controller.incomplete, isTrue);
    expect(closed.controller.lastOutcome, isNot('transcribed'));
    expect(closed.controller.localTranscripts, ['partial']);
    expect(closed.controller.admissionOpen, isFalse);
    expect(closed.socket.connects, 1);
    expect(privacyCaptureStatusLabel(state: closed.controller.state, incomplete: true), 'Recording interrupted');
    expect(
      privacyCaptureStatusLabel(state: PrivacyCaptureState.off, lastOutcome: 'transcribed'),
      'Completed',
    );
    expect(privacyCaptureStatusLabel(state: PrivacyCaptureState.off), 'Recording: Off');

    await closed.controller.onReconnect();
    expect(closed.controller.recording, isFalse);
    expect(closed.socket.connects, 1);

    final send = await recording();
    send.socket.failSend = true;
    send.ble.audio.add(const [1, 0, 0, 9, 0]);
    await send.pump();
    await send.pump();
    expect(send.controller.state, PrivacyCaptureState.error);
    expect(send.controller.lastOutcome, isNot('transcribed'));
    expect(send.socket.connects, 1);

    final audioError = await recording();
    audioError.ble.audio.addError(StateError('ble'));
    await audioError.pump();
    expect(audioError.controller.state, PrivacyCaptureState.error);
    expect(audioError.controller.admissionOpen, isFalse);
    expect(audioError.ble.audioSubscribes, 1);

    final audioDone = await recording();
    await audioDone.ble.audio.close();
    await audioDone.pump();
    expect(audioDone.controller.state, PrivacyCaptureState.error);
    expect(audioDone.socket.connects, 1);

    final raced = _Harness();
    final first = raced.controller.start();
    final second = raced.controller.start();
    await raced.pump();
    raced.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"$id"}');
    await Future.wait([first, second]);
    expect(raced.socket.connects, 1);

    final taps = _Harness();
    final tapA = taps.controller.onDoubleTap();
    final tapB = taps.controller.onDoubleTap();
    await taps.pump();
    taps.socket.emit('{"type":"StartCaptureAck","version":1,"capture_id":"$id"}');
    await Future.wait([tapA, tapB]);
    expect(taps.socket.connects, 1);
    expect(taps.controller.state, PrivacyCaptureState.recording);
    await taps.controller.onDoubleTap();
    expect(taps.controller.state, PrivacyCaptureState.finalizing);
    await taps.controller.onDoubleTap();
    expect(taps.socket.connects, 1);
    expect(taps.controller.state, PrivacyCaptureState.finalizing);
  });
}

class _MemoryCredentials implements PrivacyCredentialStore {
  _MemoryCredentials(this.url, this.token);
  final String url;
  final String token;
  @override
  Future<PrivacyCredentials?> read() async => PrivacyCredentials(url: url, bearerToken: token);
}

class _RecordingSink implements PrivacyAudioSink {
  final admitted = <List<int>>[];
  final rejected = <List<int>>[];
  @override
  void admit(List<int> frame) => admitted.add(List<int>.from(frame));
  @override
  void reject(List<int> frame) => rejected.add(List<int>.from(frame));
}

class _FakeBle implements PrivacyBlePort {
  _FakeBle({this.codecId = PrivacyPcm16.pcm16CodecId});
  final int codecId;
  var connected = true;
  var buttonSubscribes = 0;
  var audioSubscribes = 0;
  var audioUnsubscribes = 0;
  final audio = StreamController<List<int>>.broadcast();

  @override
  Future<bool> get isConnected async => connected;

  @override
  Future<bool> maintainButtonNotifications({void Function(List<int> payload)? onButton}) async {
    buttonSubscribes++;
    return true;
  }

  @override
  Future<int> audioCodecId() async => codecId;

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

class _FakeSocket implements PrivacySocketPort {
  Uri? url;
  String? authorization;
  var connects = 0;
  var failSend = false;
  final texts = <String>[];
  final bytes = <List<int>>[];
  var closed = false;
  final _messages = StreamController<Object?>.broadcast();

  void emit(Object? message) => _messages.add(message);

  @override
  Future<PrivacySocketSession> connect({required Uri url, required String authorizationHeader}) async {
    connects++;
    this.url = url;
    authorization = authorizationHeader;
    return _FakeSession(this);
  }
}

class _FakeSession implements PrivacySocketSession {
  _FakeSession(this.socket);
  final _FakeSocket socket;
  @override
  Stream<Object?> get messages => socket._messages.stream;
  @override
  void sendText(String text) => socket.texts.add(text);
  @override
  void sendBytes(List<int> bytes) {
    if (socket.failSend) throw StateError('send failed');
    socket.bytes.add(List<int>.from(bytes));
  }
  @override
  Future<void> close() async {
    socket.closed = true;
  }
}

class _Harness {
  _Harness({
    PrivacyCredentialStore? credentials,
    String purpose = PrivacyCaptureConfig.defaultPurpose,
    int codecId = PrivacyPcm16.pcm16CodecId,
    List<int> Function(List<int> opusPayload)? decodeOpus,
  }) : credentials = credentials ?? _MemoryCredentials('wss://stt.home.internal/live', 'secret-token') {
    ble = _FakeBle(codecId: codecId);
    controller = PrivacyCaptureController(
      ble: ble,
      socket: socket,
      credentials: this.credentials,
      sink: sink,
      onHaptic: haptics.add,
      onState: (_) {},
      now: () => DateTime.utc(2026, 10, 9, 12),
      newCaptureId: () => '11111111-1111-4111-8111-111111111111',
      purpose: purpose,
      decodeOpus: decodeOpus,
    );
  }

  final PrivacyCredentialStore credentials;
  late final _FakeBle ble;
  final socket = _FakeSocket();
  final sink = _RecordingSink();
  final haptics = <PrivacyHaptic>[];
  late final PrivacyCaptureController controller;

  Future<void> pump() => Future<void>.delayed(Duration.zero);
}
