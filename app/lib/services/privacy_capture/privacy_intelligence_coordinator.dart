import 'package:uuid/uuid.dart';

import 'package:omi/services/privacy_capture/privacy_intelligence_client.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_models.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';

class PrivacyIntelligenceAssistantResult {
  const PrivacyIntelligenceAssistantResult({
    required this.response,
    required this.savedSuggestionCount,
  });

  final PrivacyIntelligenceAssistantResponse response;
  final int savedSuggestionCount;
}

/// Joins Ubuntu intelligence to the one authoritative local task store.
///
/// Only compact task fields leave the phone. Notes, source excerpts,
/// transcripts, habit history, and completed tasks are never sent to the
/// assistant. Calendar operations stay split into prepare, confirm, and
/// reconciliation calls so this layer cannot bypass user confirmation.
class PrivacyIntelligenceCoordinator {
  PrivacyIntelligenceCoordinator({
    required this.client,
    required this.store,
    String Function()? newId,
  }) : _newId = newId ?? const Uuid().v4;

  final PrivacyIntelligenceClient client;
  final PrivacyStore store;
  final String Function() _newId;

  Future<PrivacyIntelligenceAssistantResult> ask({
    required String message,
    required String timezone,
    required DateTime now,
  }) async {
    final context = await _openTaskContext(now);
    final response = await client.assistant(
      PrivacyIntelligenceAssistantRequest(
        message: message,
        timezone: timezone,
        now: now,
        openTasks: context,
      ),
    );
    final savedSuggestionCount = await _persistNewPendingSuggestions(response.taskSuggestions);
    return PrivacyIntelligenceAssistantResult(
      response: response,
      savedSuggestionCount: savedSuggestionCount,
    );
  }

  Future<int> evaluateProactive({required String timezone, required DateTime now}) async {
    final response = await client.evaluateProactive(
      PrivacyIntelligenceProactiveEvaluationRequest(
        timezone: timezone,
        now: now,
        openTasks: await _openTaskContext(now),
      ),
    );
    return _persistNewPendingSuggestions(
      response.suggestions,
      extractionKind: 'deterministic_deadline_risk',
      extractionVersion: 'deadline-risk-v1',
      origin: 'proactive_intelligence',
    );
  }

  Future<List<PrivacyIntelligenceLocalTaskContext>> _openTaskContext(DateTime now) async {
    final tasks = await store.tasks();
    final projects = await store.projects();
    final projectNames = <String, String>{for (final project in projects) project.projectId: project.name};
    return tasks
        .where((task) => task.isOpen)
        .map(
          (task) => PrivacyIntelligenceLocalTaskContext(
            taskId: task.taskId,
            title: task.title,
            dueAt: task.dueAt,
            projectName: task.projectId == null ? null : projectNames[task.projectId],
            inToday: privacyTaskSelectedToday(task, now),
          ),
        )
        .take(250)
        .toList(growable: false);
  }

  /// Re-evaluate retained, authorized transcript chunks on an explicit owner gesture.
  Future<int> reprocessSession({
    required String sessionId,
    required String timezone,
    required DateTime now,
  }) async {
    final sessions = (await store.sessions()).where((session) => session.localId == sessionId);
    if (sessions.isEmpty) throw StateError('source session is unavailable');
    final session = sessions.single;
    final participants = session.wireConsentBasis == 'participants_consented';
    if (!participants && session.wireConsentBasis != 'self_only') {
      throw StateError('source authorization is unavailable');
    }
    final text = <String>[
      ...(await store.chunks(sessionId)).map((chunk) => chunk.displayText),
      ...(await store.notes(sessionId)).map((note) => note.text),
    ].where((value) => value.trim().isNotEmpty).join('\n');
    if (text.isEmpty) return 0;
    return extract(
      sourceRef: 'session:$sessionId',
      sourceKind: participants
          ? PrivacyIntelligenceSourceKind.consentedConversation
          : PrivacyIntelligenceSourceKind.selfAuthoredTranscript,
      authorizationBasis: participants
          ? PrivacyIntelligenceAuthorizationBasis.participantsConsented
          : PrivacyIntelligenceAuthorizationBasis.selfOnly,
      text: text,
      timezone: timezone,
      now: now,
      sessionId: sessionId,
      captureId: session.captureId,
      requireSourceSession: true,
    );
  }

  Future<int> extract({
    required String sourceRef,
    required PrivacyIntelligenceSourceKind sourceKind,
    required PrivacyIntelligenceAuthorizationBasis authorizationBasis,
    required String text,
    required String timezone,
    required DateTime now,
    String sessionId = '',
    String captureId = '',
    int sequence = 0,
    bool requireSourceSession = false,
  }) async {
    final response = await client.extract(
      PrivacyIntelligenceExtractionRequest(
        sourceRef: sourceRef,
        sourceKind: sourceKind,
        authorizationBasis: authorizationBasis,
        text: text,
        timezone: timezone,
        now: now,
      ),
    );
    return _persistNewPendingSuggestions(
      response.suggestions,
      sessionId: sessionId,
      captureId: captureId,
      sequence: sequence,
      requireSourceSession: requireSourceSession,
      extractionVersion: response.extractor,
    );
  }

