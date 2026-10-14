import 'package:flutter/material.dart';

import 'package:omi/ui/omi_tokens.dart';

enum PrivacyThemeId { signalGreen, electricBlue, warmEmber, quietLight }

class PrivacyPalette {
  const PrivacyPalette({
    required this.background,
    required this.surface,
    required this.surfaceSecondary,
    required this.text,
    required this.textSecondary,
    required this.accent,
    required this.onAccent,
    required this.border,
    required this.success,
    required this.warning,
    required this.destructive,
    required this.disabled,
    required this.focus,
    required this.recording,
    required this.interrupted,
    required this.suggestion,
    required this.machine,
    required this.owner,
  });

  final Color background;
  final Color surface;
  final Color surfaceSecondary;
  final Color text;
  final Color textSecondary;
  final Color accent;
  final Color onAccent;
  final Color border;
  final Color success;
  final Color warning;
  final Color destructive;
  final Color disabled;
  final Color focus;
  final Color recording;
  final Color interrupted;
  final Color suggestion;
  final Color machine;
  final Color owner;
}

class PrivacySpace {
  const PrivacySpace._();
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

class PrivacyRadius {
  const PrivacyRadius._();
  static const control = 16.0;
  static const card = 22.0;
  static const pill = 999.0;
}

class PrivacyTypeScale {
  const PrivacyTypeScale._();
  static const display = 40.0;
  static const title = 28.0;
  static const section = 18.0;
  static const body = 16.0;
  static const meta = 13.0;
  static const caption = 12.0;
}

class PrivacyTheme {
  const PrivacyTheme({required this.id, required this.name, required this.palette});

  final PrivacyThemeId id;
  final String name;
  final PrivacyPalette palette;

  ThemeData toThemeData() {
    final colors = palette;
    final base = colors.background.computeLuminance() > 0.5 ? ThemeData.light() : ThemeData.dark();
    return base.copyWith(
      scaffoldBackgroundColor: colors.background,
      colorScheme: base.colorScheme.copyWith(
        primary: colors.accent,
        onPrimary: colors.onAccent,
        surface: colors.surface,
        onSurface: colors.text,
        error: colors.destructive,
      ),
      textTheme: base.textTheme.apply(
        fontFamily: 'SF Pro Display',
        bodyColor: colors.text,
        displayColor: colors.text,
      ),
      dividerColor: colors.border,
      disabledColor: colors.disabled,
      focusColor: colors.focus,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceSecondary,
        contentPadding: const EdgeInsets.symmetric(horizontal: PrivacySpace.md, vertical: PrivacySpace.md),
        labelStyle: TextStyle(color: colors.textSecondary),
        hintStyle: TextStyle(color: colors.textSecondary),
        helperStyle: TextStyle(color: colors.textSecondary),
        errorStyle: TextStyle(color: colors.destructive),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PrivacyRadius.control),
          borderSide: BorderSide(color: colors.border),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PrivacyRadius.control),
          borderSide: BorderSide(color: colors.disabled),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PrivacyRadius.control),
          borderSide: BorderSide(color: colors.focus, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PrivacyRadius.control),
          borderSide: BorderSide(color: colors.destructive),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PrivacyRadius.control),
          borderSide: BorderSide(color: colors.destructive, width: 2),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        modalBackgroundColor: colors.surface,
        modalBarrierColor: colors.background.withValues(alpha: 0.72),
        dragHandleColor: colors.textSecondary,
      ),
      dialogTheme: DialogThemeData(backgroundColor: colors.surface),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surfaceSecondary,
        contentTextStyle: TextStyle(color: colors.text),
      ),
    );
  }

  /// Lets shared Omi controls participate in the privacy app's four palettes.
  /// The privacy flavor is a standalone root, so updating the active token set
  /// here cannot leak into the stock signed-in experience.
  OmiPalette toOmiPalette() {
    final colors = palette;
    return OmiPalette(
      surface0: colors.background,
      surface1: colors.surface,
      surface2: colors.surfaceSecondary,
      surface3: colors.border,
      chipSurface: colors.surfaceSecondary,
      messageSurface: colors.surface,
      categorySurface: colors.surfaceSecondary,
      conversationCard: colors.surface,
      sourceBadgeSurface: colors.surfaceSecondary,
      border: colors.border,
      textPrimary: colors.text,
      textSecondary: colors.textSecondary,
      textTertiary: colors.textSecondary,
      textDisabled: colors.disabled,
      accent: colors.accent,
      onAccent: colors.onAccent,
      success: colors.success,
      successSurface: colorsWithOpacity(colors.success),
      warning: colors.warning,
      danger: colors.destructive,
      dangerSurface: colorsWithOpacity(colors.destructive),
    );
  }

  TextStyle display() => TextStyle(
        fontSize: PrivacyTypeScale.display,
        fontWeight: FontWeight.w600,
        height: 1.05,
        color: palette.text,
        letterSpacing: -0.8,
      );

  TextStyle title() => TextStyle(
        fontSize: PrivacyTypeScale.title,
        fontWeight: FontWeight.w600,
        color: palette.text,
        letterSpacing: -0.4,
      );

  TextStyle section() => TextStyle(
        fontSize: PrivacyTypeScale.section,
        fontWeight: FontWeight.w600,
        color: palette.text,
      );

  TextStyle body() => TextStyle(fontSize: PrivacyTypeScale.body, height: 1.4, color: palette.text);

  TextStyle meta() => TextStyle(fontSize: PrivacyTypeScale.meta, height: 1.3, color: palette.textSecondary);

  TextStyle caption() => TextStyle(fontSize: PrivacyTypeScale.caption, color: palette.textSecondary);

  Color stateColor(String kind) {
    switch (kind) {
      case 'recording':
        return palette.recording;
      case 'interrupted':
        return palette.interrupted;
      case 'suggestion':
        return palette.suggestion;
      case 'machine':
        return palette.machine;
      case 'owner':
        return palette.owner;
      case 'destructive':
        return palette.destructive;
      default:
        return palette.accent;
    }
  }
}

