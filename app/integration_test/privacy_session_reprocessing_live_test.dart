// Opt-in local verification. Never run against private source content or a cloud API.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_client.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_config.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_quick_capture.dart';
import 'package:omi/services/privacy_capture/privacy_shell.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:omi/services/privacy_capture/privacy_theme.dart';

class _LocalCredentials implements PrivacyIntelligenceCredentialSource {
  @override
  Future<PrivacyIntelligenceCredentials?> read() async => PrivacyIntelligenceCredentials(
        baseUrl: 'http://127.0.0.1:8792',
        ownerMappingId: const String.fromEnvironment('PIS_TEST_OWNER'),
        bearerToken: const String.fromEnvironment('PIS_TEST_TOKEN'),
      );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('interrupted session gesture uses live local intelligence and persists review state', (tester) async {
    final directory = await Directory.systemTemp.createTemp('omi-live-reprocess');
    final store = await PrivacyStore.open(directory);
    final now = DateTime.now();
    final session = (await store.openSession(
      captureId: 'synthetic-live-capture',
      purpose: 'personal',
      ownerPurpose: 'synthetic verification',
      consentBasis: 'self_only',
      protocolVersion: 1,
      policyRevision: 1,
      at: now,
      retentionChoice: PrivacyRetentionChoice.untilDeleted,
    ))
        .value!;
    await store.upsertChunk(
        captureId: session.captureId,
        sequence: 1,
        machineText: 'I need to buy milk tomorrow. I will call Alex about the trip.');
    await store.markTerminal(captureId: session.captureId, outcome: 'interrupted', incomplete: true, at: now);
    final client = PrivacyIntelligenceClient(credentials: _LocalCredentials());
    addTearDown(client.close);
    addTearDown(() => directory.delete(recursive: true));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PrivacyShell(
          store: store,
          initialTab: 1,
          intelligenceClient: client,
          themeStore: MemoryPrivacyThemeStore(),
          quickPreferences: MemoryQuickSelfCapturePreferences()),
    ));
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 600; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (finder.evaluate().isNotEmpty) return;
      }
      fail('Timed out waiting for synthetic reprocess UI');
    }

    await waitFor(find.byKey(Key('privacy_reprocess_${session.localId}')));
    await tester.tap(find.byKey(Key('privacy_reprocess_${session.localId}')));
    await tester.pumpAndSettle();
    final actions = find.byKey(const Key('privacy_session_task_actions'));
    await tester.scrollUntilVisible(actions, 250);
    await tester.tap(find.descendant(of: actions, matching: find.byType(ExpansionTile)));
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('privacy_reprocess_session'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await waitFor(find.textContaining('found. Review'));
    final first = await store.pendingCandidates();
    expect(first, isNotEmpty);
    expect(first.every((candidate) => candidate.sourceRef == 'session:${session.localId}'), isTrue);
    await tester.ensureVisible(button);
    await tester.tap(button);
    // Wait for the second real model request to finish, allowing either zero
    // new suggestions or a distinct model interpretation without losing data.
    for (var i = 0; i < 600; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.text('Reprocessing…').evaluate().isEmpty && i > 8) break;
    }
    final candidate = (await store.pendingCandidates()).first;
    await store.dismissCandidate(candidate.candidateId);
    final reopened = await PrivacyStore.open(directory);
    expect((await reopened.pendingCandidates()).any((row) => row.candidateId == candidate.candidateId), isFalse);
    expect(await reopened.chunks(session.localId), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !const bool.fromEnvironment('PIS_LIVE_TEST'));
}
