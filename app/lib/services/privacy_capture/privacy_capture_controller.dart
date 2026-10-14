import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'package:omi/services/privacy_capture/privacy_capture_config.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_pcm16.dart';
import 'package:omi/services/privacy_capture/privacy_quick_capture.dart';

enum PrivacyCaptureState { off, authorizing, recording, finalizing, error }

String privacyCaptureStatusLabel({
  required PrivacyCaptureState state,
  String? lastOutcome,
  bool incomplete = false,
}) {
  switch (state) {
    case PrivacyCaptureState.recording:
      return 'Recording';
    case PrivacyCaptureState.finalizing:
      return 'Processing. Microphone off.';
    case PrivacyCaptureState.authorizing:
      return 'Waiting for StartCaptureAck';
    case PrivacyCaptureState.error:
      return 'Recording interrupted';
    case PrivacyCaptureState.off:
      if (!incomplete && lastOutcome != null && PrivacyCaptureConfig.successfulOutcomes.contains(lastOutcome)) {
        return 'Completed';
      }
      return 'Recording: Off';
  }
}

enum PrivacyHaptic { start, stop, error }

/// BLE seam. Button notifications stay up while audio notifications stay down.
abstract class PrivacyBlePort {
  Future<bool> maintainButtonNotifications({void Function(List<int> payload)? onButton});
  Future<void> unsubscribeAudio();
  Future<Stream<List<int>>> subscribeAudio();
  Future<int> audioCodecId();
  Future<bool> get isConnected;
}

abstract class PrivacySocketPort {
  Future<PrivacySocketSession> connect({required Uri url, required String authorizationHeader});
}

abstract class PrivacySocketSession {
  Stream<Object?> get messages;
  void sendText(String text);
  void sendBytes(List<int> bytes);
  Future<void> close();
}

class PrivacySocketClosed {
  const PrivacySocketClosed(this.code, {this.reason});
  final int? code;
  final String? reason;
}

class PrivacyTranscript {
  const PrivacyTranscript({
    required this.captureId,
    required this.sequence,
    required this.text,
    this.startSeconds,
    this.endSeconds,
  });
  final String captureId;
  final int sequence;
  final String text;
  final double? startSeconds;
  final double? endSeconds;
}

/// Persistence seam. Capture admission does not depend on a second audio path.
abstract class PrivacyCaptureJournal {
  Future<void> onAuthorizing({
    required String captureId,
    required String purpose,
    required String ownerPurpose,
    required String consentBasis,
    required String wireConsentBasis,
    required DateTime consentAssertedAt,
    String? configuredPurpose,
    required String captureOrigin,
    PrivacyRetentionChoice? retentionChoice,
    required DateTime at,
    required int protocolVersion,
    required int policyRevision,
  });

  Future<void> onRecording(String captureId);

  /// False means the chunk conflicted or could not be stored. Fail closed.
  Future<bool> onTranscript(PrivacyTranscript transcript);

  Future<void> onTerminal({
    required String captureId,
    required String outcome,
    required bool incomplete,
    required DateTime at,
  });
}

class PrivacyCaptureTrace {
  const PrivacyCaptureTrace({
    required this.at,
    required this.type,
    required this.captureIdMatched,
    required this.decoded,
    required this.state,
    required this.transcriptCount,
    this.closeCode,
    this.closeReason,
  });

  final DateTime at;
  final String type;
  final bool captureIdMatched;
  final bool decoded;
  final PrivacyCaptureState state;
  final int transcriptCount;
  final int? closeCode;
  final String? closeReason;
}

class PrivacyCredentials {
  const PrivacyCredentials({required this.url, required this.bearerToken});

  final String url;
  final String bearerToken;
}

/// Reads a user-supplied URL and bearer token. Never a source-code constant.
abstract class PrivacyCredentialStore {
  Future<PrivacyCredentials?> read();
}

/// Admitted frames may be forwarded. Rejected frames must be dropped.
abstract class PrivacyAudioSink {
  void admit(List<int> frame);
  void reject(List<int> frame);
}

class DroppingAudioSink implements PrivacyAudioSink {
  const DroppingAudioSink();
  @override
  void admit(List<int> frame) {}

