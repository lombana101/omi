import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_client.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_config.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_ui.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:omi/services/privacy_capture/privacy_theme.dart';
import 'package:omi/services/privacy_capture/privacy_widgets.dart';

class _Credentials implements PrivacyIntelligenceCredentialSource {
  @override
  Future<PrivacyIntelligenceCredentials?> read() async => PrivacyIntelligenceCredentials(
        baseUrl: 'https://home-server.example.test:8444',
        ownerMappingId: 'owner',
        bearerToken: 'abcdefghijklmnopqrstuvwxyz012345',
      );
}

class _NoCredentials implements PrivacyIntelligenceCredentialSource {
  @override
  Future<PrivacyIntelligenceCredentials?> read() async => null;
}

Widget _app(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PrivacyScope(
        theme: signalGreen,
        child: Scaffold(body: child),
      ),
    );

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int attempts = 100,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for ${finder.describeMatch(Plurality.one)}');
}

Map<String, Object?> _eventJson({String title = 'Existing TimeTree event'}) => <String, Object?>{
      'uuid': 'event_1',
      'calendar_id': 'calendar_1',
      'title': title,
      'all_day': false,
      'start_at': '2026-10-14T18:00:00Z',
      'end_at': '2026-10-14T19:00:00Z',
      'start_timezone': 'America/Toronto',
      'end_timezone': 'America/Toronto',
      'recurrences': <Object?>[],
    };

