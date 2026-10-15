import 'package:uuid/uuid.dart';

import 'package:omi/services/privacy_capture/privacy_intelligence_client.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_models.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';

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

  Future<PrivacyIntelligenceAssistantResponse> ask({
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
    for (final suggestion in response.taskSuggestions) {
      await _persistSuggestion(suggestion);
    }
    return response;
  }

  Future<int> evaluateProactive({required String timezone, required DateTime now}) async {
    final response = await client.evaluateProactive(
      PrivacyIntelligenceProactiveEvaluationRequest(
        timezone: timezone,
        now: now,
        openTasks: await _openTaskContext(now),
      ),
    );
    var saved = 0;
    for (final suggestion in response.suggestions) {
      final result = await _persistSuggestion(suggestion);
      if (result.ok && result.value?.status == 'pending') saved++;
    }
    return saved;
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

  Future<int> extract({
    required String sourceRef,
    required PrivacyIntelligenceSourceKind sourceKind,
    required PrivacyIntelligenceAuthorizationBasis authorizationBasis,
    required String text,
    required String timezone,
    required DateTime now,
    String sessionId = '',
    String captureId = '',
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
    var saved = 0;
    for (final suggestion in response.suggestions) {
      final result = await _persistSuggestion(
        suggestion,
        sessionId: sessionId,
        captureId: captureId,
      );
      if (result.ok) saved++;
    }
    return saved;
  }

  Future<PrivacyWriteResult<PrivacyCandidateRecord>> _persistSuggestion(
    PrivacyIntelligenceStructuredSuggestion suggestion, {
    String sessionId = '',
    String captureId = '',
  }) {
    return store.addIntelligenceCandidate(
      sourceRef: suggestion.sourceRef,
      suggestedType: suggestion.suggestedType.wireName,
      title: suggestion.title,
      excerpt: suggestion.supportingExcerpt,
      uncertainty: suggestion.uncertainty,
      sessionId: sessionId,
      captureId: captureId,
      description: suggestion.description,
      proposedTimeText: suggestion.proposedTimeText,
      proposedStartAt: suggestion.startAt,
      proposedEndAt: suggestion.endAt,
      timezone: suggestion.timezone,
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
