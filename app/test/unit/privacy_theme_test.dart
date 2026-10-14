import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_shell.dart';
import 'package:omi/services/privacy_capture/privacy_widgets.dart';
import 'package:omi/services/privacy_capture/privacy_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('signal green is the default and selection persists', () async {
    final store = MemoryPrivacyThemeStore();
    final controller = PrivacyThemeController(store: store);
    await controller.load();
    expect(controller.id, PrivacyThemeId.signalGreen);
    expect(controller.theme.stateColor('recording'), isNot(controller.theme.stateColor('interrupted')));
    await controller.select(PrivacyThemeId.electricBlue);
    final again = PrivacyThemeController(store: store);
    await again.load();
    expect(again.id, PrivacyThemeId.electricBlue);
    expect(again.theme.palette.accent, isNot(signalGreen.palette.accent));
  });

  testWidgets('start stays disabled until required inputs exist', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final themes = MemoryPrivacyThemeStore();
    await tester.pumpWidget(MaterialApp(
      home: PrivacyShell(themeStore: themes, findPendant: () async => PrivacyCopy.notConnected),
    ));
    await tester.pump();
    expect(find.text(PrivacyCopy.recordingOff), findsOneWidget);
    expect(find.text(PrivacyCopy.missingRetention, skipOffstage: false), findsOneWidget);
    final start = tester.widget<PrivacyButton>(find.byKey(const Key('privacy_start')));
    expect(start.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme switch updates the capture accent immediately', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final themes = MemoryPrivacyThemeStore();
    await tester.pumpWidget(MaterialApp(
      home: PrivacyShell(themeStore: themes, initialTab: 4, findPendant: () async => PrivacyCopy.notConnected),
    ));
    await tester.pump();
    await tester.tap(find.text(PrivacyCopy.electricBlue));
    await tester.pump();
    expect(themes.value, PrivacyThemeId.electricBlue.name);
  });

  testWidgets('reduce motion removes the recording glow', (tester) async {
    await tester.pumpWidget(const MediaQuery(
      data: MediaQueryData(disableAnimations: true),
      child: PrivacyScope(
        theme: signalGreen,
        child: MaterialApp(home: PrivacyCaptureOrb(label: 'Recording', kind: 'recording', icon: Icons.graphic_eq)),
      ),
    ));
    final box = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    expect(box.duration, Duration.zero);
  });
}