  Future<int> _persistNewPendingSuggestions(
    Iterable<PrivacyIntelligenceStructuredSuggestion> suggestions, {
    String sessionId = '',
    String captureId = '',
    int sequence = 0,
    bool requireSourceSession = false,
    String extractionKind = 'structured_personal_action',
    String extractionVersion = 'ollama-structured-v1',
    String origin = 'intelligence_suggestion',
  }) async {
    // Idempotent writes return the matching existing record as a success, so
    // only a previously unseen pending ID represents a newly saved candidate.
    final knownPendingIds = (await store.pendingCandidates()).map((candidate) => candidate.candidateId).toSet();
    var saved = 0;
    for (final suggestion in suggestions) {
      final result = await _persistSuggestion(
        suggestion,
        sessionId: sessionId,
        captureId: captureId,
        sequence: sequence,
        requireSourceSession: requireSourceSession,
        extractionKind: extractionKind,
        extractionVersion: extractionVersion,
        origin: origin,
      );
      if (!result.ok) throw StateError('suggestion persistence failed');
      final candidate = result.value;
      if (result.ok &&
          candidate != null &&
          candidate.status == 'pending' &&
          !candidate.tombstone &&
          knownPendingIds.add(candidate.candidateId)) {
        saved++;
      }
    }
    return saved;
  }

  Future<PrivacyWriteResult<PrivacyCandidateRecord>> _persistSuggestion(
    PrivacyIntelligenceStructuredSuggestion suggestion, {
    String sessionId = '',
    String captureId = '',
    int sequence = 0,
    bool requireSourceSession = false,
    String extractionKind = 'structured_personal_action',
    String extractionVersion = 'ollama-structured-v1',
    String origin = 'intelligence_suggestion',
  }) {
    return store.addIntelligenceCandidate(
      sourceRef: suggestion.sourceRef,
      suggestedType: suggestion.suggestedType.wireName,
      title: suggestion.title,
      excerpt: suggestion.supportingExcerpt,
      uncertainty: suggestion.uncertainty,
      sessionId: sessionId,
      captureId: captureId,
      sequence: sequence,
      requireSourceSession: requireSourceSession,
      description: suggestion.description,
      proposedTimeText: suggestion.proposedTimeText,
      proposedStartAt: suggestion.startAt,
      proposedEndAt: suggestion.endAt,
      timezone: suggestion.timezone,
      extractionKind: extractionKind,
      extractionVersion: extractionVersion,
      origin: origin,
    );
  }

  Future<PrivacyIntelligenceCalendarOperationPreview> prepare(
    PrivacyIntelligenceCalendarWriteProposal proposal,
  ) {
    final idempotencyKey = _newId().replaceAll('-', '');
    return client.prepareCalendarOperation(proposal.prepareRequest(idempotencyKey: idempotencyKey));
  }

  Future<PrivacyIntelligenceCalendarOperationPreview> prepareRequest(
    PrivacyIntelligenceCalendarOperationRequest request,
  ) =>
      client.prepareCalendarOperation(request);

  PrivacyIntelligenceCalendarWriteProposal calendarProposalForCandidate({
    required PrivacyCandidateRecord candidate,
    required String calendarId,
  }) {
    final startAt = candidate.proposedStartAt;
    final endAt = candidate.proposedEndAt;
    final timezone = candidate.timezone?.trim();
    if (candidate.suggestedType != 'calendar_event' ||
        startAt == null ||
        endAt == null ||
        timezone == null ||
        timezone.isEmpty) {
      throw ArgumentError('calendar candidate requires a start, end, and timezone');
    }
    return PrivacyIntelligenceCalendarWriteProposal(
      kind: PrivacyIntelligenceCalendarOperationKind.create,
      calendarId: calendarId,
      explanation: 'Review exact extracted calendar event.',
      event: PrivacyIntelligenceCalendarEventDraft(
        title: candidate.proposedText,
        startAt: startAt,
        endAt: endAt,
        startTimezone: timezone,
        endTimezone: timezone,
      ),
    );
  }

  Future<PrivacyIntelligenceCalendarOperationOutcome> confirm(
    PrivacyIntelligenceCalendarOperationPreview approvedPreview,
  ) =>
      client.confirmCalendarOperation(approvedPreview.operationId);

  Future<PrivacyIntelligenceCalendarOperationOutcome> confirmCalendarCandidate({
    required String candidateId,
    required PrivacyIntelligenceCalendarOperationPreview approvedPreview,
  }) async {
    final outcome = await confirm(approvedPreview);
    if (outcome.status == PrivacyIntelligenceOperationStatus.succeeded) {
      final saved = await store.markCalendarCandidateSaved(candidateId);
      if (!saved.ok) throw StateError('calendar candidate is no longer pending');
    }
    return outcome;
  }

  Future<PrivacyIntelligenceCalendarOperationOutcome> reconcile(String operationId) =>
      client.calendarOperationStatus(operationId);

  Future<PrivacyIntelligenceCalendarOperationOutcome> reconcileCalendarCandidate({
    required String candidateId,
    required String operationId,
  }) async {
    final outcome = await reconcile(operationId);
    if (outcome.status == PrivacyIntelligenceOperationStatus.succeeded) {
      final saved = await store.markCalendarCandidateSaved(candidateId);
      if (!saved.ok) throw StateError('calendar candidate is no longer pending');
    }
    return outcome;
  }
}
