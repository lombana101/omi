import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_quick_capture.dart';
import 'package:omi/services/privacy_capture/privacy_shell.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:omi/services/privacy_capture/privacy_suggestion.dart';
import 'package:omi/services/privacy_capture/privacy_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('small phone and 200 percent text do not overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2), size: Size(320, 568)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: PrivacyShell(
          themeStore: MemoryPrivacyThemeStore(),
          quickPreferences: _readyQuick(),
          findPendant: () async => PrivacyCopy.notConnected,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('write sanitized usability redesign screenshots', (tester) async {
    await _loadFonts();
    final out = Directory('../v1-delivery/usability-redesign/screenshots');
    await tester.runAsync(() => out.create(recursive: true));
    final directory = await tester.runAsync(() => Directory.systemTemp.createTemp('privacy-usability-shots'));
    addTearDown(() {
      if (directory != null && directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final store = await tester.runAsync(() => PrivacyStore.open(directory!));
    await tester.runAsync(() => _seed(store!));

    Future<void> shot(
      String name,
      PrivacyThemeId id,
      int tab, {
      Size size = const Size(390, 844),
      double textScale = 1,
      Future<void> Function()? afterPump,
    }) async {
      final themes = MemoryPrivacyThemeStore()..value = id.name;
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(RepaintBoundary(
        key: Key('shot-$name'),
        child: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: PrivacyShell(
              store: store,
              themeStore: themes,
              quickPreferences: _readyQuick(),
              initialTab: tab,
              clock: () => DateTime(2026, 10, 11, 10),
              findPendant: () async => PrivacyCopy.notConnected,
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      if (afterPump != null) await afterPump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull, reason: name);
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(Key('shot-$name')));
      final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
      final data = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
      final file = File('${out.path}/$name.png');
      await tester.runAsync(() => file.writeAsBytes(data!.buffer.asUint8List()));
    }

    await shot('capture-ready-signal-green', PrivacyThemeId.signalGreen, 0);
    await shot('sessions-list-signal-green', PrivacyThemeId.signalGreen, 1);
    await shot(
      'session-detail-signal-green',
      PrivacyThemeId.signalGreen,
      1,
      afterPump: () async {
        await tester.tap(find.text('Synthetic review note'));
        await tester.pump(const Duration(milliseconds: 350));
      },
    );
    await shot('tasks-today-signal-green', PrivacyThemeId.signalGreen, 2);
    await shot(
      'tasks-projects-signal-green',
      PrivacyThemeId.signalGreen,
      2,
      afterPump: () async {
        await tester.tap(find.byKey(const Key('privacy_task_category_projects')));
        await tester.pump(const Duration(milliseconds: 250));
      },
    );
    await shot(
      'tasks-suggestions-signal-green',
      PrivacyThemeId.signalGreen,
      2,
      afterPump: () async {
        await tester.tap(find.byKey(const Key('privacy_task_category_suggestions')));
        await tester.pump(const Duration(milliseconds: 250));
      },
    );
    await shot('settings-groups-signal-green', PrivacyThemeId.signalGreen, 4);
    await shot('capture-electric-blue', PrivacyThemeId.electricBlue, 0);
    await shot('capture-warm-ember', PrivacyThemeId.warmEmber, 0);
    await shot('capture-quiet-light', PrivacyThemeId.quietLight, 0);
    await shot('capture-small-phone', PrivacyThemeId.signalGreen, 0, size: const Size(320, 568));
    await shot('capture-large-text', PrivacyThemeId.signalGreen, 0, textScale: 2);

    expect(File('${out.path}/capture-ready-signal-green.png').existsSync(), isTrue);
    expect(File('${out.path}/settings-groups-signal-green.png').existsSync(), isTrue);
  });
}

Future<void> _loadFonts() async {
  final textLoader = FontLoader('SF Pro Display')
    ..addFont(rootBundle.load('assets/fonts/SFPRODISPLAYREGULAR.OTF'))
    ..addFont(rootBundle.load('assets/fonts/SFPRODISPLAYMEDIUM.OTF'))
    ..addFont(rootBundle.load('assets/fonts/SFPRODISPLAYBOLD.OTF'));
  final iconLoader = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await textLoader.load();
  await iconLoader.load();
}

MemoryQuickSelfCapturePreferences _readyQuick() {
  return MemoryQuickSelfCapturePreferences(const QuickSelfCaptureSettings(
    enabled: true,
    purpose: QuickSelfCapturePurpose.personalNote,
    retention: PrivacyRetentionChoice.hours24,
  ));
}

Future<void> _seed(PrivacyStore store) async {
  final now = DateTime(2026, 10, 11, 10);
  await store.setRetention(PrivacyRetentionChoice.hours24, at: now);
  const captureId = '77777777-7777-4777-8777-777777777777';
  final session = await store.openSession(
    captureId: captureId,
    purpose: 'personal_memory',
    ownerPurpose: 'Synthetic review note',
    consentBasis: 'self_only_quick_gesture',
    wireConsentBasis: 'self_only',
    consentAssertedAt: now,
    configuredPurpose: 'personal_note',
    captureOrigin: 'pendant_quick_capture',
    retentionChoice: PrivacyRetentionChoice.hours24,
    protocolVersion: 1,
    policyRevision: 1,
    at: now,
  );
  await store.upsertChunk(
    captureId: captureId,
    sequence: 1,
    machineText: 'I will send the synthetic design review tomorrow.',
  );
  await store.markTerminal(captureId: captureId, outcome: 'transcribed', incomplete: false, at: now);
  await store.refreshSuggestions(
    service: const ActionSuggestionService(),
    sessionId: session.value!.localId,
    at: now,
  );
  await store.createTask(title: 'Review the calm capture flow', dueAt: DateTime(2026, 10, 11, 16), at: now);
  await store.createTask(title: 'Sort the synthetic inbox', at: now);
  final project = await store.createProject('Usability polish', at: now);
  await store.createTask(title: 'Check contrast in every theme', projectId: project.value!.projectId, at: now);
}
