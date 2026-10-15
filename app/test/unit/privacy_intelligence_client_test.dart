import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:omi/services/privacy_capture/privacy_intelligence_client.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_config.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_models.dart';

const _owner = 'owner_01';
const _token = '0123456789abcdefghijklmnop';
const _operationId = '0123456789abcdef0123456789abcdef';

void main() {
  test('typed client covers status, calendar reads, extraction, assistant, and operation lifecycle', () async {
    final requests = <http.Request>[];
    final httpClient = MockClient((request) async {
      requests.add(request);
      expect(request.followRedirects, isFalse);
      expect(request.headers['authorization'], 'Bearer $_token');
      expect(request.headers['x-pis-owner-uid'], _owner);
      switch (request.url.path) {
        case '/pis/v1/integrations':
          return _json(<String, Object?>{
            'local_intelligence': true,
            'timetree': true,
            'generic_calendar_uses_timetree': false,
          });
        case '/pis/v1/timetree/calendars':
          return _json(<Object?>[
            <String, Object?>{'id': 'calendar_1', 'name': 'Personal'},
          ]);
        case '/pis/v1/timetree/events':
          expect(request.url.queryParameters, <String, String>{
            'calendar_id': 'calendar_1',
            'query': 'dentist',
            'start_at': '2026-10-13T00:00:00.000Z',
            'end_at': '2026-10-15T00:00:00.000Z',
            'limit': '10',
          });
          return _json(<Object?>[_eventJson()]);
        case '/pis/v1/intelligence/extract':
          final body = _body(request);
          expect(body['source_kind'], 'owner_note');
          expect(body['authorization_basis'], 'self_only');
          return _json(<String, Object?>{
            'suggestions': <Object?>[_suggestionJson()],
            'extractor': 'ollama-structured-v1',
          });
        case '/pis/v1/assistant':
          final body = _body(request);
          expect((body['open_tasks'] as List).single, containsPair('task_id', 'task_1'));
          return _json(<String, Object?>{
            'message': 'You have one task and one TimeTree event.',
            'events': <Object?>[_eventJson()],
            'task_suggestions': <Object?>[_suggestionJson()],
            'calendar_proposal': null,
            'used_local_tasks': true,
            'used_timetree': true,
          });
        case '/pis/v1/intelligence/proactive/evaluate':
          final body = _body(request);
          expect((body['open_tasks'] as List).single, containsPair('task_id', 'task_1'));
          return _json(<String, Object?>{
            'suggestions': <Object?>[
              <String, Object?>{
                ..._suggestionJson(),
                'suggested_type': 'advice',
                'source_ref': 'proactive:deadline:2026-10-14:task_1',
              },
            ],
            'used_local_tasks': true,
            'used_timetree': true,
            'calendar_status': 'available',
          });
        case '/pis/v1/timetree/operations/prepare':
          final body = _body(request);
          expect(body['idempotency_key'], 'request_12345678');
          expect(body['kind'], 'create');
          return _json(_previewJson());
        case '/pis/v1/timetree/operations/confirm':
          expect(_body(request), <String, Object?>{'operation_id': _operationId});
          return _json(<String, Object?>{
            'operation_id': _operationId,
            'status': 'succeeded',
            'message': 'TimeTree confirmed the event.',
            'event': _eventJson(),
          });
        case '/pis/v1/timetree/operations/$_operationId':
          return _json(<String, Object?>{
            'operation_id': _operationId,
            'status': 'succeeded',
            'message': 'TimeTree confirmed the event.',
            'event': _eventJson(),
          });
      }
      return http.Response('', 404);
    });
    final client = _client(httpClient);

    final integrations = await client.integrationStatus();
    expect(integrations.localIntelligence, isTrue);
    expect(integrations.timeTree, isTrue);
    expect(integrations.genericCalendarUsesTimeTree, isFalse);

    final calendars = await client.calendars();
    expect(calendars.single.name, 'Personal');

    final events = await client.events(
      query: PrivacyIntelligenceEventQuery(
        calendarId: 'calendar_1',
        query: 'dentist',
        startAt: DateTime.utc(2026, 10, 13),
        endAt: DateTime.utc(2026, 10, 15),
        limit: 10,
      ),
    );
    expect(events.single.uuid, 'event_1');
    expect(events.single.isRecurring, isFalse);

    final extraction = await client.extract(
      PrivacyIntelligenceExtractionRequest(
        sourceRef: 'note_1',
        sourceKind: PrivacyIntelligenceSourceKind.ownerNote,
        authorizationBasis: PrivacyIntelligenceAuthorizationBasis.selfOnly,
        text: 'I need to call the dentist.',
        timezone: 'America/Toronto',
        now: DateTime.utc(2026, 10, 13, 16),
      ),
    );
    expect(extraction.extractor, 'ollama-structured-v1');
    expect(extraction.suggestions.single.suggestedType, PrivacyIntelligenceSuggestionType.task);

    final assistant = await client.assistant(
      PrivacyIntelligenceAssistantRequest(
        message: 'What is on my plate?',
        timezone: 'America/Toronto',
        now: DateTime.utc(2026, 10, 13, 16),
        openTasks: <PrivacyIntelligenceLocalTaskContext>[
          PrivacyIntelligenceLocalTaskContext(taskId: 'task_1', title: 'Call dentist', inToday: true),
        ],
      ),
    );
    expect(assistant.usedLocalTasks, isTrue);
    expect(assistant.usedTimeTree, isTrue);
    expect(assistant.events.single.calendarId, 'calendar_1');

    final proactive = await client.evaluateProactive(
      PrivacyIntelligenceProactiveEvaluationRequest(
        timezone: 'America/Toronto',
        now: DateTime.utc(2026, 10, 13, 16),
        openTasks: <PrivacyIntelligenceLocalTaskContext>[
          PrivacyIntelligenceLocalTaskContext(taskId: 'task_1', title: 'Call dentist'),
        ],
      ),
    );
    expect(proactive.suggestions.single.suggestedType, PrivacyIntelligenceSuggestionType.advice);
    expect(proactive.calendarStatus, 'available');

    final prepare = PrivacyIntelligenceCalendarOperationRequest(
      kind: PrivacyIntelligenceCalendarOperationKind.create,
      idempotencyKey: 'request_12345678',
      calendarId: 'calendar_1',
      event: _draft(),
    );
    final preview = await client.prepareCalendarOperation(prepare);
    expect(preview.operationId, _operationId);
    expect(preview.title, 'Dentist');
    expect(preview.expiresAt, DateTime.utc(2026, 10, 13, 16, 15));

    final confirmed = await client.confirmCalendarOperation(_operationId);
    expect(confirmed.status, PrivacyIntelligenceOperationStatus.succeeded);
    expect(confirmed.event!.uuid, 'event_1');

    final reconciled = await client.calendarOperationStatus(_operationId);
    expect(reconciled.status, PrivacyIntelligenceOperationStatus.succeeded);

    expect(requests, hasLength(9));
    expect(requests.where((request) => request.method == 'POST'), hasLength(5));
  });

  test('confirm write is attempted exactly once on server failure', () async {
    var calls = 0;
    final client = _client(MockClient((request) async {
      calls++;
      return http.Response(
        jsonEncode(<String, Object?>{'detail': 'private provider error'}),
        503,
      );
    }));

    await expectLater(
      client.confirmCalendarOperation(_operationId),
      throwsA(
        isA<PrivacyIntelligenceClientException>()
            .having((error) => error.kind, 'kind', PrivacyIntelligenceFailureKind.serviceUnavailable)
            .having((error) => error.statusCode, 'statusCode', 503),
      ),
    );
    expect(calls, 1);
  });

  test('confirm timeout is bounded and never retried', () async {
    var calls = 0;
    final client = PrivacyIntelligenceClient(
      credentials: _StaticCredentials(_credentials()),
      httpClient: MockClient((request) {
        calls++;
        return Completer<http.Response>().future;
      }),
      timeouts: const PrivacyIntelligenceTimeouts(
        credentialLookup: Duration(milliseconds: 20),
        read: Duration(milliseconds: 20),
        model: Duration(milliseconds: 20),
        write: Duration(milliseconds: 20),
      ),
    );

    await expectLater(
      client.confirmCalendarOperation(_operationId),
      throwsA(
        isA<PrivacyIntelligenceClientException>().having(
          (error) => error.kind,
          'kind',
          PrivacyIntelligenceFailureKind.timeout,
        ),
      ),
    );
    expect(calls, 1);
  });

  test('errors redact private URL, owner, token, request text, and server body', () async {
    const privateText = 'secret appointment with Dr Private';
    final client = _client(MockClient((request) async {
      return http.Response(
        jsonEncode(<String, Object?>{'detail': 'server echoed $_token $_owner $privateText'}),
        401,
      );
    }));

    Object? captured;
    try {
      await client.assistant(
        PrivacyIntelligenceAssistantRequest(
          message: privateText,
          timezone: 'UTC',
          now: DateTime.utc(2026, 10, 13),
        ),
      );
    } catch (error) {
      captured = error;
    }
    expect(captured, isA<PrivacyIntelligenceClientException>());
    final rendered = captured.toString();
    expect(rendered, contains('unauthorized'));
    expect(rendered, isNot(contains('private-ubuntu')));
    expect(rendered, isNot(contains(_owner)));
    expect(rendered, isNot(contains(_token)));
    expect(rendered, isNot(contains(privateText)));
    expect(rendered, isNot(contains('server echoed')));
  });

  test('malformed response is a compact invalid-response failure', () async {
    final client = _client(MockClient((request) async {
      return _json(<String, Object?>{
        'local_intelligence': 'yes',
        'timetree': true,
        'generic_calendar_uses_timetree': false,
        'private_detail': 'must not escape',
      });
    }));

    await expectLater(
      client.integrationStatus(),
      throwsA(
        isA<PrivacyIntelligenceClientException>().having(
          (error) => error.kind,
          'kind',
          PrivacyIntelligenceFailureKind.invalidResponse,
        ),
      ),
    );
  });

  test('missing credentials fail before transport', () async {
    var calls = 0;
    final client = PrivacyIntelligenceClient(
      credentials: const _StaticCredentials(null),
      httpClient: MockClient((request) async {
        calls++;
        return _json(<Object?>[]);
      }),
    );

    await expectLater(
      client.calendars(),
      throwsA(
        isA<PrivacyIntelligenceClientException>().having(
          (error) => error.kind,
          'kind',
          PrivacyIntelligenceFailureKind.notConfigured,
        ),
      ),
    );
    expect(calls, 0);
  });
}