  @override
  void reject(List<int> frame) {}
}

/// Explicit capture session. Off until the backend acknowledges StartCapture.
class PrivacyCaptureController {
  PrivacyCaptureController({
    required this.ble,
    required this.socket,
    required this.credentials,
    required this.sink,
    required this.onHaptic,
    required this.onState,
    this.onTrace,
    this.config = const PrivacyCaptureConfig(),
    DateTime Function()? now,
    String Function()? newCaptureId,
    this.purpose = PrivacyCaptureConfig.defaultPurpose,
    this.ownerPurpose = '',
    this.journal,
    this.requireConsentAssertion = false,
    this.decodeOpus,
  })  : _now = now ?? DateTime.now,
        _newCaptureId = newCaptureId ?? const Uuid().v4;

  final PrivacyBlePort ble;
  final PrivacySocketPort socket;
  final PrivacyCredentialStore credentials;
  final PrivacyAudioSink sink;
  final void Function(PrivacyHaptic haptic) onHaptic;
  final void Function(PrivacyCaptureState state) onState;
  final void Function()? onTrace;
  final PrivacyCaptureConfig config;
  final DateTime Function() _now;
  final String Function() _newCaptureId;
  String purpose;
  String ownerPurpose;
  PrivacyCaptureJournal? journal;
  bool requireConsentAssertion;
  bool selfOnlyAsserted = false;
  final List<int> Function(List<int> opusPayload)? decodeOpus;

  PrivacyCaptureState state = PrivacyCaptureState.off;
  String consentBasis = PrivacyCaptureConfig.defaultConsentBasis;
  String wireConsentBasis = PrivacyCaptureConfig.defaultConsentBasis;
  String captureOrigin = PrivacyCaptureConfig.phoneManualCaptureOrigin;
  String? configuredPurpose;
  PrivacyRetentionChoice? retentionChoice;
  bool participantsConsentArmed = false;
  String? activeCaptureId;
  String? lastStartCaptureJson;
  String? lastAuthorizationHeader;
  int audioSubscriptionCount = 0;
  bool get admissionOpen => _admissionOpen;
  bool _admissionOpen = false;
  bool get recording => state == PrivacyCaptureState.recording;
  String? lastOutcome;
  bool incomplete = false;
  bool _tapGate = false;
  bool _startGate = false;
  bool _ending = false;
  bool _foreground = true;
  int? _backgroundQuickCaptureGeneration;
  DateTime? _pendingConsentAssertedAt;
  QuickSelfCaptureIntent? _pendingQuickCapture;
  final transcripts = <PrivacyTranscript>[];
  List<String> get localTranscripts => transcripts.map((item) => item.text).toList();
  final traces = <PrivacyCaptureTrace>[];
  Timer? _watchdog;
  bool _terminal = false;
  Future<void> _events = Future<void>.value();

  void closeAdmissionForTesting() {
    _admissionOpen = false;
  }

  void expireFinalizationForTesting() {
    final generation = _generation;
    _watchdog?.cancel();
    unawaited(_onWatchdog(generation));
  }

  int _generation = 0;
  int? _lastAcceptedSequence;
  String? _openedCaptureId;
  bool _journalClosed = false;
  StreamSubscription<List<int>>? _audioSub;
  StreamSubscription<Object?>? _socketSub;
  PrivacySocketSession? _session;

  /// Fresh process. Does not resume a previous capture.
  Future<void> onAppStart() async {
    _foreground = true;
    await _forceOff(haptic: null, next: PrivacyCaptureState.off);
  }

  bool get _backgroundQuickCaptureActive =>
      _backgroundQuickCaptureGeneration == _generation &&
      (_startGate ||
          state == PrivacyCaptureState.authorizing ||
          state == PrivacyCaptureState.recording ||
          state == PrivacyCaptureState.finalizing);

  /// Returning to the foreground never revives a prior authorization or audio
  /// subscription. A pendant capture that was admitted while backgrounded is
  /// already the same live generation, so foregrounding must not stop it.
  Future<void> onForeground() async {
    _foreground = true;
    if (_backgroundQuickCaptureActive) return;
    if (state == PrivacyCaptureState.recording ||
        state == PrivacyCaptureState.authorizing ||
        state == PrivacyCaptureState.finalizing) {
      await _interrupt(_generation);
      return;
    }
    await _forceOff(haptic: null, next: PrivacyCaptureState.off);
  }