Color colorsWithOpacity(Color color) => color.withValues(alpha: 0.15);

// omi-ux-allow: color-literal -- privacy theme tokens, not ad-hoc widget colors
const signalGreen = PrivacyTheme(
  id: PrivacyThemeId.signalGreen,
  name: 'Signal Green',
  palette: PrivacyPalette(
    background: Color(0xFF101410), // omi-ux-allow: color-literal -- privacy theme token
    surface: Color(0xFF1A211A), // omi-ux-allow: color-literal -- privacy theme token
    surfaceSecondary: Color(0xFF232C23), // omi-ux-allow: color-literal -- privacy theme token
    text: Color(0xFFF3F7F1), // omi-ux-allow: color-literal -- privacy theme token
    textSecondary: Color(0xFFA8B5A8), // omi-ux-allow: color-literal -- privacy theme token
    accent: Color(0xFF3DDC84), // omi-ux-allow: color-literal -- privacy theme token
    onAccent: Color(0xFF062112), // omi-ux-allow: color-literal -- privacy theme token
    border: Color(0xFF314034), // omi-ux-allow: color-literal -- privacy theme token
    success: Color(0xFF3DDC84), // omi-ux-allow: color-literal -- privacy theme token
    warning: Color(0xFFE2B15A), // omi-ux-allow: color-literal -- privacy theme token
    destructive: Color(0xFFFF6B6B), // omi-ux-allow: color-literal -- privacy theme token
    disabled: Color(0xFF667066), // omi-ux-allow: color-literal -- privacy theme token
    focus: Color(0xFF8AF0B4), // omi-ux-allow: color-literal -- privacy theme token
    recording: Color(0xFF3DDC84), // omi-ux-allow: color-literal -- privacy theme token
    interrupted: Color(0xFFE2B15A), // omi-ux-allow: color-literal -- privacy theme token
    suggestion: Color(0xFF8FD6B0), // omi-ux-allow: color-literal -- privacy theme token
    machine: Color(0xFFC5D2C6), // omi-ux-allow: color-literal -- privacy theme token
    owner: Color(0xFFF3F7F1), // omi-ux-allow: color-literal -- privacy theme token
  ),
);

