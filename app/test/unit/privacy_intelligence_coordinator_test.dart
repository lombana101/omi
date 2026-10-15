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
  test('assistant receives only minimal open-task state and saves suggestions for review', () async {
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

    await coordinator.ask(
      message: 'Remind me to email the deck',
      timezone: 'America/Toronto',
      now: DateTime(2026, 10, 13, 9),
    );

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
    expect((await store.pendingCandidates()).single.proposedText, 'Email the deck');
  });

  test('authorized extraction persists provenance but does not auto-promote', () async {
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
            'extractor': 'ollama-structured-v1',
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

    final count = await coordinator.extract(
      sourceRef: 'session:s1',
      sourceKind: PrivacyIntelligenceSourceKind.consentedConversation,
      authorizationBasis: PrivacyIntelligenceAuthorizationBasis.participantsConsented,
      text: 'I will review notes',
      timezone: 'America/Toronto',
      now: DateTime.utc(2026, 10, 13),
      sessionId: 's1',
      captureId: 'c1',
    );

    expect(count, 1);
    expect(await store.tasks(), isEmpty);
    expect(await store.habits(), isEmpty);
    final candidate = (await store.pendingCandidates()).single;
    expect(candidate.sourceRef, 'session:s1');
    expect(candidate.uncertainty, 0.25);
    expect(candidate.suggestedType, 'habit');
  });

  test('proactive deadline advice persists once and dismissal prevents resurfacing', () async {
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

    await coordinator.evaluateProactive(
      timezone: 'America/Toronto',
      now: DateTime(2026, 10, 13, 9),
    );
    final pending = await store.pendingCandidates();
    expect(pending, hasLength(1));
    expect(pending.single.suggestedType, 'advice');

    await store.dismissCandidate(pending.single.candidateId);
    await coordinator.evaluateProactive(
      timezone: 'America/Toronto',
      now: DateTime(2026, 10, 13, 9),
    );

    expect(calls, 2);
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