  /// Radio returned. An in-progress capture is interrupted. Audio must not resume.
  Future<void> onReconnect() async {
    if (state == PrivacyCaptureState.recording ||
        state == PrivacyCaptureState.authorizing ||
        state == PrivacyCaptureState.finalizing) {
      await _interrupt(_generation);
    } else {
      await _forceOff(haptic: null, next: PrivacyCaptureState.off);
    }
    await ble.maintainButtonNotifications();
    await ble.unsubscribeAudio();
  }

  /// Arms the next start only. A later double-tap still defaults to self_only
  /// unless this is called again.
  void armParticipantsConsented({required bool consentObtained}) {
    participantsConsentArmed = consentObtained;
    if (consentObtained) {
      selfOnlyAsserted = false;
      _pendingConsentAssertedAt = _now();
    }
  }

  /// Owner assertion that nobody else is being recorded. Not a technical determination.
  void assertSelfOnly() {
    selfOnlyAsserted = true;
    participantsConsentArmed = false;
    _pendingConsentAssertedAt = _now();
  }

  /// Any capture admitted in the foreground stops when the app leaves it. A
  /// pendant capture admitted while already backgrounded survives duplicate
  /// background notifications for that lifecycle transition only. If it is
  /// foregrounded and later backgrounded again, it is interrupted normally.
  Future<void> onBackground() async {
    final repeatedBackgroundNotification = !_foreground;
    _foreground = false;
    if (repeatedBackgroundNotification && _backgroundQuickCaptureActive) return;
    if (state == PrivacyCaptureState.off || state == PrivacyCaptureState.error) {
      await _forceOff(haptic: null, next: PrivacyCaptureState.off);
      return;
    }
    if (state == PrivacyCaptureState.authorizing) {
      await _fail(_generation);
      return;
    }
    await _interrupt(_generation);
  }

  /// Pendant double-tap. A quick intent is an assertion for this start gesture
  /// only. Without one, privacy builds reject pendant starts even if the phone
  /// flow has a mixed-party assertion armed.
  Future<void> onDoubleTap({QuickSelfCaptureIntent? quickCapture}) async {
    if (_tapGate || state == PrivacyCaptureState.authorizing || state == PrivacyCaptureState.finalizing) {
      return;
    }
    _tapGate = true;
    try {
      if (state == PrivacyCaptureState.recording) {
        await stop();
        return;
      }
      if ((!_foreground && quickCapture == null) || (quickCapture == null && requireConsentAssertion)) {
        await _forceOff(haptic: PrivacyHaptic.error, next: PrivacyCaptureState.off);
        return;
      }
      if (quickCapture != null) {
        _pendingQuickCapture = quickCapture;
        participantsConsentArmed = false;
        selfOnlyAsserted = false;
        _pendingConsentAssertedAt = null;
      }
      await start();
    } finally {
      _tapGate = false;
    }
  }

