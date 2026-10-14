import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_quick_capture.dart';
import 'package:omi/services/privacy_capture/privacy_shell.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:omi/services/privacy_capture/privacy_suggestion.dart';
import 'package:omi/services/privacy_capture/privacy_theme.dart';
import 'package:omi/services/privacy_capture/privacy_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('privacy usability contract', () {
    testWidgets('the header app switcher reaches every destination without a bottom NavigationBar', (tester) async {
      final store = await _openStore(tester, 'privacy-usability-navigation');

      await _pumpShell(tester, store: store, quickPreferences: _readyQuickPreferences());

      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byKey(const Key('privacy_app_switcher')), findsOneWidget);

      for (final destination in <(int, String)>[
        (1, PrivacyCopy.sessions),
        (2, PrivacyCopy.tasks),
        (3, PrivacyCopy.assistant),
        (4, PrivacyCopy.settings),
        (0, PrivacyCopy.capture),
      ]) {
        await tester.tap(find.byKey(const Key('privacy_app_switcher')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('privacy_destination_${destination.$1}')), findsOneWidget);

        await tester.tap(find.byKey(Key('privacy_destination_${destination.$1}')));
        await tester.pumpAndSettle();
        expect(find.text(destination.$2), findsWidgets);
        expect(find.byKey(const Key('privacy_app_switcher')), findsOneWidget);
      }
    });

    testWidgets('ready quick mode keeps manual capture fields behind disclosure', (tester) async {
      final store = await _openStore(tester, 'privacy-usability-quick-ready');

      await _pumpShell(tester, store: store, quickPreferences: _readyQuickPreferences());

      expect(find.byKey(const Key('privacy_quick_ready')), findsOneWidget);
      expect(find.byKey(const Key('privacy_quick_setup')), findsNothing);
      expect(find.text(PrivacyCopy.quickDoubleTap), findsOneWidget);
      expect(find.byKey(const Key('privacy_purpose')), findsNothing);
      expect(find.byKey(const Key('privacy_self_only')), findsNothing);
      expect(find.byKey(const Key('privacy_mixed')), findsNothing);

      await tester.tap(find.byKey(const Key('privacy_manual_options')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('privacy_purpose')), findsOneWidget);
      expect(find.byKey(const Key('privacy_self_only')), findsOneWidget);
      expect(find.byKey(const Key('privacy_mixed')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unconfigured quick mode presents one setup action instead of the full form', (tester) async {
      final store = await _openStore(tester, 'privacy-usability-quick-setup');

      await _pumpShell(
        tester,
        store: store,
        quickPreferences: MemoryQuickSelfCapturePreferences(),
      );

      expect(find.byKey(const Key('privacy_quick_setup')), findsOneWidget);
      expect(find.byKey(const Key('privacy_quick_ready')), findsNothing);
      expect(find.byKey(const Key('privacy_purpose')), findsNothing);
      expect(find.byKey(const Key('privacy_self_only')), findsNothing);
      expect(find.byKey(const Key('privacy_mixed')), findsNothing);
    });

    testWidgets('Quick Self Capture requires the owner confirmation and persists a ready configuration',
        (tester) async {
      final store = await _openStore(tester, 'privacy-usability-quick-confirmation');
      final preferences = MemoryQuickSelfCapturePreferences();

      await _pumpShell(tester, store: store, quickPreferences: preferences);
      await tester.tap(find.byKey(const Key('privacy_quick_setup')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('privacy_quick_purpose_personalNote')));
      await tester.pump();
      final retention = find.byKey(const Key('privacy_quick_retention_hours24'));
      await tester.ensureVisible(retention);
      await tester.pumpAndSettle();
      await tester.tap(retention);
      await tester.pump();
      await _pumpUntil(tester, () async {
        final settings = await preferences.load();
        return settings.purpose == QuickSelfCapturePurpose.personalNote &&
            settings.retention == PrivacyRetentionChoice.hours24;
      });

      final toggle = find.byKey(const Key('privacy_quick_toggle'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text(PrivacyCopy.quickAssertion), findsWidgets);
      expect((await preferences.load()).enabled, isFalse, reason: 'opening the confirmation is not consent');

      await tester.tap(find.widgetWithText(TextButton, PrivacyCopy.cancel));
      await tester.pumpAndSettle();
      expect((await preferences.load()).enabled, isFalse);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, PrivacyCopy.enable));
      await tester.pumpAndSettle();
      await _pumpUntil(tester, () async => (await preferences.load()).ready);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('privacy_quick_ready')), findsOneWidget);
      expect(find.text(PrivacyCopy.quickDoubleTap), findsOneWidget);
    });

    testWidgets('Tasks displays exactly one populated category at a time', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = await _openStore(tester, 'privacy-usability-task-categories');
      await _seedTaskWorkspace(tester, store);

      await _pumpShell(
        tester,
        store: store,
        quickPreferences: _readyQuickPreferences(),
        initialTab: 2,
        clock: () => _now,
      );

      _expectOnlyVisible('Today contract task', hidden: const [
        'Inbox contract task',
        'Launch Project',
        'Send the usability draft tomorrow',
        'Completed contract task',
      ]);
      final todaySemantics =
          tester.getSemantics(find.byKey(const Key('privacy_task_category_today'))).getSemanticsData().flagsCollection;
      expect(todaySemantics.isButton, isTrue);
      expect(todaySemantics.isSelected.toBoolOrNull(), isTrue);

      await _selectTaskCategory(tester, 'inbox');
      _expectOnlyVisible('Inbox contract task', hidden: const [
        'Today contract task',
        'Launch Project',
        'Send the usability draft tomorrow',
        'Completed contract task',
      ]);
      final inboxSemantics =
          tester.getSemantics(find.byKey(const Key('privacy_task_category_inbox'))).getSemanticsData().flagsCollection;
      expect(inboxSemantics.isSelected.toBoolOrNull(), isTrue);

      await _selectTaskCategory(tester, 'projects');
      _expectOnlyVisible('Launch Project', hidden: const [
        'Today contract task',
        'Inbox contract task',
        'Send the usability draft tomorrow',
        'Completed contract task',
      ]);

      await _selectTaskCategory(tester, 'suggestions');
      _expectOnlyVisible('Send the usability draft tomorrow', hidden: const [
        'Today contract task',
        'Inbox contract task',
        'Launch Project',
        'Completed contract task',
      ]);

      await _selectTaskCategory(tester, 'completed');
      _expectOnlyVisible('Completed contract task', hidden: const [
        'Today contract task',
        'Inbox contract task',
        'Launch Project',
        'Send the usability draft tomorrow',
      ]);
      semantics.dispose();
    });

    testWidgets('compact task cards disclose editing only after the card opens', (tester) async {
      final store = await _openStore(tester, 'privacy-usability-task-detail');
      await _seedTaskWorkspace(tester, store);

      await _pumpShell(
        tester,
        store: store,
        quickPreferences: _readyQuickPreferences(),
        initialTab: 2,
        clock: () => _now,
      );
      await _selectTaskCategory(tester, 'inbox');

      expect(find.text('Inbox contract task'), findsOneWidget);
      expect(find.byType(TextField), findsNothing, reason: 'task rows are scan-first, not permanent editors');

      await tester.tap(find.text('Inbox contract task'));
      await tester.pumpAndSettle();

      expect(find.text(PrivacyCopy.taskDetails), findsWidgets);
      expect(find.byType(TextField), findsWidgets);
      expect(find.text(PrivacyCopy.saveEdits), findsOneWidget);
      expect(find.text(PrivacyCopy.delete), findsOneWidget);
    });

    testWidgets('completing an Inbox task targets the exact task ID that was tapped', (tester) async {
      final store = await _openStore(tester, 'privacy-usability-task-complete-id');
      late PrivacyTaskRecord first;
      late PrivacyTaskRecord second;
      await tester.runAsync(() async {
        first = (await store.createTask(title: 'First inbox task', at: _now)).value!;
        second = (await store.createTask(title: 'Second inbox task', at: _now)).value!;
      });

      await _pumpShell(
        tester,
        store: store,
        quickPreferences: _readyQuickPreferences(),
        initialTab: 2,
        clock: () => _now,
      );
      await _selectTaskCategory(tester, 'inbox');

      expect(find.text(first.title), findsOneWidget);
      expect(find.text(second.title), findsOneWidget);
      await tester.tap(find.byKey(Key('privacy_task_complete_${second.taskId}')));
      await _pumpUntil(tester, () async {
        final tasks = {for (final task in await store.tasks()) task.taskId: task};
        return tasks[second.taskId]?.status == 'completed';
      });
      await _pumpUntilWidget(
        tester,
        () => find.text(first.title).evaluate().length == 1 && find.text(second.title).evaluate().isEmpty,
      );

      final tasks = {for (final task in await store.tasks()) task.taskId: task};
      expect(tasks[first.taskId]?.status, 'open');
      expect(tasks[second.taskId]?.status, 'completed');
      expect(find.text(first.title), findsOneWidget);
      expect(find.text(second.title), findsNothing);

      await _selectTaskCategory(tester, 'completed');
      expect(find.text(second.title), findsOneWidget);
      expect(find.text(first.title), findsNothing);
    });

    testWidgets('project archive is confirmed and archived projects remain accessible', (tester) async {
      final store = await _openStore(tester, 'privacy-usability-project-archive');
      await _seedTaskWorkspace(tester, store);

      await _pumpShell(
        tester,
        store: store,
        quickPreferences: _readyQuickPreferences(),
        initialTab: 2,
        clock: () => _now,
      );
      await _selectTaskCategory(tester, 'projects');
      await tester.tap(find.text('Launch Project'));
      await tester.pumpAndSettle();

      expect(find.text('Project-only contract task'), findsOneWidget);
      await tester.tap(find.byTooltip('Project actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(PrivacyCopy.archive));
      await tester.pumpAndSettle();
      expect(find.text(PrivacyCopy.archiveConfirm), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, PrivacyCopy.cancel));
      await tester.pumpAndSettle();
      expect((await store.projects(includeArchived: true)).single.archived, isFalse);

      await tester.tap(find.byTooltip('Project actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(PrivacyCopy.archive));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, PrivacyCopy.archive));
      await tester.pumpAndSettle();
      await _pumpUntil(
        tester,
        () async => (await store.projects(includeArchived: true)).single.archived,
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Project actions'), findsNothing);
      expect(find.byKey(const Key('privacy_projects_archived')), findsOneWidget);
      await tester.tap(find.byKey(const Key('privacy_projects_archived')));
      await tester.pumpAndSettle();
      expect(find.text('Launch Project'), findsOneWidget);
    });

    testWidgets('suggestion editing stays hidden and opening it does not accept the suggestion', (tester) async {
      final store = await _openStore(tester, 'privacy-usability-suggestion-detail');
      await _seedTaskWorkspace(tester, store);

      await _pumpShell(
        tester,
        store: store,
        quickPreferences: _readyQuickPreferences(),
        initialTab: 2,
        clock: () => _now,
      );
      await _selectTaskCategory(tester, 'suggestions');

      expect(find.text(PrivacyCopy.suggestionNotTask), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text(PrivacyCopy.accept), findsOneWidget);
      expect(find.text(PrivacyCopy.editAccept), findsOneWidget);
      expect(find.text(PrivacyCopy.dismiss), findsOneWidget);

      await tester.tap(find.text(PrivacyCopy.editAccept));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect((await store.pendingCandidates()).length, 1, reason: 'opening an editor is not an acceptance gesture');
      expect((await store.tasks()).where((task) => task.creationOrigin == 'accepted_candidate'), isEmpty);
    });

    testWidgets('Session details finds and renders only this session suggestions with visible progress',
        (tester) async {
      Completer<void>? writeGate;
      final store = await _openStore(
        tester,
        'privacy-usability-session-suggestions',
        protect: (_) async {
          final gate = writeGate;
          if (gate != null) await gate.future;
        },
      );
      late PrivacySessionRecord session;
      await tester.runAsync(() async {
        session = await _seedSession(
          store,
          captureId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          purpose: 'Current session',
          text: 'I will send the session-only draft tomorrow.',
        );
        final otherSession = await _seedSession(
          store,
          captureId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          purpose: 'Other session',
          text: 'I will archive the unrelated notes tomorrow.',
        );
        await store.refreshSuggestions(
          service: const ActionSuggestionService(),
          sessionId: otherSession.localId,
          at: _now,
        );
      });

      await _pumpShell(
        tester,
        store: store,
        quickPreferences: _readyQuickPreferences(),
        initialTab: 1,
      );
      await tester.tap(find.byKey(Key('privacy_session_${session.localId}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final taskActions = find.byKey(const Key('privacy_session_task_actions'));
      await tester.scrollUntilVisible(
        taskActions,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(taskActions);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Archive the unrelated notes tomorrow'), findsNothing);
      writeGate = Completer<void>();
      await tester.tap(find.byKey(const Key('privacy_find_suggestions')));
      await tester.pump();

      expect(find.text(PrivacyCopy.findingSuggestions), findsOneWidget);
      expect(
        tester.widget<PrivacyButton>(find.byKey(const Key('privacy_find_suggestions'))).onPressed,
        isNull,
      );

      writeGate.complete();
      await _pumpUntil(
        tester,
        () async => (await store.pendingCandidates()).any((candidate) => candidate.sessionId == session.localId),
      );
      await _pumpUntilWidget(
        tester,
        () => find.byKey(const Key('privacy_suggestion_feedback')).evaluate().length == 1,
      );

      final candidate = (await store.pendingCandidates()).singleWhere(
        (candidate) => candidate.sessionId == session.localId,
      );
      expect(find.byKey(const Key('privacy_suggestion_feedback')), findsOneWidget);
      expect(find.text('1 suggestion found. Review it below.'), findsOneWidget);
      expect(find.text('Send the session-only draft tomorrow'), findsOneWidget);
      expect(find.text('Archive the unrelated notes tomorrow'), findsNothing);
      expect(find.byKey(Key('privacy_accept_${candidate.candidateId}')), findsOneWidget);
    });

    testWidgets('Session details gives explicit no-result feedback', (tester) async {
      final store = await _openStore(tester, 'privacy-usability-session-suggestion-feedback');
      late PrivacySessionRecord session;
      await tester.runAsync(() async {
        session = await _seedSession(
          store,
          captureId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          purpose: 'No commitments',
          text: 'We talked about the weather.',
        );
      });

      await _pumpShell(
        tester,
        store: store,
        quickPreferences: _readyQuickPreferences(),
        initialTab: 1,
      );
      await tester.tap(find.byKey(Key('privacy_session_${session.localId}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final taskActions = find.byKey(const Key('privacy_session_task_actions'));
      await tester.scrollUntilVisible(
        taskActions,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(taskActions);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('privacy_find_suggestions')));
      await tester.pump();
      await _pumpUntilWidget(tester, () => find.text(PrivacyCopy.noNewSuggestions).evaluate().length == 1);

      expect(find.text(PrivacyCopy.noNewSuggestions), findsOneWidget);
      expect((await store.pendingCandidates()).where((item) => item.sessionId == session.localId), isEmpty);
    });

    testWidgets('Sessions and every task category have an intentional empty state', (tester) async {
      final store = await _openStore(tester, 'privacy-usability-empty-states');

      await _pumpShell(
        tester,
        store: store,
        quickPreferences: _readyQuickPreferences(),
        initialTab: 1,
      );
      expect(find.text(PrivacyCopy.noSessionsTitle), findsOneWidget);

      await tester.tap(find.byKey(const Key('privacy_app_switcher')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('privacy_destination_2')));
      await tester.pumpAndSettle();

      expect(find.text(PrivacyCopy.noTasksToday), findsOneWidget);
      await _selectTaskCategory(tester, 'inbox');
      expect(find.text(PrivacyCopy.noInboxTasks), findsOneWidget);
      await _selectTaskCategory(tester, 'projects');
      expect(find.text(PrivacyCopy.noProjects), findsOneWidget);
      await _selectTaskCategory(tester, 'suggestions');
      expect(find.text(PrivacyCopy.noSuggestions), findsOneWidget);
      await _selectTaskCategory(tester, 'completed');
      expect(find.text(PrivacyCopy.noCompletedTasks), findsOneWidget);
    });

    testWidgets('small viewport, 200% text, Reduce Motion, and core semantics remain usable', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = await _openStore(tester, 'privacy-usability-accessibility');
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _pumpShell(
        tester,
        store: store,
        quickPreferences: _readyQuickPreferences(),
        mediaQueryData: const MediaQueryData(
          size: Size(320, 568),
          textScaler: TextScaler.linear(2),
          disableAnimations: true,
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.getSize(find.byKey(const Key('privacy_app_switcher'))).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(find.byKey(const Key('privacy_app_switcher'))).height, greaterThanOrEqualTo(44));

      final switcher = tester.getSemantics(find.byKey(const Key('privacy_app_switcher'))).getSemanticsData();
      expect(switcher.flagsCollection.isButton, isTrue);
      expect(switcher.label.toLowerCase(), contains('switch'));

      final state = tester.getSemantics(find.byKey(const Key('privacy_state'))).getSemanticsData();
      expect(state.flagsCollection.isLiveRegion, isTrue);
      expect(state.label, isNotEmpty);

      final orb = tester.widget<AnimatedContainer>(find.descendant(
        of: find.byType(PrivacyCaptureOrb),
        matching: find.byType(AnimatedContainer),
      ));
      expect(orb.duration, Duration.zero);

      await tester.tap(find.byKey(const Key('privacy_app_switcher')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('privacy_destination_0')), findsOneWidget);
      expect(find.byKey(const Key('privacy_destination_4')), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  });

  test('all privacy themes keep status text and state colors legible', () {
    for (final id in PrivacyThemeId.values) {
      final theme = privacyThemeById(id);
      final palette = theme.palette;
      final checks = <String, (Color, Color)>{
        'primary text on surface': (palette.text, palette.surface),
        'secondary text on surface': (palette.textSecondary, palette.surface),
        'secondary text on secondary surface': (palette.textSecondary, palette.surfaceSecondary),
        'connected status on surface': (palette.success, palette.surface),
        'recording status on surface': (palette.recording, palette.surface),
        'interrupted status on surface': (palette.interrupted, palette.surface),
        'button label on accent': (palette.onAccent, palette.accent),
      };

      for (final check in checks.entries) {
        expect(
          _contrastRatio(check.value.$1, check.value.$2),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.name}: ${check.key}',
        );
      }
    }
  });
}

final _now = DateTime(2026, 10, 11, 10);

MemoryQuickSelfCapturePreferences _readyQuickPreferences() {
  return MemoryQuickSelfCapturePreferences(const QuickSelfCaptureSettings(
    enabled: true,
    purpose: QuickSelfCapturePurpose.personalNote,
    retention: PrivacyRetentionChoice.hours24,
  ));
}

Future<PrivacyStore> _openStore(
  WidgetTester tester,
  String prefix, {
  Future<void> Function(String path)? protect,
}) async {
  final directory = await tester.runAsync(() => Directory.systemTemp.createTemp(prefix));
  addTearDown(() {
    if (directory != null && directory.existsSync()) directory.deleteSync(recursive: true);
  });
  final store = await tester.runAsync(() => PrivacyStore.open(directory!, protect: protect));
  return store!;
}

Future<PrivacySessionRecord> _seedSession(
  PrivacyStore store, {
  required String captureId,
  required String purpose,
  required String text,
}) async {
  final session = (await store.openSession(
    captureId: captureId,
    purpose: 'personal_memory',
    ownerPurpose: purpose,
    consentBasis: 'self_only',
    protocolVersion: 1,
    policyRevision: 1,
    at: _now,
  ))
      .value!;
  await store.upsertChunk(
    captureId: captureId,
    sequence: 1,
    machineText: text,
  );
  return session;
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required PrivacyStore store,
  required MemoryQuickSelfCapturePreferences quickPreferences,
  int initialTab = 0,
  DateTime Function()? clock,
  MediaQueryData? mediaQueryData,
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    builder: mediaQueryData == null
        ? null
        : (context, child) => MediaQuery(
              data: mediaQueryData,
              child: child!,
            ),
    home: PrivacyShell(
      store: store,
      quickPreferences: quickPreferences,
      initialTab: initialTab,
      clock: clock,
      themeStore: MemoryPrivacyThemeStore(),
      findPendant: () async => PrivacyCopy.notConnected,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  // Privacy capture deliberately owns long-lived state animations and native
  // service futures. Advance the first frame without waiting for every ticker
  // in the state-preserving IndexedStack to become idle.
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _seedTaskWorkspace(WidgetTester tester, PrivacyStore store) async {
  await tester.runAsync(() async {
    await store.setRetention(PrivacyRetentionChoice.hours24, at: _now);
    await store.createTask(
      title: 'Today contract task',
      dueAt: DateTime(2026, 10, 11, 17),
      at: _now,
    );
    await store.createTask(title: 'Inbox contract task', at: _now);

    final project = (await store.createProject('Launch Project', at: _now)).value!;
    await store.createTask(
      title: 'Project-only contract task',
      projectId: project.projectId,
      at: _now,
    );

    final completed = (await store.createTask(title: 'Completed contract task', at: _now)).value!;
    await store.setTaskStatus(completed.taskId, completed: true, at: _now);

    const captureId = '99999999-9999-4999-8999-999999999999';
    final session = (await store.openSession(
      captureId: captureId,
      purpose: 'personal_memory',
      ownerPurpose: 'Usability contract fixture',
      consentBasis: 'self_only',
      protocolVersion: 1,
      policyRevision: 1,
      at: _now,
    ))
        .value!;
    await store.upsertChunk(
      captureId: captureId,
      sequence: 1,
      machineText: 'I will send the usability draft tomorrow.',
    );
    await store.refreshSuggestions(
      service: const ActionSuggestionService(),
      sessionId: session.localId,
      at: _now,
    );
  });
}

Future<void> _selectTaskCategory(WidgetTester tester, String category) async {
  await tester.tap(find.byKey(Key('privacy_task_category_$category')));
  await tester.pumpAndSettle();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Future<bool> Function() condition,
) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    if ((await tester.runAsync(condition)) == true) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(await tester.runAsync(condition), isTrue, reason: 'asynchronous store update did not settle');
}

Future<void> _pumpUntilWidget(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (condition()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
  expect(condition(), isTrue, reason: 'asynchronous widget refresh did not settle');
}

void _expectOnlyVisible(String visible, {required List<String> hidden}) {
  expect(find.text(visible), findsOneWidget);
  for (final value in hidden) {
    expect(find.text(value), findsNothing, reason: '$value belongs to another task category');
  }
}

double _contrastRatio(Color foreground, Color background) {
  final lighter = foreground.computeLuminance() > background.computeLuminance() ? foreground : background;
  final darker = identical(lighter, foreground) ? background : foreground;
  return (lighter.computeLuminance() + 0.05) / (darker.computeLuminance() + 0.05);
}