void main() {
  testWidgets('renders real calendar data and confirms an exact proposal only after preview', (tester) async {
    final store = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('privacy-intelligence-widget');
      return PrivacyStore.open(directory);
    }))!;
    var prepareCalls = 0;
    var confirmCalls = 0;
    var eventReads = 0;
    final httpClient = MockClient((request) async {
      if (request.method == 'GET' && request.url.path.endsWith('/calendars')) {
        return http.Response(
            jsonEncode(<Object?>[
              <String, Object?>{'id': 'calendar_1', 'name': 'Personal'}
            ]),
            200);
      }
      if (request.method == 'GET' && request.url.path.endsWith('/events')) {
        eventReads++;
        return http.Response(
          jsonEncode(<Object?>[_eventJson(title: eventReads == 1 ? 'Existing TimeTree event' : 'Focus block')]),
          200,
        );
      }
      if (request.url.path.endsWith('/assistant')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'message': 'I prepared a reviewable change. Nothing has been written yet.',
            'events': <Object?>[],
            'task_suggestions': <Object?>[],
            'calendar_proposal': <String, Object?>{
              'kind': 'create',
              'calendar_id': 'calendar_1',
              'event': <String, Object?>{
                'title': 'Focus block',
                'all_day': false,
                'start_at': '2026-10-15T18:00:00Z',
                'end_at': '2026-10-15T20:00:00Z',
                'start_timezone': 'America/Toronto',
                'end_timezone': 'America/Toronto',
                'category': 1,
                'attendees': <Object?>[],
                'recurrences': <Object?>[],
                'alerts': <Object?>[],
                'file_uuids': <Object?>[],
              },
              'explanation': 'Review this exact focus block.',
            },
            'used_local_tasks': true,
            'used_timetree': true,
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/prepare')) {
        prepareCalls++;
        return http.Response(
          jsonEncode(<String, Object?>{
            'operation_id': '0123456789abcdef0123456789abcdef',
            'kind': 'create',
            'calendar_id': 'calendar_1',
            'calendar_name': 'Personal',
            'title': 'Focus block',
            'start_at': '2026-10-15T18:00:00Z',
            'end_at': '2026-10-15T20:00:00Z',
            'timezone': 'America/Toronto',
            'all_day': false,
            'recurrence_scope': 'not_recurring',
            'changes': <String>['Create this event'],
            'expires_at': '2026-10-15T17:15:00Z',
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/confirm')) {
        confirmCalls++;
        return http.Response(
          jsonEncode(<String, Object?>{
            'operation_id': '0123456789abcdef0123456789abcdef',
            'status': 'succeeded',
            'message': 'TimeTree confirmed that the event was created',
            'event': _eventJson(title: 'Focus block'),
          }),
          200,
        );
      }
      fail('Unexpected request: ${request.method} ${request.url.path}');
    });
    final client = PrivacyIntelligenceClient(credentials: _Credentials(), httpClient: httpClient);
    await tester.pumpWidget(
      _app(
        PrivacyAssistantTab(
          store: store,
          now: DateTime.utc(2026, 10, 13, 12),
          onChanged: () async {},
          client: client,
          timezoneLoader: () async => 'America/Toronto',
        ),
      ),
    );
    await _pumpUntil(tester, find.text('Existing TimeTree event'));

    expect(find.text('Existing TimeTree event'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('privacy_assistant_message')), 'Add a focus block to TimeTree');
    await tester.tap(find.byKey(const Key('privacy_assistant_ask')));
    await _pumpUntil(tester, find.text('I prepared a reviewable change. Nothing has been written yet.'));
    expect(find.text('I prepared a reviewable change. Nothing has been written yet.'), findsOneWidget);
    expect(confirmCalls, 0);

    await tester.ensureVisible(find.byKey(const Key('privacy_review_calendar_proposal')));
    await tester.tap(find.byKey(const Key('privacy_review_calendar_proposal')));
    await _pumpUntil(tester, find.text(PrivacyCopy.confirmCalendarChange));
    expect(prepareCalls, 1);
    expect(confirmCalls, 0);
    expect(find.textContaining('Personal'), findsWidgets);
    expect(find.textContaining('Focus block'), findsWidgets);
    expect(find.textContaining('America/Toronto'), findsWidgets);
    expect(find.textContaining('One non-recurring event'), findsOneWidget);
    expect(find.textContaining('Create this event'), findsOneWidget);

    await tester.tap(find.text(PrivacyCopy.confirmCalendarChange));
    await _pumpUntil(tester, find.text('TimeTree confirmed that the event was created'));
    expect(confirmCalls, 1);
    expect(eventReads, 2);
    expect(find.text('TimeTree confirmed that the event was created'), findsOneWidget);
    expect(find.text('Focus block'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('backend unavailability leaves local tasks usable', (tester) async {
    final store = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('privacy-intelligence-offline');
      final value = await PrivacyStore.open(directory);
      await value.createTask(title: 'Local task survives');
      return value;
    }))!;
    final client = PrivacyIntelligenceClient(
      credentials: _NoCredentials(),
      httpClient: MockClient((_) async => fail('transport must not run without credentials')),
    );
    await tester.pumpWidget(
      _app(
        PrivacyAssistantTab(
          store: store,
          now: DateTime.utc(2026, 10, 13),
          onChanged: () async {},
          client: client,
          timezoneLoader: () async => 'America/Toronto',
        ),
      ),
    );
    await _pumpUntil(tester, find.text(PrivacyCopy.noEvents));
    await tester.enterText(find.byKey(const Key('privacy_assistant_message')), 'What is on my list?');
    await tester.tap(find.byKey(const Key('privacy_assistant_ask')));
    await _pumpUntil(tester, find.text(PrivacyCopy.intelligenceNotConfigured));

    expect(find.text(PrivacyCopy.intelligenceNotConfigured), findsOneWidget);
    final tasks = (await tester.runAsync(store.tasks))!;
    expect(tasks.single.title, 'Local task survives');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a complete settings submission repairs partial secure configuration', (tester) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      PrivacyIntelligenceCredentialStore.baseUrlKey: 'https://stale.example.test',
      PrivacyIntelligenceCredentialStore.ownerMappingIdKey: 'stale-owner',
    });
    await tester.pumpWidget(_app(const SingleChildScrollView(child: PrivacyIntelligenceSettings())));
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('privacy_intelligence_url')),
      'https://ubuntu.tailnet.example:8444',
    );
    await tester.enterText(find.byKey(const Key('privacy_intelligence_owner')), 'owner');
    await tester.enterText(
      find.byKey(const Key('privacy_intelligence_token')),
      'abcdefghijklmnopqrstuvwxyz012345',
    );
    await tester.tap(find.text(PrivacyCopy.save));
    await _pumpUntil(tester, find.text(PrivacyCopy.intelligenceSaved));

    final repaired = await PrivacyIntelligenceCredentialStore().read();
    expect(repaired, isNotNull);
    expect(repaired!.baseUrl, 'https://ubuntu.tailnet.example:8444');
    expect(repaired.ownerMappingId, 'owner');
    expect(repaired.bearerToken, 'abcdefghijklmnopqrstuvwxyz012345');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
