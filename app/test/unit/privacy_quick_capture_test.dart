import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_quick_capture.dart';

void main() {
  test('quick self capture is disabled and incomplete by default', () async {
    final preferences = MemoryQuickSelfCapturePreferences();
    final settings = await preferences.load();

    expect(settings.enabled, isFalse);
    expect(settings.purpose, isNull);
    expect(settings.retention, isNull);
    expect(settings.ready, isFalse);
  });

  test('ready requires explicit enable, purpose, and retention', () {
    const configured = QuickSelfCaptureSettings(
      purpose: QuickSelfCapturePurpose.selfReflection,
      retention: PrivacyRetentionChoice.hours24,
    );

    expect(configured.ready, isFalse);
    expect(configured.copyWith(enabled: true).ready, isTrue);
    expect(
      const QuickSelfCaptureSettings(enabled: true, retention: PrivacyRetentionChoice.hours24).ready,
      isFalse,
    );
    expect(
      const QuickSelfCaptureSettings(
        enabled: true,
        purpose: QuickSelfCapturePurpose.personalNote,
      ).ready,
      isFalse,
    );
  });

  test('preferences persist only enabled, purpose, and retention', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final preferences = PrefsQuickSelfCapturePreferences();
    const configured = QuickSelfCaptureSettings(
      enabled: true,
      purpose: QuickSelfCapturePurpose.taskCapture,
      retention: PrivacyRetentionChoice.days7,
    );

    await preferences.save(configured);
    final reloaded = await preferences.load();
    final raw = await SharedPreferences.getInstance();

    expect(reloaded.enabled, isTrue);
    expect(reloaded.purpose, QuickSelfCapturePurpose.taskCapture);
    expect(reloaded.retention, PrivacyRetentionChoice.days7);
    expect(raw.getKeys(), {
      PrefsQuickSelfCapturePreferences.enabledKey,
      PrefsQuickSelfCapturePreferences.purposeKey,
      PrefsQuickSelfCapturePreferences.retentionKey,
    });
    expect(raw.getKeys().where((key) => key.contains('consent')), isEmpty);
  });
}