  Future<void> start() async {
    if (_startGate ||
        state == PrivacyCaptureState.recording ||
        state == PrivacyCaptureState.authorizing ||
        state == PrivacyCaptureState.finalizing) {
      return;
    }
    _startGate = true;
    final generation = ++_generation;
    final quickCapture = _pendingQuickCapture;
    _pendingQuickCapture = null;
    _backgroundQuickCaptureGeneration = !_foreground && quickCapture != null ? generation : null;
    try {
      await _closeAudio();
      final previous = _session;
      _session = null;
      if (previous != null) await previous.close();
      if (!_foreground && quickCapture == null) {
        await _fail(generation);
        return;
      }
      if (requireConsentAssertion && quickCapture == null && ownerPurpose.trim().isEmpty) {
        await _fail(generation);
        return;
      }
      if (requireConsentAssertion && quickCapture == null && !participantsConsentArmed && !selfOnlyAsserted) {
        await _fail(generation);
        return;
      }
      await ble.maintainButtonNotifications();
      _setState(PrivacyCaptureState.authorizing);
      _terminal = false;
      _journalClosed = false;
      _lastAcceptedSequence = null;
      _openedCaptureId = null;
      lastOutcome = null;
      incomplete = false;
      _ending = false;
      transcripts.clear();

      final startAt = _now();
      final basis = quickCapture != null
          ? PrivacyCaptureConfig.defaultConsentBasis
          : (participantsConsentArmed ? 'participants_consented' : PrivacyCaptureConfig.defaultConsentBasis);
      final localBasis = quickCapture == null ? basis : PrivacyCaptureConfig.quickGestureConsentBasis;
      final wirePurpose = quickCapture == null ? purpose : PrivacyCaptureConfig.defaultPurpose;
      final effectiveOwnerPurpose = quickCapture?.purpose.provenanceValue ?? ownerPurpose;
      final assertedAt = quickCapture?.assertedAt ?? _pendingConsentAssertedAt ?? startAt;
      participantsConsentArmed = false;
      selfOnlyAsserted = false;
      _pendingConsentAssertedAt = null;
      consentBasis = localBasis;
      wireConsentBasis = basis;
      configuredPurpose = quickCapture?.purpose.provenanceValue;
      captureOrigin = quickCapture == null
          ? PrivacyCaptureConfig.phoneManualCaptureOrigin
          : PrivacyCaptureConfig.pendantQuickCaptureOrigin;
      retentionChoice = quickCapture?.retention;

      if (!await ble.isConnected || !_consentAllowed(basis, wirePurpose: wirePurpose)) {
        await _fail(generation);
        return;
      }

      final stored = await credentials.read();
      final url = validatePrivacyLiveUrl(stored?.url, config: config);
      final token = stored?.bearerToken.trim() ?? '';
      if (url == null || token.isEmpty) {
        await _fail(generation);
        return;
      }

      final captureId = _newCaptureId();
      _openedCaptureId = captureId;
      try {
        await journal?.onAuthorizing(
          captureId: captureId,
          purpose: wirePurpose,
          ownerPurpose: effectiveOwnerPurpose,
          consentBasis: localBasis,
          wireConsentBasis: basis,
          consentAssertedAt: assertedAt,
          configuredPurpose: configuredPurpose,
          captureOrigin: captureOrigin,
          retentionChoice: retentionChoice,
          at: startAt,
          protocolVersion: config.protocolVersion,
          policyRevision: config.policyRevision,
        );
      } catch (_) {
        await _fail(generation);
        return;
      }
      final message = _startCaptureJson(
        captureId: captureId,
        purpose: wirePurpose,
        consentBasis: basis,
      );
      lastStartCaptureJson = message;
      lastAuthorizationHeader = 'Bearer $token';

      PrivacySocketSession session;
      try {
        session = await socket.connect(url: url, authorizationHeader: lastAuthorizationHeader!);
      } catch (_) {
        await _fail(generation);
        return;
      }
      if (generation != _generation) {
        await session.close();
        return;
      }
      _session = session;
      final ackCompleter = Completer<Object?>();
      _socketSub = session.messages.listen((event) {
        if (!ackCompleter.isCompleted) {
          ackCompleter.complete(event);
          return;
        }
        unawaited(_enqueue(generation, event));
      }, onError: (_) {
        if (!ackCompleter.isCompleted) ackCompleter.complete(const PrivacySocketClosed(1008));
        unawaited(_fail(generation));
      });
      session.sendText(message);

      Object? ack;
      try {
        ack = await ackCompleter.future.timeout(config.ackTimeout);
      } catch (_) {
        await _fail(generation);
        return;
      }
      if (generation != _generation || !_isAck(ack, captureId)) {
        await _fail(generation);
        return;
      }

      final codecId = await ble.audioCodecId();
      final opus = codecId == PrivacyPcm16.opusCodecId || codecId == PrivacyPcm16.opusFs320CodecId;
      final known = codecId == PrivacyPcm16.pcm16CodecId || codecId == PrivacyPcm16.pcm8CodecId || opus;
      if (generation != _generation || !known || (opus && decodeOpus == null)) {
        await _fail(generation);
        return;
      }
      try {
        await journal?.onRecording(captureId);
      } catch (_) {
        await _fail(generation);
        return;
      }
      _codecId = codecId;
      activeCaptureId = captureId;
      _admissionOpen = true;
      _setState(PrivacyCaptureState.recording);
      onHaptic(PrivacyHaptic.start);
      final stream = await ble.subscribeAudio();
      if (generation != _generation) {
        await ble.unsubscribeAudio();
        return;
      }
      audioSubscriptionCount++;
      _audioSub = stream.listen(
        (frame) => _onAudio(generation, frame),
        onError: (_) {
          unawaited(_interrupt(generation));
        },
        onDone: () {
          if (state == PrivacyCaptureState.recording) unawaited(_interrupt(generation));
        },
      );
    } finally {
      _startGate = false;
    }
  }