// omi-ux-allow: color-literal -- privacy theme tokens, not ad-hoc widget colors
const electricBlue = PrivacyTheme(
  id: PrivacyThemeId.electricBlue,
  name: 'Electric Blue',
  palette: PrivacyPalette(
    background: Color(0xFF0D1116), // omi-ux-allow: color-literal -- privacy theme token
    surface: Color(0xFF171E27), // omi-ux-allow: color-literal -- privacy theme token
    surfaceSecondary: Color(0xFF212B36), // omi-ux-allow: color-literal -- privacy theme token
    text: Color(0xFFF2F6FA), // omi-ux-allow: color-literal -- privacy theme token
    textSecondary: Color(0xFFA7B4C2), // omi-ux-allow: color-literal -- privacy theme token
    accent: Color(0xFF4CC9F0), // omi-ux-allow: color-literal -- privacy theme token
    onAccent: Color(0xFF041820), // omi-ux-allow: color-literal -- privacy theme token
    border: Color(0xFF31404C), // omi-ux-allow: color-literal -- privacy theme token
    success: Color(0xFF5DDC9A), // omi-ux-allow: color-literal -- privacy theme token
    warning: Color(0xFFE2B15A), // omi-ux-allow: color-literal -- privacy theme token
    destructive: Color(0xFFFF6B6B), // omi-ux-allow: color-literal -- privacy theme token
    disabled: Color(0xFF667280), // omi-ux-allow: color-literal -- privacy theme token
    focus: Color(0xFF9BE7F8), // omi-ux-allow: color-literal -- privacy theme token
    recording: Color(0xFF4CC9F0), // omi-ux-allow: color-literal -- privacy theme token
    interrupted: Color(0xFFE2B15A), // omi-ux-allow: color-literal -- privacy theme token
    suggestion: Color(0xFF8ED8F0), // omi-ux-allow: color-literal -- privacy theme token
    machine: Color(0xFFC5D3DE), // omi-ux-allow: color-literal -- privacy theme token
    owner: Color(0xFFF2F6FA), // omi-ux-allow: color-literal -- privacy theme token
  ),
);

// omi-ux-allow: color-literal -- privacy theme tokens, not ad-hoc widget colors
const warmEmber = PrivacyTheme(
  id: PrivacyThemeId.warmEmber,
  name: 'Warm Ember',
  palette: PrivacyPalette(
    background: Color(0xFF14100E), // omi-ux-allow: color-literal -- privacy theme token
    surface: Color(0xFF241C18), // omi-ux-allow: color-literal -- privacy theme token
    surfaceSecondary: Color(0xFF2E241E), // omi-ux-allow: color-literal -- privacy theme token
    text: Color(0xFFF8F3EE), // omi-ux-allow: color-literal -- privacy theme token
    textSecondary: Color(0xFFC2B2A6), // omi-ux-allow: color-literal -- privacy theme token
    accent: Color(0xFFFF9F43), // omi-ux-allow: color-literal -- privacy theme token
    onAccent: Color(0xFF2A1404), // omi-ux-allow: color-literal -- privacy theme token
    border: Color(0xFF4A382C), // omi-ux-allow: color-literal -- privacy theme token
    success: Color(0xFF7DDC8A), // omi-ux-allow: color-literal -- privacy theme token
    warning: Color(0xFFFFC46B), // omi-ux-allow: color-literal -- privacy theme token
    destructive: Color(0xFFFF6B6B), // omi-ux-allow: color-literal -- privacy theme token
    disabled: Color(0xFF7A6C62), // omi-ux-allow: color-literal -- privacy theme token
    focus: Color(0xFFFFC48A), // omi-ux-allow: color-literal -- privacy theme token
    recording: Color(0xFFFF9F43), // omi-ux-allow: color-literal -- privacy theme token
    interrupted: Color(0xFFFFC46B), // omi-ux-allow: color-literal -- privacy theme token
    suggestion: Color(0xFFFFC48A), // omi-ux-allow: color-literal -- privacy theme token
    machine: Color(0xFFD8CBBF), // omi-ux-allow: color-literal -- privacy theme token
    owner: Color(0xFFF8F3EE), // omi-ux-allow: color-literal -- privacy theme token
  ),
);

