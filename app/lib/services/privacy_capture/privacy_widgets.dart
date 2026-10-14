import 'package:flutter/material.dart';

import 'package:omi/services/privacy_capture/privacy_theme.dart';
import 'package:omi/ui/ui.dart';

class PrivacyScope extends InheritedWidget {
  const PrivacyScope({super.key, required this.theme, required super.child});

  final PrivacyTheme theme;

  static PrivacyTheme of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PrivacyScope>();
    return scope?.theme ?? signalGreen;
  }

  @override
  bool updateShouldNotify(PrivacyScope oldWidget) => oldWidget.theme.id != theme.id;
}

class PrivacyScaffold extends StatelessWidget {
  const PrivacyScaffold({super.key, required this.body, this.navigation});

  final Widget body;
  final Widget? navigation;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return ColoredBox(
      color: theme.palette.background,
      child: Scaffold(
        backgroundColor: theme.palette.background,
        body: SafeArea(child: body),
        bottomNavigationBar: navigation,
      ),
    );
  }
}

class PrivacyHeader extends StatelessWidget {
  const PrivacyHeader({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.title()),
        if (subtitle != null) const SizedBox(height: PrivacySpace.xs),
        if (subtitle != null) Text(subtitle!, style: theme.meta()),
      ],
    );
  }
}

class PrivacyPageHeader extends StatelessWidget {
  const PrivacyPageHeader({
    super.key,
    required this.title,
    required this.onOpenSwitcher,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onOpenSwitcher;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(PrivacySpace.md, PrivacySpace.sm, PrivacySpace.sm, PrivacySpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            key: const Key('privacy_app_switcher'),
            container: true,
            button: true,
            label: 'Open app switcher',
            child: ExcludeSemantics(
              child: OmiIconButton.filled(
                icon: const Icon(Icons.grid_view_rounded),
                label: 'Open app switcher',
                onPressed: onOpenSwitcher,
                color: theme.palette.text,
                fillColor: theme.palette.surface,
              ),
            ),
          ),
          const SizedBox(width: PrivacySpace.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: PrivacySpace.xxs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(header: true, child: Text(title, style: theme.title())),
                  if (subtitle != null) ...[
                    const SizedBox(height: PrivacySpace.xxs),
                    Text(subtitle!, style: theme.meta()),
                  ],
                ],
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: PrivacySpace.xs),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class PrivacySectionLabel extends StatelessWidget {
  const PrivacySectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: PrivacySpace.lg, bottom: PrivacySpace.xs),
      child: Text(label, style: PrivacyScope.of(context).section()),
    );
  }
}

enum PrivacyButtonKind { primary, secondary, quiet, destructive }

