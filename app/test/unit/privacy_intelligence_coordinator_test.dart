import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:omi/services/privacy_capture/privacy_intelligence_client.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_config.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_coordinator.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_models.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';

class _Credentials implements PrivacyIntelligenceCredentialSource {
  @override
  Future<PrivacyIntelligenceCredentials?> read() async => PrivacyIntelligenceCredentials(
        baseUrl: 'https://home-server.example.test:8444',
        ownerMappingId: 'owner',
        bearerToken: 'abcdefghijklmnopqrstuvwxyz012345',
      );
}

void main() {
  test('session reprocessing sends retained authorized text and survives retry and dismissal', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-session-reprocess');
    addTearDown(() => directory.delete(recursive: true));
    final store = await PrivacyStore.open(directory);
    final now = DateTime.now();
    final opened = await store.openSession(
      captureId: 'reprocess-capture',
      purpose: 'personal',
      ownerPurpose: 'task capture',
      consentBasis: 'self_only',
      protocolVersion: 1,
      policyRevision: 1,
      at: now,
    );
    final sessionId = opened.value!.localId;
    await store.upsertChunk(
        captureId: 'reprocess-capture', sequence: 1, machineText: 'Buy milk tomorrow. Call Alex about the trip.');
    var unavailable = true;
    var calls = 0;
    final client = PrivacyIntelligenceClient(
        credentials: _Credentials(),
        httpClient: MockClient((request) async {
          calls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(request.url.path, '/v1/intelligence/extract');
          expect(body['text'], 'Buy milk tomorrow. Call Alex about the trip.');
          expect(body['source_kind'], 'self_authored_transcript');
          expect(body['authorization_basis'], 'self_only');
          expect(body['source_ref'], 'session:$sessionId');
          if (unavailable) return http.Response('{}', 503);
          return http.Response(
              jsonEncode({
                'extractor': 'ollama-structured-v1',
                'suggestions': [
                  {
                    'suggested_type': 'task',
                    'title': 'Buy milk',
                    'source_ref': body['source_ref'],
                    'supporting_excerpt': 'Buy milk tomorrow.',
                    'uncertainty': 0.1,
                    'review_state': 'pending'
                  },
                  {
                    'suggested_type': 'task',
                    'title': 'Call Alex',
                    'source_ref': body['source_ref'],
                    'supporting_excerpt': 'Call Alex about the trip.',
                    'uncertainty': 0.1,
                    'review_state': 'pending',
                  }
                ],
              }),
              200);
        }));
    addTearDown(client.close);
    final coordinator = PrivacyIntelligenceCoordinator(client: client, store: store);
    Future<int> reprocess() =>
        coordinator.reprocessSession(sessionId: sessionId, timezone: 'America/Toronto', now: now);
    await expectLater(reprocess(), throwsA(isA<Exception>()));
    expect(await store.chunks(sessionId), hasLength(1));
    unavailable = false;
    expect(await reprocess(), 2);
    expect(await reprocess(), 0);
    final candidates = await store.pendingCandidates();
    await store.acceptCandidate(candidates.first.candidateId, editedTitle: 'Buy oat milk');
    await store.dismissCandidate(candidates.last.candidateId);
    expect(await reprocess(), 0);
    final reopened = await PrivacyStore.open(directory);
    expect(await reopened.pendingCandidates(), isEmpty);
    expect((await reopened.tasks()).single.title, 'Buy oat milk');
    expect(await reopened.chunks(sessionId), hasLength(1));
    expect(calls, 4);
  });

  test('deleted session fences an in-flight extraction result', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-deleted-reprocess');
    addTearDown(() => directory.delete(recursive: true));
    final store = await PrivacyStore.open(directory);
    final now = DateTime.now();
    final session = (await store.openSession(
            captureId: 'deleted-capture',
            purpose: 'personal',
            ownerPurpose: 'synthetic',
            consentBasis: 'self_only',
            protocolVersion: 1,
            policyRevision: 1,
            at: now))
        .value!;
    await store.upsertChunk(captureId: session.captureId, sequence: 1, machineText: 'Buy milk tomorrow.');
    final client = PrivacyIntelligenceClient(
        credentials: _Credentials(),
        httpClient: MockClient((request) async {
          await store.deleteSession(session.localId, deleteAcceptedTasks: false);
          return http.Response(
              jsonEncode({
                'extractor': 'ollama-structured-v1',
                'suggestions': [
                  {
                    'suggested_type': 'task',
                    'title': 'Buy milk',
                    'source_ref': 'session:${session.localId}',
                    'supporting_excerpt': 'Buy milk tomorrow.',
                    'uncertainty': 0.1,
                    'review_state': 'pending',
                  }
                ]
              }),
              200);
        }));
    addTearDown(client.close);
    final coordinator = PrivacyIntelligenceCoordinator(client: client, store: store);
    await expectLater(
        coordinator.reprocessSession(sessionId: session.localId, timezone: 'UTC', now: now), throwsStateError);
    expect(await store.pendingCandidates(), isEmpty);
    expect(await store.sessions(), isEmpty);
  });

  test('assistant receives minimal task state and counts only newly saved suggestions', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-coordinator-assistant');
    final store = await PrivacyStore.open(directory);
    final project = await store.createProject('Presentation');
    final open = await store.createTask(
      title: 'Prepare deck',
      note: 'private note must stay local',
      projectId: project.value!.projectId,
      excerpt: 'private source excerpt must stay local',
    );
    await store.setTaskToday(open.value!.taskId, selected: true, at: DateTime(2026, 10, 13, 9));
    final completed = await store.createTask(title: 'Already done');
    await store.setTaskStatus(completed.value!.taskId, completed: true);
    Map<String, dynamic>? requestBody;
    final client = PrivacyIntelligenceClient(
      credentials: _Credentials(),
      httpClient: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, Object?>{
            'message': 'Review the suggestion.',
            'events': <Object?>[],
            'task_suggestions': <Object?>[
              <String, Object?>{
                'suggested_type': 'task',
                'title': 'Email the deck',
                'source_ref': 'assistant:abc',
                'supporting_excerpt': 'Email the deck',
                'uncertainty': 0.1,
                'review_state': 'pending',
              },
            ],
            'calendar_proposal': null,
            'used_local_tasks': true,
            'used_timetree': false,
          }),
          200,
        );
      }),
    );
    final coordinator = PrivacyIntelligenceCoordinator(client: client, store: store);

    Future<PrivacyIntelligenceAssistantResult> ask() => coordinator.ask(
          message: 'Remind me to email the deck',
          timezone: 'America/Toronto',
          now: DateTime(2026, 10, 13, 9),
        );

    final first = await ask();
    expect(first.savedSuggestionCount, 1);
    expect((await ask()).savedSuggestionCount, 0);

    final projected = (requestBody!['open_tasks'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(projected, hasLength(1));
    expect(projected.single, <String, Object?>{
      'task_id': open.value!.taskId,
      'title': 'Prepare deck',
      'project_name': 'Presentation',
      'in_today': true,
    });
    expect(jsonEncode(requestBody), isNot(contains('private note')));
    expect(jsonEncode(requestBody), isNot(contains('private source excerpt')));
    expect((await store.tasks()), hasLength(2));
    final candidate = (await store.pendingCandidates()).single;
    expect(candidate.proposedText, 'Email the deck');

    await store.dismissCandidate(candidate.candidateId);
    expect((await ask()).savedSuggestionCount, 0);
    expect(await store.pendingCandidates(), isEmpty);
  });

  test('authorized extraction counts only new pending candidates and respects tombstones', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-coordinator-extract');
    final store = await PrivacyStore.open(directory);
    final client = PrivacyIntelligenceClient(
      credentials: _Credentials(),
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['source_kind'], 'consented_conversation');
        expect(body['authorization_basis'], 'participants_consented');
        return http.Response(
          jsonEncode(<String, Object?>{
            'extractor': 'ollama-structured-v2',
            'suggestions': <Object?>[
              <String, Object?>{
                'suggested_type': 'habit',
                'title': 'Review notes',
                'source_ref': 'session:s1',
                'supporting_excerpt': 'I will review notes',
                'uncertainty': 0.25,
                'review_state': 'pending',
              },
            ],
          }),
          200,
        );
      }),
    );
    final coordinator = PrivacyIntelligenceCoordinator(client: client, store: store);

    Future<int> extract() => coordinator.extract(
          sourceRef: 'session:s1',
          sourceKind: PrivacyIntelligenceSourceKind.consentedConversation,
          authorizationBasis: PrivacyIntelligenceAuthorizationBasis.participantsConsented,
          text: 'I will review notes',
          timezone: 'America/Toronto',
          now: DateTime.utc(2026, 10, 13),
          sessionId: 's1',
          captureId: 'c1',
        );

    expect(await extract(), 1);
    expect(await extract(), 0);
    expect(await store.tasks(), isEmpty);
    expect(await store.habits(), isEmpty);
    final candidate = (await store.pendingCandidates()).single;
    expect(candidate.sourceRef, 'session:s1');
    expect(candidate.uncertainty, 0.25);
    expect(candidate.suggestedType, 'habit');
    expect(candidate.extractionKind, 'structured_personal_action');
    expect(candidate.extractionVersion, 'ollama-structured-v2');
    expect(candidate.origin, 'intelligence_suggestion');

    await store.dismissCandidate(candidate.candidateId);
    expect(await extract(), 0);
    expect(await store.pendingCandidates(), isEmpty);
  });

  test('repeated refresh replaces by fingerprint and keeps dismissals tombstoned', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-coordinator-refresh');
    final store = await PrivacyStore.open(directory);
    var calls = 0;
    final client = PrivacyIntelligenceClient(
      credentials: _Credentials(),
      httpClient: MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode(<String, Object?>{
            'extractor': 'ollama-structured-v2',
            'suggestions': <Object?>[
              <String, Object?>{
                'suggested_type': 'task',
                'title': 'Buy milk',
                'source_ref': 'session:s1',
                'supporting_excerpt': 'Buy milk tomorrow',
                'uncertainty': 0.1,
                'review_state': 'pending',
              },
            ],
          }),
          200,
        );
      }),
    );
    final coordinator = PrivacyIntelligenceCoordinator(client: client, store: store);

    final first = await coordinator.extract(
      sourceRef: 'session:s1',
      sourceKind: PrivacyIntelligenceSourceKind.selfAuthoredTranscript,
      authorizationBasis: PrivacyIntelligenceAuthorizationBasis.selfOnly,
      text: 'Buy milk tomorrow',
      timezone: 'America/Toronto',
      now: DateTime.utc(2026, 10, 13),
      sessionId: 's1',
      captureId: 'c1',
    );
    expect(first, 1);
    final candidate = (await store.pendingCandidates()).single;
    await store.dismissCandidate(candidate.candidateId);
    expect(
        await coordinator.extract(
          sourceRef: 'session:s1',
          sourceKind: PrivacyIntelligenceSourceKind.selfAuthoredTranscript,
          authorizationBasis: PrivacyIntelligenceAuthorizationBasis.selfOnly,
          text: 'Buy milk tomorrow',
          timezone: 'America/Toronto',
          now: DateTime.utc(2026, 10, 13),
          sessionId: 's1',
          captureId: 'c1',
        ),
        0);
    expect(calls, 2);
    expect(await store.pendingCandidates(), isEmpty);
  });

  test('proactive refresh counts only new pending advice and dismissal prevents resurfacing', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-coordinator-proactive');
    final store = await PrivacyStore.open(directory);
    final dueAt = DateTime(2026, 10, 14, 17);
    final task = await store.createTask(title: 'Finish Memoria improvements', dueAt: dueAt);
    var calls = 0;
    final client = PrivacyIntelligenceClient(
      credentials: _Credentials(),
      httpClient: MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final tasks = (body['open_tasks'] as List<dynamic>).cast<Map<String, dynamic>>();
        expect(tasks.single['task_id'], task.value!.taskId);
        return http.Response(
          jsonEncode(<String, Object?>{
            'suggestions': <Object?>[
              <String, Object?>{
                'suggested_type': 'advice',
                'title': 'Plan for Finish Memoria improvements',
                'description': 'The task is due tomorrow.',
                'proposed_time_text': 'today',
                'source_ref': 'proactive:deadline:2026-10-14:${task.value!.taskId}',
                'supporting_excerpt': 'Finish Memoria improvements',
                'uncertainty': 0.0,
                'review_state': 'pending',
              },
            ],
            'used_local_tasks': true,
            'used_timetree': true,
            'calendar_status': 'available',
          }),
          200,
        );
      }),
    );
    final coordinator = PrivacyIntelligenceCoordinator(client: client, store: store);

    Future<int> refresh() => coordinator.evaluateProactive(
          timezone: 'America/Toronto',
          now: DateTime(2026, 10, 13, 9),
        );

    expect(await refresh(), 1);
    expect(await refresh(), 0);
    final pending = await store.pendingCandidates();
    expect(pending, hasLength(1));
    expect(pending.single.suggestedType, 'advice');
    expect(pending.single.extractionKind, 'deterministic_deadline_risk');
    expect(pending.single.extractionVersion, 'deadline-risk-v1');
    expect(pending.single.origin, 'proactive_intelligence');

    await store.dismissCandidate(pending.single.candidateId);
    expect(await refresh(), 0);

    expect(calls, 3);
    expect(await store.pendingCandidates(), isEmpty);
    expect(await store.tasks(), hasLength(1));
  });

  test('calendar prepare and confirm remain separate single calls', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-coordinator-calendar');
    final store = await PrivacyStore.open(directory);
    final candidate = await store.addIntelligenceCandidate(
      sourceRef: 'manual:calendar',
      suggestedType: 'calendar_event',
      title: 'Focus block',
      excerpt: 'Schedule a focus block',
      uncertainty: 0.1,
      proposedStartAt: DateTime.utc(2026, 10, 14, 18),
      proposedEndAt: DateTime.utc(2026, 10, 14, 20),
      timezone: 'America/Toronto',
    );
    var prepareCalls = 0;
    var confirmCalls = 0;
    final client = PrivacyIntelligenceClient(
      credentials: _Credentials(),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/prepare')) {
          prepareCalls++;
          return http.Response(
            jsonEncode(<String, Object?>{
              'operation_id': '0123456789abcdef0123456789abcdef',
              'kind': 'create',
              'calendar_id': 'calendar_1',
              'calendar_name': 'Personal',
              'title': 'Focus block',
              'start_at': '2026-10-14T18:00:00Z',
              'end_at': '2026-10-14T20:00:00Z',
              'timezone': 'America/Toronto',
              'all_day': false,
              'recurrence_scope': 'not_recurring',
              'changes': <String>['Create this event'],
              'expires_at': '2026-10-13T20:15:00Z',
            }),
            200,
          );
        }
        confirmCalls++;
        return http.Response(
          jsonEncode(<String, Object?>{
            'operation_id': '0123456789abcdef0123456789abcdef',
            'status': 'succeeded',
            'message': 'TimeTree confirmed that the event was created',
          }),
          200,
        );
      }),
    );
    final coordinator = PrivacyIntelligenceCoordinator(
      client: client,
      store: store,
      newId: () => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    );
    final proposal = coordinator.calendarProposalForCandidate(
      candidate: candidate.value!,
      calendarId: 'calendar_1',
    );

    final preview = await coordinator.prepare(proposal);
    expect(prepareCalls, 1);
    expect(confirmCalls, 0);
    expect(await store.pendingCandidates(), hasLength(1));
    final outcome = await coordinator.confirmCalendarCandidate(
      candidateId: candidate.value!.candidateId,
      approvedPreview: preview,
    );
    expect(outcome.status, PrivacyIntelligenceOperationStatus.succeeded);
    expect(prepareCalls, 1);
    expect(confirmCalls, 1);
    expect(await store.pendingCandidates(), isEmpty);
  });

  test('uncertain calendar confirmation stays pending until reconciliation succeeds', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-coordinator-calendar-reconcile');
    final store = await PrivacyStore.open(directory);
    final candidate = await store.addIntelligenceCandidate(
      sourceRef: 'manual:calendar',
      suggestedType: 'calendar_event',
      title: 'Focus block',
      excerpt: 'Schedule a focus block',
      uncertainty: 0.1,
      proposedStartAt: DateTime.utc(2026, 10, 14, 18),
      proposedEndAt: DateTime.utc(2026, 10, 14, 20),
      timezone: 'America/Toronto',
    );
    var confirmCalls = 0;
    var statusCalls = 0;
    final client = PrivacyIntelligenceClient(
      credentials: _Credentials(),
      httpClient: MockClient((request) async {
        if (request.method == 'POST') {
          confirmCalls++;
          return http.Response(
            jsonEncode(<String, Object?>{
              'operation_id': '0123456789abcdef0123456789abcdef',
              'status': 'uncertain',
              'message': 'Provider result is uncertain',
            }),
            200,
          );
        }
        statusCalls++;
        return http.Response(
          jsonEncode(<String, Object?>{
            'operation_id': '0123456789abcdef0123456789abcdef',
            'status': 'succeeded',
            'message': 'TimeTree confirmed that the event was created',
          }),
          200,
        );
      }),
    );
    final coordinator = PrivacyIntelligenceCoordinator(client: client, store: store);
    final preview = PrivacyIntelligenceCalendarOperationPreview(
      operationId: '0123456789abcdef0123456789abcdef',
      kind: PrivacyIntelligenceCalendarOperationKind.create,
      calendarId: 'calendar_1',
      calendarName: 'Personal',
      title: 'Focus block',
      startAt: DateTime.utc(2026, 10, 14, 18),
      endAt: DateTime.utc(2026, 10, 14, 20),
      timezone: 'America/Toronto',
      allDay: false,
      recurrenceScope: PrivacyIntelligencePreviewRecurrenceScope.notRecurring,
      changes: const <String>['Create this event'],
      expiresAt: DateTime.utc(2026, 10, 14, 17),
    );

    final uncertain = await coordinator.confirmCalendarCandidate(
      candidateId: candidate.value!.candidateId,
      approvedPreview: preview,
    );
    expect(uncertain.requiresReconciliation, isTrue);
    expect(confirmCalls, 1);
    expect(statusCalls, 0);
    expect(await store.pendingCandidates(), hasLength(1));

    final reconciled = await coordinator.reconcileCalendarCandidate(
      candidateId: candidate.value!.candidateId,
      operationId: preview.operationId,
    );
    expect(reconciled.status, PrivacyIntelligenceOperationStatus.succeeded);
    expect(confirmCalls, 1);
    expect(statusCalls, 1);
    expect(await store.pendingCandidates(), isEmpty);
  });
}