// omi-ux-allow: color-literal -- privacy theme tokens, not ad-hoc widget colors
const quietLight = PrivacyTheme(
  id: PrivacyThemeId.quietLight,
  name: 'Quiet Light',
  palette: PrivacyPalette(
    background: Color(0xFFF4F1EA), // omi-ux-allow: color-literal -- privacy theme token
    surface: Color(0xFFFFFCF7), // omi-ux-allow: color-literal -- privacy theme token
    surfaceSecondary: Color(0xFFE7EFE6), // omi-ux-allow: color-literal -- privacy theme token
    text: Color(0xFF1C241C), // omi-ux-allow: color-literal -- privacy theme token
    textSecondary: Color(0xFF5C6A5E), // omi-ux-allow: color-literal -- privacy theme token
    accent: Color(0xFF176F3B), // omi-ux-allow: color-literal -- privacy theme token
    onAccent: Color(0xFFF7FFF9), // omi-ux-allow: color-literal -- privacy theme token
    border: Color(0xFFD5DDD4), // omi-ux-allow: color-literal -- privacy theme token
    success: Color(0xFF176F3B), // omi-ux-allow: color-literal -- privacy theme token
    warning: Color(0xFF9A6A12), // omi-ux-allow: color-literal -- privacy theme token
    destructive: Color(0xFFB42318), // omi-ux-allow: color-literal -- privacy theme token
    disabled: Color(0xFF8A938A), // omi-ux-allow: color-literal -- privacy theme token
    focus: Color(0xFF125E32), // omi-ux-allow: color-literal -- privacy theme token
    recording: Color(0xFF176F3B), // omi-ux-allow: color-literal -- privacy theme token
    interrupted: Color(0xFF9A6A12), // omi-ux-allow: color-literal -- privacy theme token
    suggestion: Color(0xFF176F3B), // omi-ux-allow: color-literal -- privacy theme token
    machine: Color(0xFF3E4C40), // omi-ux-allow: color-literal -- privacy theme token
    owner: Color(0xFF1C241C), // omi-ux-allow: color-literal -- privacy theme token
  ),
);

PrivacyTheme privacyThemeById(PrivacyThemeId id) {
  switch (id) {
    case PrivacyThemeId.signalGreen:
      return signalGreen;
    case PrivacyThemeId.electricBlue:
      return electricBlue;
    case PrivacyThemeId.warmEmber:
      return warmEmber;
    case PrivacyThemeId.quietLight:
      return quietLight;
  }
}

abstract class PrivacyThemeStore {
  Future<String?> read();
  Future<void> write(String id);
}

class MemoryPrivacyThemeStore implements PrivacyThemeStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String id) async {
    value = id;
  }
}

class PrivacyThemeController extends ChangeNotifier {
  PrivacyThemeController({PrivacyThemeStore? store, PrivacyThemeId initial = PrivacyThemeId.signalGreen})
      : _store = store,
        id = initial;

  final PrivacyThemeStore? _store;
  PrivacyThemeId id;

  PrivacyTheme get theme => privacyThemeById(id);

  Future<void> load() async {
    final stored = await _store?.read();
    id = _fromName(stored) ?? PrivacyThemeId.signalGreen;
    notifyListeners();
  }

  Future<void> select(PrivacyThemeId next) async {
    id = next;
    notifyListeners();
    await _store?.write(next.name);
  }

  static PrivacyThemeId? _fromName(String? name) {
    for (final value in PrivacyThemeId.values) {
      if (value.name == name) return value;
    }
    return null;
  }
}