  Future<void> stop() async {
    if (state == PrivacyCaptureState.finalizing || _terminal) return;
    if (state != PrivacyCaptureState.recording) {
      await _forceOff(haptic: PrivacyHaptic.stop, next: PrivacyCaptureState.off);
      return;
    }
    final generation = _generation;
    final captureId = activeCaptureId;
    final session = _session;
    _admissionOpen = false;
    await _audioSub?.cancel();
    _audioSub = null;
    await ble.unsubscribeAudio();
    if (generation != _generation || captureId == null || session == null) {
      await _fail(generation);
      return;
    }
    _terminal = false;
    _setState(PrivacyCaptureState.finalizing);
    onHaptic(PrivacyHaptic.stop);
    session.sendText(jsonEncode({
      'type': PrivacyCaptureConfig.closeType,
      'version': config.protocolVersion,
      'capture_id': captureId,
    }));
    _watchdog?.cancel();
    _watchdog = Timer(config.finalizationTimeout, () {
      unawaited(_onWatchdog(generation));
    });
  }

  int? _codecId;

  void _onAudio(int generation, List<int> frame) {
    final live = generation == _generation && _admissionOpen && state == PrivacyCaptureState.recording;
    if (!live) {
      _admissionOpen = false;
      sink.reject(frame);
      return;
    }
    final pcm = PrivacyPcm16.encode(frame, codecId: _codecId ?? -1, decodeOpus: decodeOpus);
    if (pcm == null) {
      sink.reject(frame);
      return;
    }
    sink.admit(pcm);
    try {
      _session?.sendBytes(pcm);
    } catch (_) {
      unawaited(_interrupt(generation));
    }
  }

  bool _consentAllowed(String basis, {required String wirePurpose}) {
    if (!PrivacyCaptureConfig.allowedConsentBases.contains(basis)) return false;
    if (!PrivacyCaptureConfig.allowedPurposes.contains(wirePurpose)) return false;
    if (wirePurpose == 'self_voice_enrollment' && basis != PrivacyCaptureConfig.defaultConsentBasis) return false;
    return true;
  }

  String _startCaptureJson({
    required String captureId,
    required String purpose,
    required String consentBasis,
  }) {
    final timestamp = _now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    final formatted =
        '${timestamp.year.toString().padLeft(4, '0')}-${two(timestamp.month)}-${two(timestamp.day)}T${two(timestamp.hour)}:${two(timestamp.minute)}:${two(timestamp.second)}Z';
    return jsonEncode(<String, Object>{
      'type': PrivacyCaptureConfig.startType,
      'version': config.protocolVersion,
      'capture_id': captureId,
      'purpose': purpose,
      'consent_basis': consentBasis,
      'policy_revision': config.policyRevision,
      'client_timestamp': formatted,
    });
  }

  bool _isAck(Object? message, String captureId) => isStartCaptureAck(
        message,
        captureId,
        protocolVersion: config.protocolVersion,
      );

  Future<void> _enqueue(int generation, Object? event) {
    _events = _events.then((_) => _onLiveEvent(generation, event));
    return _events;
  }