class PrivacyButton extends StatelessWidget {
  const PrivacyButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = PrivacyButtonKind.primary,
    this.expand = false,
  });

  const PrivacyButton.secondary({super.key, required this.label, required this.onPressed, this.expand = false})
      : kind = PrivacyButtonKind.secondary;

  const PrivacyButton.quiet({super.key, required this.label, required this.onPressed, this.expand = false})
      : kind = PrivacyButtonKind.quiet;

  const PrivacyButton.destructive({super.key, required this.label, required this.onPressed, this.expand = false})
      : kind = PrivacyButtonKind.destructive;

  final String label;
  final Future<void> Function()? onPressed;
  final PrivacyButtonKind kind;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    final colors = theme.palette;
    final enabled = onPressed != null;
    final background = switch (kind) {
      PrivacyButtonKind.primary => enabled ? colors.accent : colors.disabled,
      PrivacyButtonKind.secondary => colors.surfaceSecondary,
      PrivacyButtonKind.quiet => colors.background,
      PrivacyButtonKind.destructive => colors.surface,
    };
    final foreground = switch (kind) {
      PrivacyButtonKind.primary => colors.onAccent,
      PrivacyButtonKind.destructive => colors.destructive,
      _ => colors.text,
    };
    final button = Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        child: Material(
          color: background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PrivacyRadius.control),
            side: BorderSide(color: kind == PrivacyButtonKind.destructive ? colors.destructive : colors.border),
          ),
          child: InkWell(
            onTap: onPressed == null
                ? null
                : () {
                    onPressed!();
                  },
            borderRadius: BorderRadius.circular(PrivacyRadius.control),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: PrivacySpace.md, vertical: PrivacySpace.sm),
              child: Text(label,
                  textAlign: TextAlign.center,
                  style: theme.body().copyWith(color: foreground, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
    if (!expand) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}

class PrivacyCard extends StatelessWidget {
  const PrivacyCard({
    super.key,
    required this.child,
    this.tint,
    this.onTap,
    this.semanticLabel,
    this.padding = const EdgeInsets.all(PrivacySpace.md),
  });

  final Widget child;
  final Color? tint;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = PrivacyScope.of(context).palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: PrivacySpace.sm),
      child: Semantics(
        button: onTap != null,
        label: semanticLabel,
        child: Material(
          color: tint ?? colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PrivacyRadius.card),
            side: BorderSide(color: colors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: padding,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class PrivacyBadge extends StatelessWidget {
  const PrivacyBadge({super.key, required this.label, required this.kind});

  final String label;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    final color = theme.stateColor(kind);
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: PrivacySpace.sm, vertical: PrivacySpace.xxs),
        decoration: BoxDecoration(
          color: colorsWithAlpha(color),
          borderRadius: BorderRadius.circular(PrivacyRadius.pill),
          border: Border.all(color: color),
        ),
        child: Text(label, style: theme.caption().copyWith(color: color, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

Color colorsWithAlpha(Color color) => color.withValues(alpha: 0.16);

class PrivacyCaptureOrb extends StatelessWidget {
  const PrivacyCaptureOrb({super.key, required this.label, required this.kind, required this.icon});

  final String label;
  final String kind;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    final color = theme.stateColor(kind);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final live = kind == 'recording' && !reduce;
    return Column(
      children: [
        Semantics(
          label: label,
          child: AnimatedContainer(
            duration: reduce ? Duration.zero : const Duration(milliseconds: 240),
            width: 168,
            height: 168,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.palette.surface,
              border: Border.all(color: color, width: live ? 3 : 1.5),
              boxShadow: live ? [BoxShadow(color: colorsWithAlpha(color), blurRadius: 28, spreadRadius: 4)] : const [],
            ),
            child: Icon(icon, color: color, size: 48),
          ),
        ),
        const SizedBox(height: PrivacySpace.md),
        Text(label, style: theme.title(), textAlign: TextAlign.center),
      ],
    );
  }
}

class PrivacyField extends StatelessWidget {
  const PrivacyField({
    super.key,
    required this.controller,
    required this.label,
    this.obscure = false,
    this.onChanged,
    this.helperText,
    this.errorText,
    this.enabled = true,
    this.autocorrect = true,
    this.keyboardType,
    this.textInputAction,
    this.minLines,
    this.maxLines = 1,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final ValueChanged<String>? onChanged;
  final String? helperText;
  final String? errorText;
  final bool enabled;
  final bool autocorrect;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final int? minLines;
  final int? maxLines;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return TextField(
      controller: controller,
      obscureText: obscure,
      onChanged: onChanged,
      enabled: enabled,
      autocorrect: autocorrect,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      minLines: obscure ? 1 : minLines,
      maxLines: obscure ? 1 : maxLines,
      autofocus: autofocus,
      style: theme.body(),
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        errorText: errorText,
        labelStyle: theme.meta(),
        filled: true,
        fillColor: theme.palette.surfaceSecondary,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PrivacyRadius.control),
          borderSide: BorderSide(color: theme.palette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PrivacyRadius.control),
          borderSide: BorderSide(color: theme.palette.focus, width: 1.5),
        ),
      ),
    );
  }
}

class PrivacyStatusRow extends StatelessWidget {
  const PrivacyStatusRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.active,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    final color = active ? theme.palette.success : theme.palette.textSecondary;
    return Semantics(
      label: '$label: $value',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            ExcludeSemantics(child: Icon(icon, size: 20, color: color)),
            const SizedBox(width: PrivacySpace.sm),
            Expanded(child: Text(label, style: theme.body())),
            const SizedBox(width: PrivacySpace.sm),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: theme.meta().copyWith(color: color, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PrivacySettingsGroup extends StatelessWidget {
  const PrivacySettingsGroup({super.key, required this.children, this.label, this.footer});

  final String? label;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PrivacySpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: PrivacySpace.xs, bottom: PrivacySpace.xs),
              child: Text(label!, style: theme.section()),
            ),
          ],
          Material(
            color: theme.palette.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PrivacyRadius.card),
              side: BorderSide(color: theme.palette.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var index = 0; index < children.length; index++) ...[
                  if (index > 0) Divider(height: 1, color: theme.palette.border),
                  children[index],
                ],
              ],
            ),
          ),
          if (footer != null) ...[
            const SizedBox(height: PrivacySpace.xs),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: PrivacySpace.xs),
              child: Text(footer!, style: theme.meta()),
            ),
          ],
        ],
      ),
    );
  }
}

