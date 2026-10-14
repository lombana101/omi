import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/privacy_capture/privacy_intelligence_models.dart';

void main() {
  test('extraction request binds source kind to its authorization basis', () {
    final request = PrivacyIntelligenceExtractionRequest(
      sourceRef: 'session-1:chunk-2',
      sourceKind: PrivacyIntelligenceSourceKind.consentedConversation,
      authorizationBasis: PrivacyIntelligenceAuthorizationBasis.participantsConsented,
      text: 'I will send the follow-up tomorrow.',
      timezone: 'America/Toronto',
      now: DateTime.utc(2026, 10, 13, 15),
    );
    expect(request.toJson(), <String, Object?>{
      'source_ref': 'session-1:chunk-2',
      'source_kind': 'consented_conversation',
      'authorization_basis': 'participants_consented',
      'text': 'I will send the follow-up tomorrow.',
      'timezone': 'America/Toronto',
      'now': '2026-10-13T15:00:00.000Z',
    });

    expect(
      () => PrivacyIntelligenceExtractionRequest(
        sourceRef: 'session-1:chunk-2',
        sourceKind: PrivacyIntelligenceSourceKind.consentedConversation,
        authorizationBasis: PrivacyIntelligenceAuthorizationBasis.selfOnly,
        text: 'private text',
        timezone: 'UTC',
        now: DateTime.utc(2026),
      ),
      throwsArgumentError,
    );
  });

  test('event query is typed, bounded, and emits timezone-aware instants', () {
    final query = PrivacyIntelligenceEventQuery(
      calendarId: 'calendar_1',
      query: 'dentist',
      startAt: DateTime.utc(2026, 10, 13),
      endAt: DateTime.utc(2026, 10, 14),
      limit: 25,
    );
    expect(query.toQueryParameters(), <String, String>{
      'calendar_id': 'calendar_1',
      'query': 'dentist',
      'start_at': '2026-10-13T00:00:00.000Z',
      'end_at': '2026-10-14T00:00:00.000Z',
      'limit': '25',
    });
    expect(
      () => PrivacyIntelligenceEventQuery(
        startAt: DateTime.utc(2026, 10, 14),
        endAt: DateTime.utc(2026, 10, 13),
      ),
      throwsArgumentError,
    );
  });

  test('calendar patch represents explicit nullable clears without untyped maps', () {
    final patch = PrivacyIntelligenceCalendarEventPatch(
      title: 'Updated title',
      clearNote: true,
      clearLocation: true,
      clearLabelId: true,
      attendees: const <int>[],
    );
    expect(patch.toJson(), <String, Object?>{
      'title': 'Updated title',
      'note': null,
      'location': null,
      'label_id': null,
      'attendees': <int>[],
    });
    expect(() => PrivacyIntelligenceCalendarEventPatch(), throwsArgumentError);
  });

  test('assistant calendar proposal converts to a validated prepare request', () {
    final proposal = PrivacyIntelligenceCalendarWriteProposal.fromJson(<String, Object?>{
      'kind': 'create',
      'calendar_id': 'calendar_1',
      'event_uuid': null,
      'event': <String, Object?>{
        'title': 'Dentist',
        'all_day': false,
        'start_at': '2026-10-14T14:00:00Z',
        'end_at': '2026-10-14T14:30:00Z',
        'start_timezone': 'America/Toronto',
        'end_timezone': 'America/Toronto',
        'note': null,
        'location': null,
        'label_id': null,
        'category': 1,
        'attendees': <int>[],
        'recurrences': <String>[],
        'alerts': <Object?>[],
        'file_uuids': <String>[],
      },
      'changes': null,
      'recurrence_scope': null,
      'explanation': 'Review this exact event.',
    });
    final request = proposal.prepareRequest(idempotencyKey: 'request_12345678');
    expect(request.kind, PrivacyIntelligenceCalendarOperationKind.create);
    expect(request.toJson()['calendar_id'], 'calendar_1');
    expect((request.toJson()['event'] as Map<String, Object?>)['title'], 'Dentist');
  });

  test('response timestamps must carry a timezone', () {
    expect(
      () => PrivacyIntelligenceEvent.fromJson(<String, Object?>{
        'uuid': 'event_1',
        'calendar_id': 'calendar_1',
        'title': 'Private title',
        'all_day': false,
        'start_at': '2026-10-14T14:00:00',
        'end_at': '2026-10-14T15:00:00Z',
        'start_timezone': 'UTC',
        'end_timezone': 'UTC',
        'recurrences': <Object?>[],
      }),
      throwsFormatException,
    );
  });

  test('uncertain operation outcome is explicitly reconciliation-required', () {
    final outcome = PrivacyIntelligenceCalendarOperationOutcome.fromJson(<String, Object?>{
      'operation_id': '0123456789abcdef0123456789abcdef',
      'status': 'uncertain',
      'message': 'Inspect the calendar before retrying.',
      'event': null,
    });
    expect(outcome.status, PrivacyIntelligenceOperationStatus.uncertain);
    expect(outcome.requiresReconciliation, isTrue);
  });
}