PrivacyIntelligenceClient _client(http.Client httpClient) => PrivacyIntelligenceClient(
      credentials: _StaticCredentials(_credentials()),
      httpClient: httpClient,
    );

PrivacyIntelligenceCredentials _credentials() => PrivacyIntelligenceCredentials(
      baseUrl: 'https://private-ubuntu.tailnet.ts.net/pis',
      ownerMappingId: _owner,
      bearerToken: _token,
    );

class _StaticCredentials implements PrivacyIntelligenceCredentialSource {
  const _StaticCredentials(this.value);
  final PrivacyIntelligenceCredentials? value;

  @override
  Future<PrivacyIntelligenceCredentials?> read() async => value;
}

http.Response _json(Object? value, [int statusCode = 200]) => http.Response(
      jsonEncode(value),
      statusCode,
      headers: const <String, String>{'content-type': 'application/json'},
    );

Map<String, Object?> _body(http.Request request) =>
    (jsonDecode(request.body) as Map).map((key, value) => MapEntry(key as String, value));

Map<String, Object?> _eventJson() => <String, Object?>{
      'uuid': 'event_1',
      'calendar_id': 'calendar_1',
      'title': 'Dentist',
      'all_day': false,
      'start_at': '2026-10-14T14:00:00Z',
      'end_at': '2026-10-14T14:30:00Z',
      'start_timezone': 'America/Toronto',
      'end_timezone': 'America/Toronto',
      'recurrences': <Object?>[],
      'author_id': 7,
      'parent_id': null,
      'deactivated_at': null,
      'location': 'Clinic',
      'note': null,
    };

