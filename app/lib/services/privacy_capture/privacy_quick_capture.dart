import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/services/privacy_capture/privacy_models.dart';

/// Truthful owner-selected purposes for a pendant quick capture.
///
/// These values are local provenance. The current wire contract continues to
/// use `personal_memory` until the backend explicitly supports a wider purpose
/// vocabulary.
enum QuickSelfCapturePurpose { personalNote, selfReflection, taskCapture }

extension QuickSelfCapturePurposeValue on QuickSelfCapturePurpose {
  String get provenanceValue {
    switch (this) {
      case QuickSelfCapturePurpose.personalNote:
        return 'personal_note';
      case QuickSelfCapturePurpose.selfReflection:
        return 'self_reflection';
      case QuickSelfCapturePurpose.taskCapture:
        return 'task_capture';
    }
  }
}

QuickSelfCapturePurpose? quickSelfCapturePurposeFromName(String? value) {
  for (final purpose in QuickSelfCapturePurpose.values) {
    if (purpose.name == value || purpose.provenanceValue == value) return purpose;
  }
  return null;
}

class QuickSelfCaptureSettings {
  const QuickSelfCaptureSettings({
    this.enabled = false,
    this.purpose,
    this.retention,
  });

  final bool enabled;
  final QuickSelfCapturePurpose? purpose;
  final PrivacyRetentionChoice? retention;

  bool get ready => enabled && purpose != null && retention != null;

  QuickSelfCaptureSettings copyWith({
    bool? enabled,
    QuickSelfCapturePurpose? purpose,
    PrivacyRetentionChoice? retention,
    bool clearPurpose = false,
    bool clearRetention = false,
  }) {
    return QuickSelfCaptureSettings(
      enabled: enabled ?? this.enabled,
      purpose: clearPurpose ? null : (purpose ?? this.purpose),
      retention: clearRetention ? null : (retention ?? this.retention),
    );
  }
}

/// One accepted start gesture. It is intentionally not reusable.
class QuickSelfCaptureIntent {
  const QuickSelfCaptureIntent({
    required this.purpose,
    required this.retention,
    required this.assertedAt,
  });

  final QuickSelfCapturePurpose purpose;
  final PrivacyRetentionChoice retention;
  final DateTime assertedAt;
}

abstract class QuickSelfCapturePreferences {
  Future<QuickSelfCaptureSettings> load();
  Future<void> save(QuickSelfCaptureSettings settings);
}

class PrefsQuickSelfCapturePreferences implements QuickSelfCapturePreferences {
  PrefsQuickSelfCapturePreferences({Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  static const enabledKey = 'privacy_quick_self_capture_enabled';
  static const purposeKey = 'privacy_quick_self_capture_purpose';
  static const retentionKey = 'privacy_quick_self_capture_retention';

  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<QuickSelfCaptureSettings> load() async {
    final prefs = await _preferences();
    return QuickSelfCaptureSettings(
      enabled: prefs.getBool(enabledKey) ?? false,
      purpose: quickSelfCapturePurposeFromName(prefs.getString(purposeKey)),
      retention: privacyRetentionFromName(prefs.getString(retentionKey)),
    );
  }

  @override
  Future<void> save(QuickSelfCaptureSettings settings) async {
    final prefs = await _preferences();
    await prefs.setBool(enabledKey, settings.enabled);
    final purpose = settings.purpose;
    if (purpose == null) {
      await prefs.remove(purposeKey);
    } else {
      await prefs.setString(purposeKey, purpose.name);
    }
    final retention = settings.retention;
    if (retention == null) {
      await prefs.remove(retentionKey);
    } else {
      await prefs.setString(retentionKey, retention.name);
    }
  }
}

class MemoryQuickSelfCapturePreferences implements QuickSelfCapturePreferences {
  MemoryQuickSelfCapturePreferences([
    QuickSelfCaptureSettings initial = const QuickSelfCaptureSettings(),
  ]) : _settings = initial;

  QuickSelfCaptureSettings _settings;

  @override
  Future<QuickSelfCaptureSettings> load() async => _settings;

  @override
  Future<void> save(QuickSelfCaptureSettings settings) async {
    _settings = settings;
  }
}
