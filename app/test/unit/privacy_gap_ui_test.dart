import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_quick_capture.dart';
import 'package:omi/services/privacy_capture/privacy_shell.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:omi/services/privacy_capture/privacy_suggestion.dart';
import 'package:omi/services/privacy_capture/privacy_theme.dart';

void main() {
  testWidgets('suggestions and tasks expose review controls', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('privacy-ui'));
    final store = await tester.runAsync(() => PrivacyStore.open(dir!));
    const captureId = '77777777-7777-4777-8777-777777777777';
    final session = await tester.runAsync(() => store!.openSession(
          captureId: captureId,
          purpose: 'personal_memory',
          ownerPurpose: 'review',
          consentBasis: 'self_only',
          protocolVersion: 1,
          policyRevision: 1,
          at: DateTime.utc(2026, 10, 10),
        ));
    await tester.runAsync(() async {
      await store!.upsertChunk(captureId: captureId, sequence: 1, machineText: 'I will send the draft tomorrow');
      await store.refreshSuggestions(service: const ActionSuggestionService(), sessionId: session!.value!.localId);
      await store.createProject('Home');
      await store.createProject('Work');
      await store.createTask(title: 'Call back');
      await store.addIntelligenceCandidate(
        sourceRef: 'manual:calendar',
        suggestedType: 'calendar_event',
        title: 'Focus block',
        excerpt: 'Schedule a focus block',
        uncertainty: 0.1,
        proposedStartAt: DateTime.utc(2026, 10, 14, 18),
        proposedEndAt: DateTime.utc(2026, 10, 14, 20),
        timezone: 'America/Toronto',
      );
    });

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: PrivacyShell(
        store: store,
        initialTab: 2,
        findPendant: () async => PrivacyCopy.notConnected,
        quickPreferences: MemoryQuickSelfCapturePreferences(),
        themeStore: MemoryPrivacyThemeStore(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const Key('privacy_task_category_suggestions')));
    await tester.pumpAndSettle();
    expect(find.text(PrivacyCopy.suggestionNotTask), findsOneWidget);
    expect(find.text(PrivacyCopy.editAccept), findsWidgets);
    expect(find.text(PrivacyCopy.reviewCalendarSuggestion), findsOneWidget);

    await tester.tap(find.byKey(const Key('privacy_task_category_inbox')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Call back'));
    await tester.pumpAndSettle();
    expect(find.text(PrivacyCopy.chooseDue), findsOneWidget);
    expect(find.text(PrivacyCopy.assignProject), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('privacy_task_category_projects')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();
    expect(find.text(PrivacyCopy.rename), findsWidgets);
    expect(find.text(PrivacyCopy.archive), findsOneWidget);
    await tester.tap(find.text(PrivacyCopy.rename).last);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('session deletion leaves the list and a local receipt', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('privacy-delete-ui'));
    final store = await tester.runAsync(() => PrivacyStore.open(dir!));
    await tester.runAsync(() => store!.openSession(
          captureId: '88888888-8888-4888-8888-888888888888',
          purpose: 'personal_memory',
          ownerPurpose: 'gone',
          consentBasis: 'self_only',
          protocolVersion: 1,
          policyRevision: 1,
          at: DateTime.utc(2026, 10, 10),
        ));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: PrivacyShell(
        store: store,
        initialTab: 1,
        findPendant: () async => PrivacyCopy.notConnected,
        quickPreferences: MemoryQuickSelfCapturePreferences(),
        themeStore: MemoryPrivacyThemeStore(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('gone'));
    await tester.pumpAndSettle();
    expect(find.text(PrivacyCopy.deleteSession), findsOneWidget);
    await tester.tap(find.text(PrivacyCopy.deleteSession));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(PrivacyCopy.confirmDelete), findsOneWidget);
    expect((await tester.runAsync(() => store!.sessions()))!.length, 1);
    await tester.tap(find.text(PrivacyCopy.cancel));
    await tester.pumpAndSettle();
    expect(find.text('gone'), findsOneWidget);

    await tester.tap(find.text(PrivacyCopy.deleteSession));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, PrivacyCopy.confirmDelete));
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 20; attempt++) {
      if ((await tester.runAsync(() => store!.sessions()))!.isEmpty) break;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    for (var attempt = 0; attempt < 20 && find.text('gone').evaluate().isNotEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    expect(find.text(PrivacyCopy.confirmDelete), findsNothing);
    expect((await tester.runAsync(() => store!.sessions()))!, isEmpty);
    expect(find.text('gone'), findsNothing);
    expect(find.text(PrivacyCopy.deletedSuccess), findsOneWidget);
    expect(find.textContaining(PrivacyCopy.deletedPhone), findsOneWidget);
  });
}