  Future<void> _onLiveEvent(int generation, Object? event) async {
    if (generation != _generation && !_terminal) return;
    if (event is PrivacySocketClosed) {
      _trace('socket_close', decoded: true, captureIdMatched: true, closeCode: event.code, closeReason: event.reason);
      if (_terminal) return;
      if (generation != _generation) return;
      if (state == PrivacyCaptureState.finalizing || state == PrivacyCaptureState.recording) {
        await _interrupt(generation);
      }
      return;
    }
    if (event is! String || generation != _generation) return;
    final parsed = _decode(event);
    _trace(
      parsed?.type ?? 'malformed',
      decoded: parsed != null,
      captureIdMatched: parsed?.captureIdMatched ?? false,
    );
    if (_terminal) return;
    if (parsed == null || !parsed.captureIdMatched) {
      await _interrupt(generation);
      return;
    }
    if (parsed.type == PrivacyCaptureConfig.transcriptType &&
        (state == PrivacyCaptureState.recording || state == PrivacyCaptureState.finalizing)) {
      final text = parsed.fields['text'];
      final sequence = parsed.fields['sequence'];
      if (text is! String || text.trim().isEmpty || (sequence != null && sequence is! int)) {
        await _interrupt(generation);
        return;
      }
      final assigned = sequence is int ? sequence : transcripts.length + 1;
      if (!_sequenceAllowed(assigned, text)) {
        await _interrupt(generation);
        return;
      }
      if (_lastAcceptedSequence == assigned) return;
      final chunk = PrivacyTranscript(
        captureId: activeCaptureId!,
        sequence: assigned,
        text: text,
        startSeconds: _seconds(parsed.fields['start']),
        endSeconds: _seconds(parsed.fields['end']),
      );
      try {
        final stored = await journal?.onTranscript(chunk) ?? true;
        if (!stored) {
          await _interrupt(generation);
          return;
        }
      } catch (_) {
        await _interrupt(generation);
        return;
      }
      transcripts.add(chunk);
      _lastAcceptedSequence = assigned;
      _trace('transcript_stored', decoded: true, captureIdMatched: true);
      onTrace?.call();
      return;
    }
    if (state == PrivacyCaptureState.recording) {
      await _interrupt(generation);
      return;
    }
    if (state != PrivacyCaptureState.finalizing) return;
    if (parsed.type == PrivacyCaptureConfig.finalizingType) return;
    if (parsed.type == PrivacyCaptureConfig.completeType) {
      final outcome = parsed.fields['outcome'];
      if (outcome is! String || !PrivacyCaptureConfig.completeOutcomes.contains(outcome)) {
        await _interrupt(generation);
        return;
      }
      _terminal = true;
      lastOutcome = outcome;
      incomplete = false;
      _watchdog?.cancel();
      final success = PrivacyCaptureConfig.successfulOutcomes.contains(outcome);
      await _closeJournal(outcome: outcome, incomplete: !success);
      await _forceOff(haptic: null, next: success ? PrivacyCaptureState.off : PrivacyCaptureState.error);
      return;
    }
    await _interrupt(generation);
  }

