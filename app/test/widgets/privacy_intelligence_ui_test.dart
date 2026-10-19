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
import 'package:omi/services/privacy_capture/privacy_quick_capture.dart';
import 'package:omi/services/privacy_capture/privacy_shell.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
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

Future<void> _pumpUntilIoBackedWidget(
  WidgetTester tester,
  Finder finder, {
  int attempts = 30,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    await tester.pump(const Duration(milliseconds: 10));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for ${finder.describeMatch(Plurality.one)}');
}

Future<PrivacyStore> _openStore(WidgetTester tester, String prefix) async {
  final directory = await tester.runAsync(() => Directory.systemTemp.createTemp(prefix));
  addTearDown(() {
    if (directory != null && directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return (await tester.runAsync(() => PrivacyStore.open(directory!)))!;
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
  testWidgets('interrupted session reprocess gesture calls intelligence and renders saved suggestions', (tester) async {
    final store = await _openStore(tester, 'privacy-reprocess-gesture');
    final now = DateTime.now();
    final session = (await tester.runAsync(() async {
      final opened = await store.openSession(
          captureId: 'gesture-capture',
          purpose: 'personal',
          ownerPurpose: 'synthetic task',
          consentBasis: 'self_only',
          protocolVersion: 1,
          policyRevision: 1,
          at: now,
          retentionChoice: PrivacyRetentionChoice.untilDeleted);
      await store.upsertChunk(captureId: 'gesture-capture', sequence: 1, machineText: 'Buy milk tomorrow.');
      await store.markTerminal(captureId: 'gesture-capture', outcome: 'interrupted', incomplete: true, at: now);
      return opened.value!;
    }))!;
    var calls = 0;
    final client = PrivacyIntelligenceClient(
        credentials: _Credentials(),
        httpClient: MockClient((request) async {
          calls++;
          expect(request.url.path, '/v1/intelligence/extract');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
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
                    'review_state': 'pending',
                  }
                ]
              }),
              200);
        }));
    await tester.binding.setSurfaceSize(const Size(800, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(PrivacyShell(
        store: store,
        initialTab: 1,
        intelligenceClient: client,
        themeStore: MemoryPrivacyThemeStore(),
        quickPreferences: MemoryQuickSelfCapturePreferences())));
    final open = find.byKey(Key('privacy_reprocess_${session.localId}'));
    await _pumpUntilIoBackedWidget(tester, open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    await _pumpUntilIoBackedWidget(tester, find.byKey(const Key('privacy_session_task_actions')));
    await tester.tap(find.text(PrivacyCopy.taskActions));
    await tester.pumpAndSettle();
    final action = find.byKey(const Key('privacy_reprocess_session'));
    await _pumpUntilIoBackedWidget(tester, action);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await _pumpUntilIoBackedWidget(tester, find.textContaining('found. Review'));
    expect(calls, 1);
    expect((await tester.runAsync(store.pendingCandidates))!.single.proposedText, 'Buy milk');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('proactive failure does not block the calendar refresh', (tester) async {
    final store = await _openStore(tester, 'privacy-proactive-calendar-fallback');
    final paths = <String>[];
    final client = PrivacyIntelligenceClient(
      credentials: _Credentials(),
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/intelligence/proactive/evaluate')) {
          return http.Response('', 404);
        }
        if (request.url.path.endsWith('/timetree/calendars')) {
          return http.Response(
            jsonEncode(<Object?>[
              <String, Object?>{'id': 'calendar_1', 'name': 'Personal'},
            ]),
            200,
          );
        }
        if (request.url.path.endsWith('/timetree/events')) {
          return http.Response(jsonEncode(<Object?>[_eventJson()]), 200);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      }),
    );

    await tester.pumpWidget(
      _app(
        PrivacyAssistantTab(
          store: store,
          now: DateTime.utc(2026, 10, 13, 12),
          onChanged: () async {},
          onOpenSwitcher: () {},
          client: client,
          timezoneLoader: () async => 'America/Toronto',
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('privacy_intelligence_refresh')));
    await _pumpUntil(tester, find.text('Existing TimeTree event'));

    expect(
        paths,
        containsAllInOrder(<String>[
          '/v1/intelligence/proactive/evaluate',
          '/v1/timetree/calendars',
          '/v1/timetree/events',
        ]));
    expect(find.text('Existing TimeTree event'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('saved proactive advice survives a subsequent calendar failure', (tester) async {
    final store = await _openStore(tester, 'privacy-proactive-task-only');
    final task = (await tester.runAsync(
      () => store.createTask(
        title: 'Finish Memoria improvements',
        dueAt: DateTime.utc(2026, 10, 14, 17),
      ),
    ))!;
    var changed = 0;
    final client = PrivacyIntelligenceClient(
      credentials: _Credentials(),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/intelligence/proactive/evaluate')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'suggestions': <Object?>[
                <String, Object?>{
                  'suggested_type': 'advice',
                  'title': 'Plan for Finish Memoria improvements',
                  'description': 'The task is due tomorrow. Protect time today.',
                  'proposed_time_text': 'today',
                  'source_ref': 'proactive:deadline:2026-10-14:${task.value!.taskId}',
                  'supporting_excerpt': 'Finish Memoria improvements',
                  'uncertainty': 0.0,
                  'review_state': 'pending',
                },
              ],
              'used_local_tasks': true,
              'used_timetree': false,
              'calendar_status': 'unavailable',
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/timetree/calendars')) {
          return http.Response('', 503);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      }),
    );

    await tester.pumpWidget(
      _app(
        PrivacyAssistantTab(
          store: store,
          now: DateTime.utc(2026, 10, 13, 12),
          onChanged: () async => changed++,
          onOpenSwitcher: () {},
          client: client,
          timezoneLoader: () async => 'America/Toronto',
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('privacy_intelligence_refresh')));
    await _pumpUntilIoBackedWidget(tester, find.text(PrivacyCopy.pendingSuggestionsSaved));

    expect(find.text(PrivacyCopy.intelligenceUnavailable), findsNothing);
    expect(changed, 1);
    final pending = (await tester.runAsync(store.pendingCandidates))!;
    expect(pending.single.suggestedType, 'advice');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('manual extraction uses a stable private source reference', (tester) async {
    final store = await _openStore(tester, 'privacy-manual-source');
    final sourceRefs = <String>[];
    final client = PrivacyIntelligenceClient(
      credentials: _Credentials(),
      httpClient: MockClient((request) async {
        expect(request.url.path, endsWith('/intelligence/extract'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final sourceRef = body['source_ref'] as String;
        sourceRefs.add(sourceRef);
        return http.Response(
          jsonEncode(<String, Object?>{
            'extractor': 'ollama-structured-v1',
            'suggestions': <Object?>[
              <String, Object?>{
                'suggested_type': 'commitment',
                'title': 'Finish Memoria improvements',
                'source_ref': sourceRef,
                'supporting_excerpt': 'finish the Memoria improvements',
                'uncertainty': 0.1,
                'review_state': 'pending',
              },
            ],
          }),
          200,
        );
      }),
    );

    await tester.pumpWidget(
      _app(
        PrivacyAssistantTab(
          store: store,
          now: DateTime.utc(2026, 10, 13, 12),
          onChanged: () async {},
          onOpenSwitcher: () {},
          client: client,
          timezoneLoader: () async => 'America/Toronto',
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('privacy_assistant_message')),
      'I need   to finish the Memoria improvements before Friday.',
    );
    await tester.tap(find.byKey(const Key('privacy_extract_manual')));
    await _pumpUntilIoBackedWidget(tester, find.text(PrivacyCopy.pendingSuggestionsSaved));
    final first = (await tester.runAsync(store.pendingCandidates))!.single;
    await tester.runAsync(() => store.dismissCandidate(first.candidateId));

    await tester.enterText(
      find.byKey(const Key('privacy_assistant_message')),
      'i need to finish the memoria improvements before friday.',
    );
    await tester.tap(find.byKey(const Key('privacy_extract_manual')));
    await _pumpUntilIoBackedWidget(tester, find.text(PrivacyCopy.noGroundedActions));

    expect(sourceRefs[0], sourceRefs[1]);
    expect(sourceRefs.first, startsWith('manual:'));
    expect(sourceRefs.first, isNot(contains('memoria')));
    expect(await tester.runAsync(store.pendingCandidates), isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('assistant does not claim a dismissed duplicate was saved', (tester) async {
    final store = await _openStore(tester, 'privacy-assistant-dismissed-duplicate');
    await tester.runAsync(() async {
      final candidate = await store.addIntelligenceCandidate(
        sourceRef: 'assistant:abc',
        suggestedType: 'task',
        title: 'Email the deck',
        excerpt: 'Email the deck',
        uncertainty: 0.1,
      );
      await store.dismissCandidate(candidate.value!.candidateId);
    });
    final client = PrivacyIntelligenceClient(
      credentials: _Credentials(),
      httpClient: MockClient((request) async {
        expect(request.url.path, endsWith('/assistant'));
        return http.Response(
          jsonEncode(<String, Object?>{
            'message': 'The earlier suggestion remains dismissed.',
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

    await tester.pumpWidget(
      _app(
        PrivacyAssistantTab(
          store: store,
          now: DateTime.utc(2026, 10, 13, 12),
          onChanged: () async {},
          onOpenSwitcher: () {},
          client: client,
          timezoneLoader: () async => 'America/Toronto',
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('privacy_assistant_message')),
      'Remind me to email the deck.',
    );
    await tester.tap(find.byKey(const Key('privacy_assistant_ask')));
    await _pumpUntilIoBackedWidget(
      tester,
      find.text('The earlier suggestion remains dismissed.'),
    );

    expect(find.text(PrivacyCopy.pendingSuggestionsSaved), findsNothing);
    expect(await tester.runAsync(store.pendingCandidates), isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('suggestion cards render the saved rationale', (tester) async {
    final now = DateTime(2026, 10, 13, 12);
    final store = await _openStore(tester, 'privacy-advice-rationale');
    final candidate = (await tester.runAsync(
      () => store.addIntelligenceCandidate(
        sourceRef: 'proactive:deadline:2026-10-14:task_1',
        suggestedType: 'advice',
        title: 'Plan for Finish Memoria improvements',
        excerpt: 'Finish Memoria improvements',
        description: 'Tomorrow is calendar-heavy, so protect time today.',
        proposedTimeText: 'today',
        uncertainty: 0,
        at: now,
      ),
    ))!;

    await tester.pumpWidget(
      _app(
        PrivacyShell(
          store: store,
          initialTab: 2,
          clock: () => now,
          quickPreferences: MemoryQuickSelfCapturePreferences(),
          themeStore: MemoryPrivacyThemeStore(),
          findPendant: () async => PrivacyCopy.notConnected,
        ),
      ),
    );
    await _pumpUntil(tester, find.byKey(const Key('privacy_task_category_suggestions')));
    await tester.tap(find.byKey(const Key('privacy_task_category_suggestions')));
    await _pumpUntil(
      tester,
      find.byKey(Key('privacy_suggestion_description_${candidate.value!.candidateId}')),
    );

    expect(
      find.byKey(Key('privacy_suggestion_description_${candidate.value!.candidateId}')),
      findsOneWidget,
    );
    expect(find.text('Tomorrow is calendar-heavy, so protect time today.'), findsOneWidget);
    expect(find.byKey(Key('privacy_dismiss_${candidate.value!.candidateId}')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('renders real calendar data and confirms an exact proposal only after preview', (tester) async {
    final store = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('privacy-intelligence-widget');
      return PrivacyStore.open(directory);
    }))!;
    var prepareCalls = 0;
    var confirmCalls = 0;
    var eventReads = 0;
    final httpClient = MockClient((request) async {
      if (request.url.path.endsWith('/intelligence/proactive/evaluate')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'suggestions': <Object?>[],
            'used_local_tasks': true,
            'used_timetree': true,
            'calendar_status': 'available',
          }),
          200,
        );
      }
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
