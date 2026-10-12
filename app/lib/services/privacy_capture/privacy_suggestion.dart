import 'package:omi/services/privacy_capture/privacy_action_config.dart';

class SuggestionDraft {
  const SuggestionDraft({required this.text, required this.excerpt});

  final String text;
  final String excerpt;
}

/// Conservative extractor for explicit first-person commitments and reminder imperatives.
///
/// Results are suggestions. Callers must not create a task without a separate accept gesture.
class ActionSuggestionService {
  const ActionSuggestionService({this.version = PrivacyActionConfig.extractorVersion});

  final String version;

  static final _patterns = <RegExp>[
    RegExp(r"\bI['’]ll\s+([^.?!\n]{3,160})", caseSensitive: false),
    RegExp(r"\bI will\s+([^.?!\n]{3,160})", caseSensitive: false),
    RegExp(r"\bI need to\s+([^.?!\n]{3,160})", caseSensitive: false),
    RegExp(r"\bI have to\s+([^.?!\n]{3,160})", caseSensitive: false),
    RegExp(r"\bI['’]m going to\s+([^.?!\n]{3,160})", caseSensitive: false),
    RegExp(r"\b[Rr]emind me to\s+([^.?!\n]{3,160})"),
    RegExp(r"\b[Rr]emember to\s+([^.?!\n]{3,160})"),
    RegExp(r"\b[Dd]on['’]t forget to\s+([^.?!\n]{3,160})"),
  ];

  List<SuggestionDraft> extract(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.endsWith('?')) return const [];
    final found = <SuggestionDraft>[];
    final seen = <String>{};
    for (final pattern in _patterns) {
      for (final match in pattern.allMatches(trimmed)) {
        final body = _clean(match.group(1) ?? '');
        if (!_usable(body)) continue;
        final key = body.toLowerCase();
        if (!seen.add(key)) continue;
        final proposed = _title(pattern, body);
        found.add(SuggestionDraft(text: proposed, excerpt: _bound(match.group(0) ?? proposed)));
      }
    }
    return found;
  }

  static bool _usable(String body) {
    if (body.length < 3) return false;
    final words = body.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
    if (words.length < 2 && body.length < 8) return false;
    return true;
  }

  static String _clean(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _title(RegExp pattern, String body) {
    final source = pattern.pattern;
    if (source.contains('Remind') || source.contains('Remember') || source.contains('forget')) {
      return _sentence(body);
    }
    return _sentence(body);
  }

  static String _sentence(String body) {
    if (body.isEmpty) return body;
    return body[0].toUpperCase() + body.substring(1);
  }

  static String _bound(String value) {
    final clean = _clean(value);
    if (clean.length <= PrivacyActionConfig.excerptMaxChars) return clean;
    return clean.substring(0, PrivacyActionConfig.excerptMaxChars);
  }
}

String boundPrivacyExcerpt(String value) {
  final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.length <= PrivacyActionConfig.excerptMaxChars) return clean;
  return clean.substring(0, PrivacyActionConfig.excerptMaxChars);
}