  _Decoded? _decode(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map || decoded['type'] is! String || decoded['version'] != config.protocolVersion) {
      return null;
    }
    final id = decoded['capture_id'];
    final active = activeCaptureId;
    final matched = id is String && active != null && _sameUuid(id, active);
    return _Decoded(decoded['type'] as String, Map<String, dynamic>.from(decoded), matched);
  }

  void _trace(
    String type, {
    required bool decoded,
    required bool captureIdMatched,
    int? closeCode,
    String? closeReason,
  }) {
    traces.add(PrivacyCaptureTrace(
      at: _now(),
      type: type,
      captureIdMatched: captureIdMatched,
      decoded: decoded,
      state: state,
      transcriptCount: transcripts.length,
      closeCode: closeCode,
      closeReason: closeReason,
    ));
    onTrace?.call();
  }

  Future<void> _onWatchdog(int generation) async {
    if (generation != _generation || _terminal || state != PrivacyCaptureState.finalizing) return;
    lastOutcome = 'timeout';
    incomplete = true;
    await _interrupt(generation);
  }

  bool _sequenceAllowed(int sequence, String text) {
    final last = _lastAcceptedSequence;
    if (last == null) return sequence == 1 || transcripts.isEmpty && sequence == transcripts.length + 1;
    if (sequence == last) {
      final prior = transcripts.where((item) => item.sequence == sequence).toList();
      return prior.isNotEmpty && prior.last.text == text;
    }
    return sequence == last + 1;
  }

  double? _seconds(Object? value) {
    if (value is num) return value.toDouble();
    return null;
  }

  Future<void> _closeJournal({required String outcome, required bool incomplete}) async {
    if (_journalClosed) return;
    final captureId = _openedCaptureId;
    _journalClosed = true;
    if (captureId == null || journal == null) return;
    try {
      await journal!.onTerminal(
        captureId: captureId,
        outcome: outcome,
        incomplete: incomplete,
        at: _now(),
      );
    } catch (_) {}
  }

  Future<void> _interrupt(int generation) async {
    if (_ending || generation != _generation || _terminal) return;
    _ending = true;
    incomplete = true;
    await _closeJournal(outcome: lastOutcome ?? 'interrupted', incomplete: true);
    await _forceOff(haptic: PrivacyHaptic.error, next: PrivacyCaptureState.error);
  }

  Future<void> _fail(int generation) async {
    if (generation != _generation) return;
    await _closeJournal(outcome: 'failed_closed', incomplete: true);
    await _forceOff(haptic: PrivacyHaptic.error, next: PrivacyCaptureState.off);
  }

  Future<void> _forceOff({required PrivacyHaptic? haptic, required PrivacyCaptureState next}) async {
    _generation++;
    _admissionOpen = false;
    _watchdog?.cancel();
    _watchdog = null;
    activeCaptureId = null;
    _openedCaptureId = null;
    _lastAcceptedSequence = null;
    consentBasis = PrivacyCaptureConfig.defaultConsentBasis;
    wireConsentBasis = PrivacyCaptureConfig.defaultConsentBasis;
    captureOrigin = PrivacyCaptureConfig.phoneManualCaptureOrigin;
    configuredPurpose = null;
    retentionChoice = null;
    participantsConsentArmed = false;
    selfOnlyAsserted = false;
    _pendingConsentAssertedAt = null;
    _pendingQuickCapture = null;
    _backgroundQuickCaptureGeneration = null;
    await _closeAudio();
    final session = _session;
    _session = null;
    if (session != null) await session.close();
    _setState(next);
    if (haptic != null) onHaptic(haptic);
    await ble.maintainButtonNotifications();
  }

  Future<void> _closeAudio() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _socketSub?.cancel();
    _socketSub = null;
    await ble.unsubscribeAudio();
  }

  void _setState(PrivacyCaptureState next) {
    state = next;
    onState(next);
  }
}

/// Accepts the verified StartCaptureAck. [authorized_at] and unknown fields
/// are ignored. [capture_id] must be the same UUID, not the same letter case.
bool isStartCaptureAck(Object? message, String captureId, {required int protocolVersion}) {
  if (message is! String) return false;
  Object? decoded;
  try {
    decoded = jsonDecode(message);
  } catch (_) {
    return false;
  }
  if (decoded is! Map) return false;
  if (decoded['type'] != PrivacyCaptureConfig.ackType) return false;
  if (decoded['version'] != protocolVersion) return false;
  final ackId = decoded['capture_id'];
  if (ackId is! String) return false;
  return _sameUuid(ackId, captureId);
}

bool _sameUuid(String left, String right) {
  final a = _uuidBytes(left);
  final b = _uuidBytes(right);
  if (a == null || b == null) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Decoded {
  const _Decoded(this.type, this.fields, this.captureIdMatched);
  final String type;
  final Map<String, dynamic> fields;
  final bool captureIdMatched;
}

List<int>? _uuidBytes(String value) {
  var text = value.trim();
  if (text.toLowerCase().startsWith('urn:uuid:')) text = text.substring(9);
  if (text.length >= 2 && text.startsWith('{') && text.endsWith('}')) {
    text = text.substring(1, text.length - 1);
  }
  final hex = text.replaceAll('-', '');
  if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) return null;
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  final version = bytes[6] >> 4;
  final variant = bytes[8] >> 4;
  if (version < 1 || version > 8 || variant < 8 || variant > 11) return null;
  return bytes;
}