Map<String, Object?> _suggestionJson() => <String, Object?>{
      'suggested_type': 'task',
      'title': 'Call dentist',
      'description': null,
      'proposed_time_text': null,
      'start_at': null,
      'end_at': null,
      'timezone': null,
      'source_ref': 'note_1',
      'supporting_excerpt': 'I need to call the dentist.',
      'uncertainty': 0.1,
      'review_state': 'pending',
    };

PrivacyIntelligenceCalendarEventDraft _draft() => PrivacyIntelligenceCalendarEventDraft(
      title: 'Dentist',
      startAt: DateTime.utc(2026, 10, 14, 14),
      endAt: DateTime.utc(2026, 10, 14, 14, 30),
      startTimezone: 'America/Toronto',
      endTimezone: 'America/Toronto',
      location: 'Clinic',
    );

Map<String, Object?> _previewJson() => <String, Object?>{
      'operation_id': _operationId,
      'kind': 'create',
      'calendar_id': 'calendar_1',
      'calendar_name': 'Personal',
      'event_uuid': null,
      'title': 'Dentist',
      'start_at': '2026-10-14T14:00:00Z',
      'end_at': '2026-10-14T14:30:00Z',
      'timezone': 'America/Toronto',
      'all_day': false,
      'recurrence_scope': 'not_recurring',
      'changes': <String>['Create event'],
      'expires_at': '2026-10-13T16:15:00Z',
    };