class PrivacySettingsRow extends StatelessWidget {
  const PrivacySettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.destructive = false,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value;
  final VoidCallback? onTap;
  final bool destructive;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    final foreground = destructive ? theme.palette.destructive : theme.palette.text;
    return Semantics(
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: PrivacySpace.md, vertical: PrivacySpace.sm),
            child: Row(
              children: [
                ExcludeSemantics(child: Icon(icon, size: 22, color: foreground)),
                const SizedBox(width: PrivacySpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.body().copyWith(color: foreground, fontWeight: FontWeight.w600)),
                      if (subtitle != null) ...[
                        const SizedBox(height: PrivacySpace.xxs),
                        Text(subtitle!, style: theme.meta()),
                      ],
                    ],
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: PrivacySpace.sm),
                  Flexible(
                    child: Text(value!, maxLines: 2, textAlign: TextAlign.end, style: theme.meta()),
                  ),
                ],
                if (trailing != null) ...[
                  const SizedBox(width: PrivacySpace.sm),
                  trailing!,
                ] else if (onTap != null) ...[
                  const SizedBox(width: PrivacySpace.xs),
                  ExcludeSemantics(child: Icon(Icons.chevron_right, color: theme.palette.textSecondary)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PrivacyChoiceRow extends StatelessWidget {
  const PrivacyChoiceRow({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: Padding(
        padding: const EdgeInsets.only(bottom: PrivacySpace.xs),
        child: Material(
          color: selected ? colorsWithAlpha(theme.palette.accent) : theme.palette.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PrivacyRadius.control),
            side: BorderSide(color: selected ? theme.palette.accent : theme.palette.border),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(PrivacyRadius.control),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: PrivacySpace.md),
                child: Row(
                  children: [
                    Icon(selected ? Icons.check_circle : Icons.circle_outlined,
                        color: selected ? theme.palette.accent : theme.palette.textSecondary),
                    const SizedBox(width: PrivacySpace.sm),
                    Expanded(child: Text(label, style: theme.body())),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PrivacyEmpty extends StatelessWidget {
  const PrivacyEmpty({super.key, required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return Padding(
      padding: const EdgeInsets.all(PrivacySpace.lg),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined, color: theme.palette.textSecondary),
          const SizedBox(height: PrivacySpace.sm),
          Text(title, style: theme.section()),
          const SizedBox(height: PrivacySpace.xs),
          Text(message, style: theme.meta(), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class PrivacyThemeTile extends StatelessWidget {
  const PrivacyThemeTile({super.key, required this.theme, required this.selected, required this.onTap});

  final PrivacyTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: theme.name,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.palette.background,
                  borderRadius: BorderRadius.circular(PrivacyRadius.control),
                  border: Border.all(color: theme.palette.accent, width: 3),
                ),
              ),
              const SizedBox(width: PrivacySpace.sm),
              Expanded(child: Text(theme.name, style: PrivacyScope.of(context).body())),
              if (selected) Icon(Icons.check, color: PrivacyScope.of(context).palette.accent),
            ],
          ),
        ),
      ),
    );
  }
}
