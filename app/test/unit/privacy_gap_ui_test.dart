import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_shell.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:omi/services/privacy_capture/privacy_suggestion.dart';

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
    });

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: PrivacyShell(store: store, initialTab: 2, findPendant: () async => PrivacyCopy.notConnected),
    ));
    await tester.pump();
    expect(find.text(PrivacyCopy.notATask), findsOneWidget);
    expect(find.text(PrivacyCopy.editAccept), findsWidgets);
    expect(find.text(PrivacyCopy.chooseDue), findsOneWidget);
    expect(find.text(PrivacyCopy.assignProject), findsOneWidget);
    expect(find.text(PrivacyCopy.rename), findsWidgets);
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
      home: PrivacyShell(store: store, initialTab: 1, findPendant: () async => PrivacyCopy.notConnected),
    ));
    await tester.pump();
    await tester.tap(find.text(PrivacyCopy.interrupted));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(PrivacyCopy.deleteSession), findsOneWidget);
    await tester.tap(find.text(PrivacyCopy.deleteSession));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(PrivacyCopy.confirmDelete), findsOneWidget);
    expect(find.textContaining(PrivacyCopy.deletedPhone), findsNothing);
    await tester.tap(find.text(PrivacyCopy.cancel));
    await tester.pump();
    expect(find.text('gone'), findsOneWidget);
  });
}
