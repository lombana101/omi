import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_shell.dart';
import 'package:omi/services/privacy_capture/privacy_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('small phone and large text do not overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(1.6), size: Size(320, 568)),
      child: MaterialApp(home: PrivacyShell(themeStore: MemoryPrivacyThemeStore(), findPendant: () async => PrivacyCopy.notConnected)),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('write synthetic theme screenshots', (tester) async {
    final out = Directory('../v1-delivery/ui-redesign');
    await tester.runAsync(() => out.create(recursive: true));
    Future<void> shot(String name, PrivacyThemeId id, int tab) async {
      final themes = MemoryPrivacyThemeStore()..value = id.name;
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(RepaintBoundary(
        key: Key('shot-$name'),
        child: MaterialApp(
          home: PrivacyShell(themeStore: themes, initialTab: tab, findPendant: () async => PrivacyCopy.notConnected),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(Key('shot-$name')));
      final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
      final data = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
      final file = File('${out.path}/$name.png');
      await tester.runAsync(() => file.writeAsBytes(data!.buffer.asUint8List()));
    }

    await shot('signal-green-capture', PrivacyThemeId.signalGreen, 0);
    await shot('signal-green-sessions', PrivacyThemeId.signalGreen, 1);
    await shot('signal-green-tasks', PrivacyThemeId.signalGreen, 2);
    await shot('theme-electric-blue', PrivacyThemeId.electricBlue, 0);
    await shot('theme-warm-ember', PrivacyThemeId.warmEmber, 0);
    await shot('theme-quiet-light', PrivacyThemeId.quietLight, 0);
    expect(File('../v1-delivery/ui-redesign/signal-green-capture.png').existsSync(), isTrue);
  });
}
