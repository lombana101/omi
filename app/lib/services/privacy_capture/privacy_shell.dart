import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/services/privacy_capture/privacy_action_config.dart';
import 'package:omi/services/privacy_capture/privacy_capture_config.dart';
import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';
import 'package:omi/services/privacy_capture/privacy_capture_feature.dart';
import 'package:omi/services/privacy_capture/privacy_capture_io.dart';
import 'package:omi/services/privacy_capture/privacy_connection_probe.dart';
import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_client.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_config.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_coordinator.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_models.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_ui.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_off_link.dart';
import 'package:omi/services/privacy_capture/privacy_pendant_battery.dart';
import 'package:omi/services/privacy_capture/privacy_quick_capture.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:omi/services/privacy_capture/privacy_suggestion.dart';
import 'package:omi/services/privacy_capture/privacy_theme.dart';
import 'package:omi/services/privacy_capture/privacy_widgets.dart';
import 'package:omi/services/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/ui/ui.dart';
import 'package:omi/utils/other/temp.dart';

class PrefsPrivacyThemeStore implements PrivacyThemeStore {
  static const key = 'privacy_visual_theme';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, id);
  }
}

class PrivacyShell extends StatefulWidget {
  const PrivacyShell({
    super.key,
    this.findPendant,
    this.store,
    this.controller,
    this.clock,
    this.initialTab = 0,
    this.themeStore,
    this.quickPreferences,
    this.pendantBattery,
    this.intelligenceClient,
  });

  final Future<String> Function()? findPendant;
  final PrivacyStore? store;
  final PrivacyCaptureController? controller;
  final DateTime Function()? clock;
  final int initialTab;
  final PrivacyThemeStore? themeStore;
  final QuickSelfCapturePreferences? quickPreferences;
  final ValueListenable<PrivacyPendantBatteryStatus>? pendantBattery;
  final PrivacyIntelligenceClient? intelligenceClient;

  @override
  State<PrivacyShell> createState() => _PrivacyShellState();
}

class _PrivacyShellState extends State<PrivacyShell> with WidgetsBindingObserver {
  var _tab = 0;
  PrivacyStore? _store;
  var _link = PrivacyCopy.notConnected;
  var _busy = false;
  PrivacyRetentionChoice? _retention;
  String? _receipt;
  final _purpose = TextEditingController();
  var _selfOnly = false;
  var _mixed = false;
  var _quick = const QuickSelfCaptureSettings();
  var _quickLoaded = false;
  String? _quickMessage;
  late final PrivacyThemeController _themes =
      PrivacyThemeController(store: widget.themeStore ?? PrefsPrivacyThemeStore());

  PrivacyCaptureController? get _controller {
    if (widget.controller != null) return widget.controller;
    if (!privacyCaptureEnabled) return null;
    return PrivacyCaptureHost.controller;
  }

  DateTime get _now => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab.clamp(0, 4);
    WidgetsBinding.instance.addObserver(this);
    if (widget.quickPreferences == null) {
      PrivacyCaptureHost.quickSettings.addListener(_hostQuickSettingsChanged);
      PrivacyCaptureHost.quickMessage.addListener(_hostQuickMessageChanged);
    }
    unawaited(_themes.load());
    unawaited(_boot());
  }

  Future<void> _boot() async {
    QuickSelfCaptureSettings quick;
    try {
      quick = await (widget.quickPreferences ?? PrivacyCaptureHost.quickPreferences).load();
    } catch (_) {
      quick = const QuickSelfCaptureSettings();
    }
    if (mounted) {
      setState(() {
        _quick = quick;
        _quickLoaded = true;
        if (widget.quickPreferences == null) {
          _quickMessage = PrivacyCaptureHost.quickMessage.value;
        }
      });
    }
    if (widget.store != null) {
      _store = widget.store;
      await _store!.recoverLaunch(_now);
      await _store!.expireDue(_now);
    } else if (privacyCaptureEnabled) {
      await PrivacyCaptureHost.ensureReady();
      _store = PrivacyCaptureHost.store;
      unawaited(_restoreQuickPendantLink());
    }
    final retention = await _store?.readRetention();
    if (!mounted) return;
    setState(() => _retention = retention);
  }

  void _hostQuickSettingsChanged() {
    if (!mounted) return;
    setState(() => _quick = PrivacyCaptureHost.quickSettings.value);
  }

  void _hostQuickMessageChanged() {
    if (!mounted) return;
    setState(() => _quickMessage = PrivacyCaptureHost.quickMessage.value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller?.onForeground());
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_controller?.onBackground());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.quickPreferences == null) {
      PrivacyCaptureHost.quickSettings.removeListener(_hostQuickSettingsChanged);
      PrivacyCaptureHost.quickMessage.removeListener(_hostQuickMessageChanged);
    }
    _themes.dispose();
    _purpose.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _themes,
      builder: (context, _) {
        final theme = _themes.theme;
        OmiColors.active = theme.toOmiPalette();
        return PrivacyScope(
          theme: theme,
          child: Theme(
            data: theme.toThemeData(),
            child: PrivacyScaffold(
              body: IndexedStack(
                index: _tab,
                children: [
                  TickerMode(enabled: _tab == 0, child: _capture()),
                  TickerMode(
                    enabled: _tab == 1,
                    child: _SessionsTab(
                      intelligenceClient: widget.intelligenceClient,
                      store: _store,
                      now: _now,
                      onChanged: _refresh,
                      onOpenSwitcher: _openSwitcher,
                      quickMessage: _quickMessage,
                    ),
                  ),
                  TickerMode(
                    enabled: _tab == 2,
                    child: _TasksTab(
                      store: _store,
                      now: _now,
                      onChanged: _refresh,
                      onOpenSwitcher: _openSwitcher,
                      quickMessage: _quickMessage,
                      intelligenceClient: widget.intelligenceClient,
                    ),
                  ),
                  TickerMode(
                    enabled: _tab == 3,
                    child: PrivacyAssistantTab(
                      store: _store,
                      now: _now,
                      onChanged: _refresh,
                      client: widget.intelligenceClient,
                      onOpenSwitcher: _openSwitcher,
                    ),
                  ),
                  TickerMode(
                    enabled: _tab == 4,
                    child: _SettingsTab(
                      store: _store,
                      retention: _retention,
                      onRetention: _setRetention,
                      receipt: _receipt,
                      themes: _themes,
                      onOpenSwitcher: _openSwitcher,
                      quick: _quick,
                      quickLoaded: _quickLoaded,
                      onOpenQuick: _openQuickSettings,
                      quickMessage: _quickMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _refresh() async {
    if (mounted) setState(() {});
  }

  Future<void> _setRetention(PrivacyRetentionChoice choice) async {
    final result = await _store?.setRetention(choice, at: _now);
    if (!mounted || result == null || !result.ok) return;
    setState(() => _retention = choice);
  }

  Future<void> _openSwitcher() async {
    final counts = await _navigationCounts();
    if (!mounted) return;
    await showOmiSheet<void>(
      context: context,
      title: 'Go to',
      builder: (sheetContext) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.only(bottom: PrivacySpace.md),
          child: Column(
            children: [
              _DestinationOption(
                key: const Key('privacy_destination_0'),
                icon: Icons.mic_none_rounded,
                label: PrivacyCopy.capture,
                description: PrivacyCopy.captureDescription,
                selected: _tab == 0,
                onTap: () => _selectDestination(sheetContext, 0),
              ),
              _DestinationOption(
                key: const Key('privacy_destination_1'),
                icon: Icons.view_agenda_outlined,
                label: PrivacyCopy.sessions,
                description: PrivacyCopy.sessionsDescription,
                count: counts.sessions,
                selected: _tab == 1,
                onTap: () => _selectDestination(sheetContext, 1),
              ),
              _DestinationOption(
                key: const Key('privacy_destination_2'),
                icon: Icons.check_circle_outline_rounded,
                label: PrivacyCopy.tasks,
                description: PrivacyCopy.tasksDescription,
                count: counts.tasks,
                selected: _tab == 2,
                onTap: () => _selectDestination(sheetContext, 2),
              ),
              _DestinationOption(
                key: const Key('privacy_destination_3'),
                icon: Icons.auto_awesome_outlined,
                label: PrivacyCopy.assistant,
                description: PrivacyCopy.assistantDescription,
                selected: _tab == 3,
                onTap: () => _selectDestination(sheetContext, 3),
              ),
              _DestinationOption(
                key: const Key('privacy_destination_4'),
                icon: Icons.settings_outlined,
                label: PrivacyCopy.settings,
                description: PrivacyCopy.settingsDescription,
                selected: _tab == 4,
                onTap: () => _selectDestination(sheetContext, 4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectDestination(BuildContext sheetContext, int index) {
    Navigator.of(sheetContext).pop();
    if (_tab == index || !mounted) return;
    OmiHaptics.selection();
    setState(() => _tab = index);
  }

  Future<_NavigationCounts> _navigationCounts() async {
    final store = _store;
    if (store == null) return const _NavigationCounts();
    try {
      final sessions = await store.sessions();
      final tasks = await store.tasks();
      return _NavigationCounts(
        sessions: sessions.length,
        tasks: tasks.where((task) => task.isOpen).length,
      );
    } catch (_) {
      return const _NavigationCounts();
    }
  }

  Future<void> _updateQuick(QuickSelfCaptureSettings settings) async {
    if (widget.quickPreferences != null) {
      await widget.quickPreferences!.save(settings);
      final controller = _controller;
      if (!settings.enabled &&
          controller?.captureOrigin == PrivacyCaptureConfig.pendantQuickCaptureOrigin &&
          controller?.state != PrivacyCaptureState.off) {
        await controller?.onBackground();
      }
      if (!mounted) return;
      setState(() {
        _quick = settings;
        _quickMessage = null;
      });
      return;
    }
    await PrivacyCaptureHost.updateQuickSettings(settings);
    if (settings.ready) unawaited(_restoreQuickPendantLink());
  }

  Future<void> _restoreQuickPendantLink() async {
    if (widget.store != null || !privacyCaptureEnabled) return;
    final saved = SharedPreferencesUtil().btDevice;
    if (saved.id.isEmpty) {
      await PrivacyCaptureHost.pendantBattery.clear();
      return;
    }
    try {
      final connection = await ServiceManager.instance()
          .device
          .ensureConnection(saved.id, force: true)
          .timeout(const Duration(seconds: 8));
      if (connection == null) return;
      await PrivacyCaptureHost.armConnectedLink(
        connection.transport,
        deviceId: saved.id,
      ).timeout(const Duration(seconds: 8));
      await PrivacyCaptureHost.observePendantBattery(connection).timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _link = decidePrivacyConnect(linkEstablished: true, name: saved.name).label;
      });
    } catch (_) {
      await PrivacyCaptureHost.pendantBattery.clear();
      // The status card remains disconnected. A later explicit Find pendant
      // action can retry without weakening the capture admission gate.
    }
  }

  Future<void> _openQuickSettings() async {
    var draft = _quick;
    await showOmiSheet<void>(
      context: context,
      title: PrivacyCopy.quickSelfCapture,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          Future<void> save(QuickSelfCaptureSettings next) async {
            draft = next;
            setSheetState(() {});
            await _updateQuick(next);
          }

          return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Padding(
              padding: const EdgeInsets.only(bottom: PrivacySpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PrivacySettingsGroup(
                    children: [
                      PrivacySettingsRow(
                        icon: Icons.touch_app_outlined,
                        title: PrivacyCopy.enable,
                        subtitle: draft.enabled ? PrivacyCopy.enabled : PrivacyCopy.disabled,
                        trailing: Switch.adaptive(
                          key: const Key('privacy_quick_toggle'),
                          value: draft.enabled,
                          onChanged: (enabled) async {
                            if (enabled) {
                              final confirmed = await showOmiConfirm(
                                sheetContext,
                                title: PrivacyCopy.quickSelfCapture,
                                message: PrivacyCopy.quickAssertion,
                                confirmLabel: PrivacyCopy.enable,
                              );
                              if (!confirmed || !sheetContext.mounted) return;
                            }
                            await save(draft.copyWith(enabled: enabled));
                          },
                        ),
                      ),
                    ],
                  ),
                  Text(PrivacyCopy.quickAssertion, style: PrivacyScope.of(sheetContext).body()),
                  const SizedBox(height: PrivacySpace.sm),
                  const _PrivacyNotice(
                    icon: Icons.person_outline,
                    title: PrivacyCopy.quickWarning,
                    message: PrivacyCopy.quickMixedGuidance,
                    kind: 'interrupted',
                  ),
                  const PrivacySectionLabel(PrivacyCopy.quickPurpose),
                  for (final purpose in QuickSelfCapturePurpose.values)
                    PrivacyChoiceRow(
                      key: Key('privacy_quick_purpose_${purpose.name}'),
                      label: _quickPurposeLabel(purpose),
                      selected: draft.purpose == purpose,
                      onTap: () => save(draft.copyWith(purpose: purpose)),
                    ),
                  const PrivacySectionLabel(PrivacyCopy.quickRetention),
                  for (final choice in PrivacyRetentionChoice.values)
                    PrivacyChoiceRow(
                      key: Key('privacy_quick_retention_${choice.name}'),
                      label: _retentionLabel(choice),
                      selected: draft.retention == choice,
                      onTap: () => save(draft.copyWith(retention: choice)),
                    ),
                  if (draft.enabled && !draft.ready) ...[
                    const SizedBox(height: PrivacySpace.sm),
                    Text(PrivacyCopy.quickIncomplete, style: PrivacyScope.of(sheetContext).meta()),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _capture() {
    final controller = _controller;
    return Column(
      children: [
        PrivacyPageHeader(
          title: PrivacyCopy.capture,
          subtitle: 'Private capture, on your terms',
          onOpenSwitcher: _openSwitcher,
        ),
        Expanded(
          child: ListView(
            key: const PageStorageKey('privacy_capture_scroll'),
            padding: const EdgeInsets.fromLTRB(
              PrivacySpace.md,
              PrivacySpace.xs,
              PrivacySpace.md,
              PrivacySpace.xxl,
            ),
            children: [
              ValueListenableBuilder<PrivacyCaptureState>(
                valueListenable: privacyCaptureEnabled ? PrivacyCaptureHost.state : _localState,
                builder: (context, hostState, _) {
                  final state = controller?.state ?? hostState;
                  final label = _status(state, controller);
                  final kind = _stateKind(state, controller);
                  return Column(
                    children: [
                      Semantics(
                        key: const Key('privacy_state'),
                        liveRegion: true,
                        label: label,
                        child: PrivacyCaptureOrb(label: label, kind: kind, icon: _stateIcon(kind)),
                      ),
                      if (state == PrivacyCaptureState.recording &&
                          controller?.captureOrigin == PrivacyCaptureConfig.pendantQuickCaptureOrigin) ...[
                        const SizedBox(height: PrivacySpace.xs),
                        Text(PrivacyCopy.quickRecordingOrigin, style: PrivacyScope.of(context).meta()),
                      ],
                      if (state == PrivacyCaptureState.recording || state == PrivacyCaptureState.authorizing) ...[
                        const SizedBox(height: PrivacySpace.md),
                        PrivacyButton.destructive(
                          key: const Key('privacy_stop'),
                          label: PrivacyCopy.stop,
                          onPressed: () async => controller?.stop(),
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: PrivacySpace.lg),
              if (!_quickLoaded)
                const OmiLoadingState(label: 'Loading Quick Self Capture…')
              else if (_quick.ready)
                PrivacyCard(
                  key: const Key('privacy_quick_ready'),
                  tint: colorsWithAlpha(PrivacyScope.of(context).palette.success),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.bolt_rounded, color: PrivacyScope.of(context).palette.success),
                          const SizedBox(width: PrivacySpace.sm),
                          Expanded(
                            child: Text(
                              PrivacyCopy.quickReady,
                              style: PrivacyScope.of(context).section(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: PrivacySpace.sm),
                      Text(_quickPurposeLabel(_quick.purpose!), style: PrivacyScope.of(context).body()),
                      Text(_retentionLabel(_quick.retention!), style: PrivacyScope.of(context).meta()),
                      const SizedBox(height: PrivacySpace.xs),
                      Text(
                        PrivacyCopy.quickDoubleTap,
                        style: PrivacyScope.of(context).body().copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                )
              else
                PrivacyCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(PrivacyCopy.quickSelfCapture, style: PrivacyScope.of(context).section()),
                      const SizedBox(height: PrivacySpace.xs),
                      Text(PrivacyCopy.quickBenefit, style: PrivacyScope.of(context).body()),
                      const SizedBox(height: PrivacySpace.md),
                      PrivacyButton(
                        key: const Key('privacy_quick_setup'),
                        label: PrivacyCopy.quickSetup,
                        expand: true,
                        onPressed: _openQuickSettings,
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: PrivacyButton.quiet(
                  key: const Key('privacy_manual_options'),
                  label: PrivacyCopy.manualCaptureOptions,
                  onPressed: _openManualCaptureOptions,
                ),
              ),
              if (_quickMessage != null) ...[
                const SizedBox(height: PrivacySpace.xs),
                _PrivacyNotice(
                  icon: Icons.info_outline,
                  title: PrivacyCopy.quickSelfCapture,
                  message: _quickMessage!,
                  kind: 'interrupted',
                ),
              ],
              if (PrivacyCaptureHost.bootError != null) ...[
                const SizedBox(height: PrivacySpace.xs),
                _PrivacyNotice(
                  icon: Icons.error_outline,
                  title: PrivacyCopy.storeUnavailable,
                  message: PrivacyCaptureHost.bootError!,
                  kind: 'destructive',
                ),
              ],
              const SizedBox(height: PrivacySpace.sm),
              ValueListenableBuilder<PrivacyLinkDiagnostics>(
                valueListenable: PrivacyCaptureHost.diagnostics,
                builder: (context, diag, _) {
                  final connected = diag.buttonSubscribed || _link != PrivacyCopy.notConnected;
                  return ValueListenableBuilder<PrivacyPendantBatteryStatus>(
                    valueListenable: widget.pendantBattery ?? PrivacyCaptureHost.pendantBattery,
                    builder: (context, battery, _) => PrivacyCard(
                      key: const Key('privacy_connection_status'),
                      child: Column(
                        children: [
                          PrivacyStatusRow(
                            icon: Icons.watch_outlined,
                            label: PrivacyCopy.connectionStatus,
                            value: connected ? PrivacyCopy.connected : PrivacyCopy.disconnected,
                            active: connected,
                          ),
                          Divider(height: 1, color: PrivacyScope.of(context).palette.border),
                          PrivacyStatusRow(
                            key: const Key('privacy_pendant_battery'),
                            icon: Icons.battery_std_rounded,
                            label: PrivacyCopy.pendantBattery,
                            value: !battery.connected
                                ? PrivacyCopy.disconnected
                                : battery.level == null
                                    ? PrivacyCopy.unavailable
                                    : '${battery.level}%',
                            active: battery.available,
                          ),
                          Divider(height: 1, color: PrivacyScope.of(context).palette.border),
                          PrivacyStatusRow(
                            icon: Icons.touch_app_outlined,
                            label: 'Button notifications',
                            value: diag.buttonSubscribed ? PrivacyCopy.subscribed : PrivacyCopy.unsubscribed,
                            active: diag.buttonSubscribed,
                          ),
                          Divider(height: 1, color: PrivacyScope.of(context).palette.border),
                          PrivacyStatusRow(
                            icon: Icons.graphic_eq_rounded,
                            label: 'Audio admission',
                            value: diag.audioSubscribed ? PrivacyCopy.subscribed : PrivacyCopy.unsubscribed,
                            active: diag.audioSubscribed,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              Wrap(
                spacing: PrivacySpace.xs,
                runSpacing: PrivacySpace.xs,
                children: [
                  PrivacyButton.secondary(
                    key: const Key('privacy_connect'),
                    label: _busy ? PrivacyCopy.looking : PrivacyCopy.connect,
                    onPressed: _busy ? null : _find,
                  ),
                ],
              ),
              const SizedBox(height: PrivacySpace.sm),
              Text(PrivacyCopy.offExplain, style: PrivacyScope.of(context).meta()),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openManualCaptureOptions() async {
    await showOmiSheet<void>(
      context: context,
      title: PrivacyCopy.manualCapture,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final missing = _missingStart;
          return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Padding(
              padding: const EdgeInsets.only(bottom: PrivacySpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Use this phone flow when another person may be recorded or when you need a different purpose.',
                    style: PrivacyScope.of(sheetContext).body(),
                  ),
                  const PrivacySectionLabel(PrivacyCopy.purposeLabel),
                  PrivacyField(
                    key: const Key('privacy_purpose'),
                    controller: _purpose,
                    label: PrivacyCopy.purposeLabel,
                    helperText: 'Describe why you are making this capture.',
                    textInputAction: TextInputAction.done,
                    onChanged: (_) {
                      setState(() {});
                      setSheetState(() {});
                    },
                  ),
                  const PrivacySectionLabel(PrivacyCopy.chooseRetention),
                  Text(PrivacyCopy.retentionNote, style: PrivacyScope.of(sheetContext).meta()),
                  const SizedBox(height: PrivacySpace.sm),
                  for (final choice in PrivacyRetentionChoice.values)
                    PrivacyChoiceRow(
                      label: _retentionLabel(choice),
                      selected: _retention == choice,
                      onTap: () async {
                        await _setRetention(choice);
                        if (sheetContext.mounted) setSheetState(() {});
                      },
                    ),
                  const PrivacySectionLabel('Who may be recorded?'),
                  Text(PrivacyCopy.selfOnlyExplain, style: PrivacyScope.of(sheetContext).meta()),
                  CheckboxListTile(
                    key: const Key('privacy_self_only'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _selfOnly,
                    onChanged: (value) {
                      setState(() {
                        _selfOnly = value ?? false;
                        if (_selfOnly) _mixed = false;
                      });
                      setSheetState(() {});
                    },
                    title: const Text(PrivacyCopy.assertSelfOnly),
                  ),
                  const SizedBox(height: PrivacySpace.xs),
                  PrivacyCard(
                    tint: colorsWithAlpha(PrivacyScope.of(sheetContext).palette.warning),
                    child: CheckboxListTile(
                      key: const Key('privacy_mixed'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _mixed,
                      onChanged: (value) {
                        setState(() {
                          _mixed = value ?? false;
                          if (_mixed) _selfOnly = false;
                        });
                        setSheetState(() {});
                      },
                      title: const Text(PrivacyCopy.assertMixed),
                      subtitle: const Text('Make this assertion only after everyone present has actively consented.'),
                    ),
                  ),
                  const SizedBox(height: PrivacySpace.sm),
                  Wrap(
                    spacing: PrivacySpace.xs,
                    runSpacing: PrivacySpace.xs,
                    children: [
                      PrivacyButton.secondary(
                        label: _busy ? PrivacyCopy.looking : PrivacyCopy.connect,
                        onPressed: _busy ? null : _find,
                      ),
                    ],
                  ),
                  if (missing != null) ...[
                    const SizedBox(height: PrivacySpace.sm),
                    Text(
                      missing,
                      key: const Key('privacy_start_missing'),
                      style: PrivacyScope.of(sheetContext).meta(),
                    ),
                  ],
                  const SizedBox(height: PrivacySpace.md),
                  PrivacyButton(
                    key: const Key('privacy_start'),
                    label: PrivacyCopy.start,
                    expand: true,
                    onPressed: missing == null
                        ? () async {
                            await _start();
                            if (!sheetContext.mounted) return;
                            Navigator.of(sheetContext).pop();
                          }
                        : null,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String? get _missingStart {
    if (_retention == null) return PrivacyCopy.missingRetention;
    if (_purpose.text.trim().isEmpty) return PrivacyCopy.missingPurpose;
    if (!_selfOnly && !_mixed) return PrivacyCopy.missingConsent;
    return null;
  }

  String _stateKind(PrivacyCaptureState state, PrivacyCaptureController? controller) {
    switch (state) {
      case PrivacyCaptureState.recording:
        return 'recording';
      case PrivacyCaptureState.error:
        return 'interrupted';
      case PrivacyCaptureState.off:
        if (controller?.incomplete ?? false) return 'interrupted';
        return 'accent';
      default:
        return 'accent';
    }
  }

  IconData _stateIcon(String kind) {
    switch (kind) {
      case 'recording':
        return Icons.graphic_eq;
      case 'interrupted':
        return Icons.pause_circle_outline;
      default:
        return Icons.mic_none;
    }
  }

  Future<void> _find() async {
    setState(() => _busy = true);
    try {
      final result = await (widget.findPendant ?? _discoverPendant)();
      if (!mounted) return;
      setState(() => _link = result);
    } catch (_) {
      if (widget.findPendant == null) await PrivacyCaptureHost.pendantBattery.clear();
      if (!mounted) return;
      setState(() => _link = PrivacyCopy.notConnected);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() async {
    final controller = _controller;
    final store = _store;
    if (controller == null || store == null) return;
    if (_retention == null) return;
    final purpose = _purpose.text.trim();
    if (purpose.isEmpty || (!_selfOnly && !_mixed)) return;
    controller.ownerPurpose = purpose;
    controller.purpose = PrivacyCaptureConfig.defaultPurpose;
    controller.requireConsentAssertion = true;
    if (_mixed) {
      controller.armParticipantsConsented(consentObtained: true);
    } else {
      controller.assertSelfOnly();
    }
    await controller.start();
    if (!mounted) return;
    setState(() {
      _selfOnly = false;
      _mixed = false;
    });
  }

  String _status(PrivacyCaptureState state, PrivacyCaptureController? controller) {
    if (_busy && state == PrivacyCaptureState.off) return PrivacyCopy.connecting;
    switch (state) {
      case PrivacyCaptureState.recording:
        return PrivacyCopy.recording;
      case PrivacyCaptureState.finalizing:
        return PrivacyCopy.processing;
      case PrivacyCaptureState.authorizing:
        return PrivacyCopy.waiting;
      case PrivacyCaptureState.error:
        return '${PrivacyCopy.recordingOff}. ${PrivacyCopy.interrupted}';
      case PrivacyCaptureState.off:
        final incomplete = controller?.incomplete ?? false;
        final outcome = controller?.lastOutcome;
        if (!incomplete && outcome != null && PrivacyCaptureConfig.successfulOutcomes.contains(outcome)) {
          return '${PrivacyCopy.recordingOff}. ${PrivacyCopy.completed}';
        }
        if (incomplete) return '${PrivacyCopy.recordingOff}. ${PrivacyCopy.interrupted}';
        return PrivacyCopy.recordingOff;
    }
  }

  static String _retentionLabel(PrivacyRetentionChoice choice) {
    switch (choice) {
      case PrivacyRetentionChoice.sessionOnly:
        return PrivacyCopy.sessionOnly;
      case PrivacyRetentionChoice.hours24:
        return PrivacyCopy.hours24;
      case PrivacyRetentionChoice.days7:
        return PrivacyCopy.days7;
      case PrivacyRetentionChoice.untilDeleted:
        return PrivacyCopy.untilDeleted;
    }
  }

  static String _quickPurposeLabel(QuickSelfCapturePurpose purpose) {
    switch (purpose) {
      case QuickSelfCapturePurpose.personalNote:
        return PrivacyCopy.personalNotePurpose;
      case QuickSelfCapturePurpose.selfReflection:
        return PrivacyCopy.selfReflectionPurpose;
      case QuickSelfCapturePurpose.taskCapture:
        return PrivacyCopy.taskCapturePurpose;
    }
  }
}

class _NavigationCounts {
  const _NavigationCounts({this.sessions, this.tasks});

  final int? sessions;
  final int? tasks;
}

class _DestinationOption extends StatelessWidget {
  const _DestinationOption({
    super.key,
    required this.icon,
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final IconData icon;
  final String label;
  final String description;
  final bool selected;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PrivacySpace.xs),
      child: Semantics(
        button: true,
        selected: selected,
        label: count == null ? '$label. $description' : '$label, $count. $description',
        excludeSemantics: true,
        child: Material(
          color: selected ? colorsWithAlpha(theme.palette.accent) : theme.palette.surfaceSecondary,
          borderRadius: BorderRadius.circular(PrivacyRadius.control),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(PrivacyRadius.control),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 68),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: PrivacySpace.md, vertical: PrivacySpace.sm),
                child: Row(
                  children: [
                    Icon(icon, color: selected ? theme.palette.accent : theme.palette.text, size: 24),
                    const SizedBox(width: PrivacySpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(label, style: theme.body().copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: PrivacySpace.xxs),
                          Text(description, style: theme.meta()),
                        ],
                      ),
                    ),
                    if (count != null) ...[
                      const SizedBox(width: PrivacySpace.sm),
                      PrivacyBadge(label: '$count', kind: selected ? 'accent' : 'machine'),
                    ],
                    const SizedBox(width: PrivacySpace.xs),
                    Icon(selected ? Icons.check_rounded : Icons.chevron_right_rounded,
                        color: selected ? theme.palette.accent : theme.palette.textSecondary),
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

class _PrivacyNotice extends StatelessWidget {
  const _PrivacyNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.kind = 'accent',
  });

  final IconData icon;
  final String title;
  final String message;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    final color = theme.stateColor(kind);
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(PrivacySpace.md),
        decoration: BoxDecoration(
          color: colorsWithAlpha(color),
          borderRadius: BorderRadius.circular(PrivacyRadius.control),
          border: Border.all(color: color),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: Icon(icon, color: color)),
            const SizedBox(width: PrivacySpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.body().copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: PrivacySpace.xxs),
                  Text(message, style: theme.meta().copyWith(color: theme.palette.text)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final _localState = ValueNotifier<PrivacyCaptureState>(PrivacyCaptureState.off);

Future<T?> _routeToPrivacyPage<T>(BuildContext context, Widget page) async {
  final privacyTheme = PrivacyScope.of(context);
  final result = await routeToPage(
    context,
    PrivacyScope(
      theme: privacyTheme,
      child: Theme(data: privacyTheme.toThemeData(), child: page),
    ),
  );
  return result as T?;
}

Future<String> _discoverPendant() async {
  final devices = ServiceManager.instance().device;
  await devices.discover(timeout: 8);
  final found = devices.devices.where((device) => device.name.toLowerCase().contains('omi')).toList();
  final device = found.isEmpty ? (devices.devices.isEmpty ? null : devices.devices.first) : found.first;
  if (device == null) {
    await PrivacyCaptureHost.pendantBattery.clear();
    return 'No pendant found';
  }
  final connection = await devices.ensureConnection(device.id, force: true);
  final decision = decidePrivacyConnect(linkEstablished: connection != null, name: device.name);
  if (!decision.armButton || connection == null) {
    await PrivacyCaptureHost.pendantBattery.clear();
    return decision.label;
  }
  await SharedPreferencesUtil().btDeviceSet(device);
  await PrivacyCaptureHost.armConnectedLink(connection.transport, deviceId: device.id);
  await PrivacyCaptureHost.observePendantBattery(connection);
  return decision.label;
}

class _SessionsTab extends StatefulWidget {
  const _SessionsTab({
    this.intelligenceClient,
    required this.store,
    required this.now,
    required this.onChanged,
    required this.onOpenSwitcher,
    this.quickMessage,
  });

  final PrivacyIntelligenceClient? intelligenceClient;
  final PrivacyStore? store;
  final DateTime now;
  final Future<void> Function() onChanged;
  final VoidCallback onOpenSwitcher;
  final String? quickMessage;

  @override
  State<_SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<_SessionsTab> {
  String? _receipt;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return Column(
      children: [
        PrivacyPageHeader(
          title: PrivacyCopy.sessions,
          subtitle: PrivacyCopy.sessionsDescription,
          onOpenSwitcher: widget.onOpenSwitcher,
        ),
        if (widget.quickMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(PrivacySpace.md, 0, PrivacySpace.md, PrivacySpace.xs),
            child: _PrivacyNotice(
              icon: Icons.info_outline,
              title: PrivacyCopy.quickSelfCapture,
              message: widget.quickMessage!,
              kind: 'interrupted',
            ),
          ),
        Expanded(
          child: store == null
              ? const OmiErrorState(message: PrivacyCopy.storeUnavailable)
              : FutureBuilder<List<PrivacySessionRecord>>(
                  future: store.sessions(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const OmiLoadingState(label: PrivacyCopy.loadingSessions);
                    }
                    if (snapshot.hasError) {
                      return OmiErrorState(message: PrivacyCopy.loadFailed, onRetry: widget.onChanged);
                    }
                    final sessions = snapshot.data ?? const <PrivacySessionRecord>[];
                    if (sessions.isEmpty) {
                      return Column(
                        children: [
                          if (_receipt != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                PrivacySpace.md,
                                PrivacySpace.xs,
                                PrivacySpace.md,
                                0,
                              ),
                              child: _PrivacyNotice(
                                icon: Icons.check_circle_outline,
                                title: PrivacyCopy.deletedSuccess,
                                message: _receipt!,
                              ),
                            ),
                          const Expanded(
                            child: OmiEmptyState(
                              icon: Icons.view_agenda_outlined,
                              title: PrivacyCopy.noSessionsTitle,
                              message: 'Completed and interrupted captures stored on this phone will appear here.',
                            ),
                          ),
                        ],
                      );
                    }
                    return ListView.builder(
                      key: const PageStorageKey('privacy_sessions_scroll'),
                      padding: const EdgeInsets.fromLTRB(
                        PrivacySpace.md,
                        PrivacySpace.xs,
                        PrivacySpace.md,
                        PrivacySpace.xxl,
                      ),
                      itemCount: sessions.length + (_receipt == null ? 0 : 1),
                      itemBuilder: (context, index) {
                        if (_receipt != null && index == 0) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: PrivacySpace.sm),
                            child: _PrivacyNotice(
                              icon: Icons.check_circle_outline,
                              title: PrivacyCopy.deletedSuccess,
                              message: _receipt!,
                            ),
                          );
                        }
                        final session = sessions[index - (_receipt == null ? 0 : 1)];
                        final status = _sessionTitle(session);
                        final statusColor = session.incomplete || session.outcome == 'interrupted'
                            ? PrivacyScope.of(context).palette.warning
                            : PrivacyScope.of(context).palette.success;
                        return PrivacyCard(
                          key: Key('privacy_session_${session.localId}'),
                          semanticLabel: '$status. ${session.ownerPurpose}',
                          onTap: () => _openSession(store, session),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: colorsWithAlpha(statusColor),
                                  borderRadius: BorderRadius.circular(PrivacyRadius.control),
                                ),
                                child: Icon(
                                  session.incomplete || session.outcome == 'interrupted'
                                      ? Icons.pause_circle_outline
                                      : Icons.check_circle_outline,
                                  color: statusColor,
                                ),
                              ),
                              const SizedBox(width: PrivacySpace.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      session.ownerPurpose.trim().isEmpty ? 'Untitled capture' : session.ownerPurpose,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: PrivacyScope.of(context).body().copyWith(fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: PrivacySpace.xxs),
                                    Text(
                                      OmiDateFormat.of(context).dateTime(session.startedAt),
                                      style: PrivacyScope.of(context).meta(),
                                    ),
                                    const SizedBox(height: PrivacySpace.xs),
                                    Wrap(
                                      spacing: PrivacySpace.xs,
                                      runSpacing: PrivacySpace.xxs,
                                      children: [
                                        PrivacyBadge(
                                          label: status,
                                          kind: session.incomplete ? 'interrupted' : 'recording',
                                        ),
                                        if (session.retentionChoice != null)
                                          PrivacyBadge(
                                            label: _retentionName(session.retentionChoice),
                                            kind: 'machine',
                                          ),
                                      ],
                                    ),
                                    if (session.incomplete || session.outcome == 'interrupted') ...[
                                      const SizedBox(height: PrivacySpace.xs),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: PrivacyButton.secondary(
                                          key: Key('privacy_reprocess_${session.localId}'),
                                          label: 'Reprocess',
                                          onPressed: () => _openSession(store, session),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              Icon(Icons.chevron_right, color: PrivacyScope.of(context).palette.textSecondary),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _openSession(PrivacyStore store, PrivacySessionRecord session) async {
    final receipt = await _routeToPrivacyPage(
      context,
      _SessionDetail(
          store: store, session: session, onChanged: widget.onChanged, intelligenceClient: widget.intelligenceClient),
    );
    if (!mounted) return;
    if (receipt is String) setState(() => _receipt = receipt);
    await widget.onChanged();
  }

  static String _retentionName(String? name) {
    final choice = privacyRetentionFromName(name);
    if (choice == null) return PrivacyCopy.retention;
    return _PrivacyShellState._retentionLabel(choice);
  }

  static String _sessionTitle(PrivacySessionRecord session) {
    if (session.incomplete || session.outcome == 'interrupted') return PrivacyCopy.interrupted;
    if (session.outcome == 'completed') return PrivacyCopy.completed;
    return PrivacyCopy.recordingOff;
  }
}

class _SessionDetailBundle {
  const _SessionDetailBundle({
    this.chunks = const <PrivacyChunkRecord>[],
    this.notes = const <PrivacyNoteRecord>[],
    this.candidates = const <PrivacyCandidateRecord>[],
  });

  final List<PrivacyChunkRecord> chunks;
  final List<PrivacyNoteRecord> notes;
  final List<PrivacyCandidateRecord> candidates;
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PrivacySpace.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 112, child: Text(label, style: theme.meta())),
          const SizedBox(width: PrivacySpace.sm),
          Expanded(child: Text(value, style: theme.body())),
        ],
      ),
    );
  }
}

class _DisclosureCard extends StatelessWidget {
  const _DisclosureCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
    this.initiallyExpanded = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return PrivacyCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: PrivacySpace.md, vertical: PrivacySpace.xxs),
        childrenPadding: const EdgeInsets.fromLTRB(
          PrivacySpace.md,
          0,
          PrivacySpace.md,
          PrivacySpace.md,
        ),
        leading: Icon(icon, color: theme.palette.textSecondary),
        title: Text(title, style: theme.body().copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: theme.meta()),
        iconColor: theme.palette.accent,
        collapsedIconColor: theme.palette.textSecondary,
        shape: const Border(),
        collapsedShape: const Border(),
        children: [child],
      ),
    );
  }
}

class _SessionDetail extends StatefulWidget {
  const _SessionDetail({required this.store, required this.session, required this.onChanged, this.intelligenceClient});

  final PrivacyIntelligenceClient? intelligenceClient;

  final PrivacyStore store;
  final PrivacySessionRecord session;
  final Future<void> Function() onChanged;

  @override
  State<_SessionDetail> createState() => _SessionDetailState();
}

class _SessionDetailState extends State<_SessionDetail> {
  final _note = TextEditingController();
  late Future<_SessionDetailBundle> _detailFuture;
  var _deleted = false;
  var _findingSuggestions = false;
  var _reprocessingInterrupted = false;
  String? _suggestionMessage;
  var _suggestionFailed = false;

  @override
  void initState() {
    super.initState();
    _detailFuture = _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    if (_deleted) {
      return Scaffold(
        backgroundColor: theme.palette.background,
        appBar: AppBar(
          backgroundColor: theme.palette.background,
          leading: const OmiBackButton(),
          title: const Text(PrivacyCopy.sessions),
        ),
        body: const OmiEmptyState(
          icon: Icons.delete_outline,
          title: PrivacyCopy.deletedSuccess,
          message: PrivacyCopy.deletedPhone,
        ),
      );
    }
    return Scaffold(
      backgroundColor: theme.palette.background,
      appBar: AppBar(
        backgroundColor: theme.palette.background,
        leading: const OmiBackButton(),
        title: const Text('Session details'),
      ),
      body: FutureBuilder<_SessionDetailBundle>(
        future: _detailFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const OmiLoadingState(label: PrivacyCopy.loadingSessions);
          }
          if (snapshot.hasError) {
            return OmiErrorState(
              message: PrivacyCopy.loadFailed,
              onRetry: () async => setState(() => _detailFuture = _load()),
            );
          }
          final bundle = snapshot.data ?? const _SessionDetailBundle();
          final session = widget.session;
          final status = _SessionsTabState._sessionTitle(session);
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              PrivacySpace.md,
              PrivacySpace.xs,
              PrivacySpace.md,
              PrivacySpace.xxl,
            ),
            children: [
              PrivacyCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(PrivacyCopy.sessionSummary, style: theme.section())),
                        PrivacyBadge(
                          label: status,
                          kind: session.incomplete ? 'interrupted' : 'recording',
                        ),
                      ],
                    ),
                    const SizedBox(height: PrivacySpace.sm),
                    _SummaryRow(label: PrivacyCopy.purposeLabel, value: _sessionPurpose(session)),
                    _SummaryRow(label: PrivacyCopy.retention, value: _sessionRetention(session)),
                    _SummaryRow(label: PrivacyCopy.consent, value: _consentLabel(session.consentBasis)),
                    _SummaryRow(label: PrivacyCopy.captureOrigin, value: _originLabel(session.captureOrigin)),
                    const SizedBox(height: PrivacySpace.xs),
                    Text(PrivacyCopy.ownerAssertion, style: theme.meta()),
                  ],
                ),
              ),
              if (session.retentionChoice == PrivacyRetentionChoice.sessionOnly.name)
                const Padding(
                  padding: EdgeInsets.only(bottom: PrivacySpace.sm),
                  child: _PrivacyNotice(
                    icon: Icons.timer_outlined,
                    title: PrivacyCopy.sessionOnly,
                    message: PrivacyCopy.sessionOnlyHint,
                    kind: 'interrupted',
                  ),
                ),
              _DisclosureCard(
                key: const Key('privacy_session_transcript'),
                title: PrivacyCopy.transcription,
                subtitle: '${bundle.chunks.length} transcript chunks',
                icon: Icons.subject_outlined,
                initiallyExpanded: true,
                child: bundle.chunks.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.only(bottom: PrivacySpace.md),
                        child: Text(PrivacyCopy.noSpeech),
                      )
                    : Column(
                        children: [
                          for (final chunk in bundle.chunks)
                            _ChunkEditor(
                              chunk: chunk,
                              onCorrect: (text) => _correct(chunk, text),
                              onCreateTask: () => _taskFrom(chunk),
                            ),
                        ],
                      ),
              ),
              _DisclosureCard(
                key: const Key('privacy_session_notes'),
                title: PrivacyCopy.personalNotes,
                subtitle: bundle.notes.isEmpty ? 'Add a private note' : '${bundle.notes.length} saved',
                icon: Icons.edit_note_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final note in bundle.notes) ...[
                      Text(note.text, style: theme.body()),
                      const SizedBox(height: PrivacySpace.sm),
                    ],
                    PrivacyField(
                      key: const Key('privacy_owner_note'),
                      controller: _note,
                      label: PrivacyCopy.noteHint,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                    ),
                    const SizedBox(height: PrivacySpace.sm),
                    PrivacyButton.secondary(label: PrivacyCopy.saveNote, onPressed: _saveNote),
                  ],
                ),
              ),
              _DisclosureCard(
                key: const Key('privacy_session_task_actions'),
                title: PrivacyCopy.taskActions,
                subtitle: bundle.candidates.isEmpty
                    ? 'Suggestions stay separate until you accept them'
                    : '${bundle.candidates.length} suggestion${bundle.candidates.length == 1 ? '' : 's'} to review',
                icon: Icons.playlist_add_check_circle_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: PrivacySpace.sm),
                      child: PrivacyButton.secondary(
                        key: const Key('privacy_find_suggestions'),
                        label: _findingSuggestions ? PrivacyCopy.findingSuggestions : PrivacyCopy.findSuggestions,
                        expand: true,
                        onPressed: _findingSuggestions ? null : _findSuggestions,
                      ),
                    ),
                    if (session.incomplete || session.outcome == 'interrupted')
                      Padding(
                        padding: const EdgeInsets.only(bottom: PrivacySpace.sm),
                        child: PrivacyButton.secondary(
                          key: const Key('privacy_reprocess_session'),
                          label: _reprocessingInterrupted ? 'Reprocessing…' : 'Reprocess interrupted session',
                          expand: true,
                          onPressed: _reprocessingInterrupted ? null : _reprocessInterruptedSession,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: PrivacySpace.sm),
                      child: PrivacyIntelligenceExtractionButton(
                        store: widget.store,
                        session: widget.session,
                        chunks: bundle.chunks,
                        notes: bundle.notes,
                        now: DateTime.now(),
                        onChanged: _refreshDetail,
                      ),
                    ),
                    if (_suggestionMessage != null)
                      Padding(
                        key: const Key('privacy_suggestion_feedback'),
                        padding: const EdgeInsets.only(bottom: PrivacySpace.sm),
                        child: _PrivacyNotice(
                          icon: _suggestionFailed ? Icons.error_outline : Icons.lightbulb_outline,
                          title: _suggestionFailed ? PrivacyCopy.intelligence : PrivacyCopy.suggestionsReady,
                          message: _suggestionMessage!,
                          kind: _suggestionFailed ? 'interrupted' : 'accent',
                        ),
                      ),
                    for (final candidate in bundle.candidates)
                      _CandidateTile(
                        key: ValueKey('session_suggestion_${candidate.candidateId}'),
                        store: widget.store,
                        candidate: candidate,
                        onChanged: _refreshDetail,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: PrivacySpace.md),
              PrivacySettingsGroup(
                label: PrivacyCopy.deletion,
                footer: '${PrivacyCopy.deletedPhone} ${PrivacyCopy.remoteUnavailable}',
                children: [
                  PrivacySettingsRow(
                    icon: Icons.delete_outline,
                    title: PrivacyCopy.deleteSession,
                    subtitle: 'Review local transcript, suggestion, and linked-task scope first.',
                    destructive: true,
                    onTap: _delete,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Future<_SessionDetailBundle> _load() async {
    final candidates = await widget.store.pendingCandidates();
    return _SessionDetailBundle(
      chunks: await widget.store.chunks(widget.session.localId),
      notes: await widget.store.notes(widget.session.localId),
      candidates: candidates.where((candidate) => candidate.sessionId == widget.session.localId).toList(),
    );
  }

  Future<void> _findSuggestions() async {
    if (_findingSuggestions) return;
    setState(() {
      _findingSuggestions = true;
      _suggestionMessage = null;
      _suggestionFailed = false;
    });
    try {
      final added = await widget.store.refreshSuggestions(
        service: const ActionSuggestionService(),
        sessionId: widget.session.localId,
      );
      await widget.onChanged();
      final bundle = await _load();
      if (!mounted) return;
      setState(() {
        _detailFuture = SynchronousFuture(bundle);
        _findingSuggestions = false;
        _suggestionMessage = added == 0
            ? PrivacyCopy.noNewSuggestions
            : '$added suggestion${added == 1 ? '' : 's'} found. Review ${added == 1 ? 'it' : 'them'} below.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _findingSuggestions = false;
        _suggestionFailed = true;
        _suggestionMessage = PrivacyCopy.suggestionsFailed;
      });
    }
  }

  Future<void> _reprocessInterruptedSession() async {
    if (_reprocessingInterrupted) return;
    setState(() {
      _reprocessingInterrupted = true;
      _suggestionMessage = null;
      _suggestionFailed = false;
    });
    try {
      final client =
          widget.intelligenceClient ?? PrivacyIntelligenceClient(credentials: PrivacyIntelligenceCredentialStore());
      final int added;
      try {
        var timezone = 'UTC';
        try {
          timezone = (await FlutterTimezone.getLocalTimezone()).identifier;
        } catch (_) {
          // Match the assistant's UTC policy when the platform cannot name its zone.
        }
        added = await PrivacyIntelligenceCoordinator(client: client, store: widget.store).reprocessSession(
          sessionId: widget.session.localId,
          timezone: timezone,
          now: DateTime.now(),
        );
      } finally {
        if (widget.intelligenceClient == null) client.close();
      }
      await widget.onChanged();
      final bundle = await _load();
      if (!mounted) return;
      setState(() {
        _detailFuture = SynchronousFuture(bundle);
        _reprocessingInterrupted = false;
        _suggestionMessage = added == 0
            ? PrivacyCopy.noNewSuggestions
            : '$added suggestion${added == 1 ? '' : 's'} found. Review ${added == 1 ? 'it' : 'them'} below.';
      });
    } on PrivacyIntelligenceClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _reprocessingInterrupted = false;
        _suggestionFailed = true;
        _suggestionMessage = error.kind == PrivacyIntelligenceFailureKind.notConfigured
            ? PrivacyCopy.intelligenceNotConfigured
            : PrivacyCopy.intelligenceUnavailable;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _reprocessingInterrupted = false;
        _suggestionFailed = true;
        _suggestionMessage = PrivacyCopy.suggestionsFailed;
      });
    }
  }

  Future<void> _refreshDetail() async {
    await widget.onChanged();
    final bundle = await _load();
    if (mounted) setState(() => _detailFuture = SynchronousFuture(bundle));
  }

  static String _sessionPurpose(PrivacySessionRecord session) {
    final configured = quickSelfCapturePurposeFromName(session.configuredPurpose);
    if (configured != null) return _PrivacyShellState._quickPurposeLabel(configured);
    final owner = session.ownerPurpose.trim();
    return owner.isEmpty ? PrivacyCopy.none : owner;
  }

  static String _sessionRetention(PrivacySessionRecord session) {
    final choice = privacyRetentionFromName(session.retentionChoice);
    return choice == null ? PrivacyCopy.none : _PrivacyShellState._retentionLabel(choice);
  }

  static String _consentLabel(String basis) {
    switch (basis) {
      case PrivacyCaptureConfig.quickGestureConsentBasis:
        return 'Self-only assertion by pendant double-tap';
      case 'participants_consented':
        return 'Everyone present consented';
      default:
        return 'Self-only owner assertion';
    }
  }

  static String _originLabel(String origin) {
    return origin == PrivacyCaptureConfig.pendantQuickCaptureOrigin
        ? PrivacyCopy.quickRecordingOrigin
        : 'Started from the phone';
  }

  Future<void> _taskFrom(PrivacyChunkRecord chunk) async {
    final title = TextEditingController(text: chunk.displayText);
    final saved = await showOmiSheet<bool>(
      context: context,
      title: PrivacyCopy.createFromChunk,
      builder: (sheetContext) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(PrivacyCopy.chunkExplain),
          TextField(
            key: const Key('privacy_chunk_task_title'),
            controller: title,
            decoration: const InputDecoration(labelText: PrivacyCopy.taskHint),
          ),
          PrivacyButton(
            label: PrivacyCopy.saveTask,
            onPressed: () async {
              Navigator.of(sheetContext).pop(true);
            },
          ),
        ],
      ),
    );
    final next = title.text.trim();
    title.dispose();
    if (saved != true || next.isEmpty || !mounted) return;
    final result = await widget.store.createTask(
      title: next,
      creationOrigin: 'manual',
      sourceSessionId: widget.session.localId,
      sourceKind: 'transcript_chunk',
      excerpt: boundPrivacyExcerpt(chunk.displayText),
    );
    if (!mounted || !result.ok) return;
    await widget.onChanged();
  }

  Future<void> _correct(PrivacyChunkRecord chunk, String correction) async {
    final result = await widget.store.correctChunk(
      captureId: chunk.captureId,
      sequence: chunk.sequence,
      correction: correction,
    );
    if (!mounted || !result.ok) return;
    await _refreshDetail();
  }

  Future<void> _saveNote() async {
    final result = await widget.store.addNote(sessionId: widget.session.localId, text: _note.text);
    if (!mounted || !result.ok) return;
    _note.clear();
    await _refreshDetail();
  }

  Future<void> _delete() async {
    final preview = await widget.store.previewSession(widget.session.localId);
    if (!mounted) return;
    final confirmed = await showOmiConfirm(
      context,
      title: PrivacyCopy.deleteSession,
      message:
          '${preview.chunkCount} ${PrivacyCopy.machine}. ${preview.pendingCandidateCount} ${PrivacyCopy.suggestions}.',
      confirmLabel: PrivacyCopy.confirmDelete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    var deleteTasks = false;
    if (preview.acceptedTaskCount > 0) {
      deleteTasks = await showOmiConfirm(
        context,
        title: PrivacyCopy.linkedTasksTitle,
        message: PrivacyCopy.linkedTasksMessage,
        confirmLabel: PrivacyCopy.deleteTasks,
        cancelLabel: PrivacyCopy.keepCommitments,
        destructive: true,
      );
      if (!mounted) return;
    }
    final result = await widget.store.deleteSession(widget.session.localId, deleteAcceptedTasks: deleteTasks);
    if (!mounted || !result.ok) return;
    setState(() => _deleted = true);
    await widget.onChanged();
    if (!mounted) return;
    Navigator.of(context).pop('${PrivacyCopy.deletedPhone} ${PrivacyCopy.remoteUnavailable}');
  }
}

class _ChunkEditor extends StatefulWidget {
  const _ChunkEditor({required this.chunk, required this.onCorrect, required this.onCreateTask});

  final PrivacyChunkRecord chunk;
  final Future<void> Function(String correction) onCorrect;
  final Future<void> Function() onCreateTask;

  @override
  State<_ChunkEditor> createState() => _ChunkEditorState();
}

class _ChunkEditorState extends State<_ChunkEditor> {
  late final TextEditingController _correction = TextEditingController(text: widget.chunk.correction ?? '');

  @override
  void dispose() {
    _correction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return PrivacyCard(
      semanticLabel: 'Transcript chunk ${widget.chunk.sequence}. Show correction and task actions.',
      onTap: _openDetails,
      tint: theme.palette.surfaceSecondary,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.chunk.displayText,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: theme.body(),
                ),
                const SizedBox(height: PrivacySpace.xs),
                Text(
                  widget.chunk.correction == null ? PrivacyCopy.machine : 'Owner correction applied',
                  style: theme.meta(),
                ),
              ],
            ),
          ),
          const SizedBox(width: PrivacySpace.xs),
          Icon(Icons.chevron_right, color: theme.palette.textSecondary),
        ],
      ),
    );
  }

  Future<void> _openDetails() async {
    await showOmiSheet<void>(
      context: context,
      title: PrivacyCopy.transcription,
      builder: (sheetContext) => SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Padding(
          padding: const EdgeInsets.only(bottom: PrivacySpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.chunk.machineText, style: PrivacyScope.of(sheetContext).body()),
              const SizedBox(height: PrivacySpace.xs),
              const PrivacyBadge(label: PrivacyCopy.machine, kind: 'machine'),
              const SizedBox(height: PrivacySpace.md),
              PrivacyField(
                key: Key('privacy_correction_${widget.chunk.sequence}'),
                controller: _correction,
                label: PrivacyCopy.correctionHint,
                helperText: 'The original machine text remains preserved.',
                maxLines: 5,
              ),
              const SizedBox(height: PrivacySpace.sm),
              Wrap(
                spacing: PrivacySpace.xs,
                runSpacing: PrivacySpace.xs,
                children: [
                  PrivacyButton(
                    label: PrivacyCopy.saveCorrection,
                    onPressed: () => widget.onCorrect(_correction.text),
                  ),
                  PrivacyButton.secondary(
                    label: PrivacyCopy.copyText,
                    onPressed: () => OmiClipboard.copy(
                      sheetContext,
                      widget.chunk.displayText,
                      what: PrivacyCopy.machine,
                    ),
                  ),
                  PrivacyButton.secondary(
                    label: PrivacyCopy.createFromChunk,
                    onPressed: widget.onCreateTask,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _TaskCategory { today, inbox, projects, habits, suggestions, completed }

class _TasksTab extends StatefulWidget {
  const _TasksTab({
    required this.store,
    required this.now,
    required this.onChanged,
    required this.onOpenSwitcher,
    required this.intelligenceClient,
    this.quickMessage,
  });

  final PrivacyStore? store;
  final DateTime now;
  final Future<void> Function() onChanged;
  final VoidCallback onOpenSwitcher;
  final PrivacyIntelligenceClient? intelligenceClient;
  final String? quickMessage;

  @override
  State<_TasksTab> createState() => _TasksTabState();
}

class _TasksTabState extends State<_TasksTab> {
  var _category = _TaskCategory.today;
  var _showArchivedProjects = false;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return Column(
      children: [
        PrivacyPageHeader(
          title: PrivacyCopy.tasks,
          subtitle: _categorySubtitle,
          onOpenSwitcher: widget.onOpenSwitcher,
          trailing: OmiIconButton.filled(
            key: const Key('privacy_new_task'),
            icon: const Icon(Icons.add_rounded),
            label: PrivacyCopy.newTask,
            onPressed: store == null ? null : () => _openNewTask(store),
            color: PrivacyScope.of(context).palette.text,
            fillColor: PrivacyScope.of(context).palette.surface,
          ),
        ),
        if (widget.quickMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(PrivacySpace.md, 0, PrivacySpace.md, PrivacySpace.xs),
            child: _PrivacyNotice(
              icon: Icons.info_outline,
              title: PrivacyCopy.quickSelfCapture,
              message: widget.quickMessage!,
              kind: 'interrupted',
            ),
          ),
        Expanded(
          child: store == null
              ? const OmiErrorState(message: PrivacyCopy.storeUnavailable)
              : FutureBuilder<_TaskBundle>(
                  future: _load(store),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const OmiLoadingState(label: PrivacyCopy.loadingTasks);
                    }
                    if (snapshot.hasError || snapshot.data == null) {
                      return OmiErrorState(message: PrivacyCopy.loadFailed, onRetry: _changed);
                    }
                    final bundle = snapshot.data!;
                    return Column(
                      children: [
                        _categoryPicker(bundle),
                        Expanded(child: _categoryBody(store, bundle)),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  String get _categorySubtitle {
    switch (_category) {
      case _TaskCategory.today:
        return 'What needs attention now';
      case _TaskCategory.inbox:
        return 'Unscheduled tasks without a project';
      case _TaskCategory.projects:
        return 'Related work, kept together';
      case _TaskCategory.habits:
        return 'Small routines, tracked only on this phone';
      case _TaskCategory.suggestions:
        return 'Nothing becomes a task until you accept it';
      case _TaskCategory.completed:
        return 'Finished tasks you can reopen';
    }
  }

  Widget _categoryPicker(_TaskBundle bundle) {
    final today = _today(bundle).length;
    final inbox = _inbox(bundle).length;
    final projects = bundle.projects.where((project) => !project.archived).length;
    final habits = bundle.habits.where((habit) => !habit.archived).length;
    final suggestions = bundle.candidates.length;
    final completed = bundle.tasks.where((task) => !task.isOpen).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(PrivacySpace.md, 0, PrivacySpace.md, PrivacySpace.xs),
      child: Wrap(
        spacing: PrivacySpace.xs,
        runSpacing: PrivacySpace.xxs,
        children: [
          _categoryChip(_TaskCategory.today, PrivacyCopy.today, today),
          _categoryChip(_TaskCategory.inbox, PrivacyCopy.inbox, inbox),
          _categoryChip(_TaskCategory.projects, PrivacyCopy.projects, projects),
          _categoryChip(_TaskCategory.habits, PrivacyCopy.habits, habits),
          _categoryChip(_TaskCategory.suggestions, PrivacyCopy.suggestions, suggestions),
          _categoryChip(_TaskCategory.completed, PrivacyCopy.completedFilter, completed),
        ],
      ),
    );
  }

  Widget _categoryChip(_TaskCategory category, String label, int count) {
    return OmiFilterChip(
      key: Key('privacy_task_category_${category.name}'),
      label: label,
      count: count,
      semanticsLabel: '$label, $count items',
      selected: _category == category,
      onSelected: () => setState(() => _category = category),
    );
  }

  Widget _categoryBody(PrivacyStore store, _TaskBundle bundle) {
    switch (_category) {
      case _TaskCategory.today:
        return _taskList(
          store,
          bundle,
          _today(bundle),
          emptyTitle: PrivacyCopy.noTasksToday,
          emptyMessage: 'Tasks due today and overdue tasks will appear here.',
          emptyIcon: Icons.today_outlined,
        );
      case _TaskCategory.inbox:
        return _taskList(
          store,
          bundle,
          _inbox(bundle),
          emptyTitle: PrivacyCopy.noInboxTasks,
          emptyMessage: 'New unscheduled tasks will wait here.',
          emptyIcon: Icons.inbox_outlined,
        );
      case _TaskCategory.completed:
        return _taskList(
          store,
          bundle,
          bundle.tasks.where((task) => !task.isOpen).toList(),
          emptyTitle: PrivacyCopy.noCompletedTasks,
          emptyMessage: 'Completed tasks remain available to reopen.',
          emptyIcon: Icons.check_circle_outline,
        );
      case _TaskCategory.suggestions:
        if (bundle.candidates.isEmpty) {
          return const OmiEmptyState(
            icon: Icons.lightbulb_outline,
            title: PrivacyCopy.noSuggestions,
            message: 'Potential commitments from sessions will wait here for your review.',
          );
        }
        return ListView(
          key: const PageStorageKey('privacy_suggestions_scroll'),
          padding: const EdgeInsets.fromLTRB(
            PrivacySpace.md,
            PrivacySpace.xs,
            PrivacySpace.md,
            PrivacySpace.xxl,
          ),
          children: [
            for (final candidate in bundle.candidates)
              _CandidateTile(
                store: store,
                candidate: candidate,
                onChanged: _changed,
                intelligenceClient: widget.intelligenceClient,
              ),
          ],
        );
      case _TaskCategory.habits:
        return _HabitsWorkspace(
          store: store,
          bundle: bundle,
          now: widget.now,
          onChanged: _changed,
        );
      case _TaskCategory.projects:
        return _ProjectsWorkspace(
          store: store,
          bundle: bundle,
          now: widget.now,
          showArchived: _showArchivedProjects,
          onShowArchived: (value) => setState(() => _showArchivedProjects = value),
          onChanged: _changed,
        );
    }
  }

  List<PrivacyTaskRecord> _today(_TaskBundle bundle) => bundle.tasks
      .where((task) =>
          task.isOpen &&
          (privacyTaskSelectedToday(task, widget.now) ||
              privacyTaskDueToday(task.dueAt, widget.now) ||
              privacyTaskOverdue(task.dueAt, widget.now)))
      .toList()
    ..sort((a, b) => (a.todayRank ?? 1 << 30).compareTo(b.todayRank ?? 1 << 30));

  List<PrivacyTaskRecord> _inbox(_TaskBundle bundle) => bundle.tasks
      .where((task) =>
          task.isOpen &&
          task.projectId == null &&
          !privacyTaskDueToday(task.dueAt, widget.now) &&
          !privacyTaskOverdue(task.dueAt, widget.now))
      .toList();

  Widget _taskList(
    PrivacyStore store,
    _TaskBundle bundle,
    List<PrivacyTaskRecord> tasks, {
    required String emptyTitle,
    required String emptyMessage,
    required IconData emptyIcon,
  }) {
    if (tasks.isEmpty) {
      return OmiEmptyState(icon: emptyIcon, title: emptyTitle, message: emptyMessage);
    }
    final projects = {for (final project in bundle.projects) project.projectId: project};
    return ListView(
      key: PageStorageKey('privacy_tasks_${_category.name}_scroll'),
      padding: const EdgeInsets.fromLTRB(
        PrivacySpace.md,
        PrivacySpace.xs,
        PrivacySpace.md,
        PrivacySpace.xxl,
      ),
      children: [
        for (final task in tasks)
          _TaskTile(
            key: ValueKey(task.taskId),
            store: store,
            task: task,
            now: widget.now,
            projectName: projects[task.projectId]?.name,
            onChanged: _changed,
          ),
      ],
    );
  }

  Future<void> _openNewTask(PrivacyStore store) async {
    final title = TextEditingController();
    final note = TextEditingController();
    final saved = await showOmiSheet<bool>(
      context: context,
      title: PrivacyCopy.newTask,
      builder: (sheetContext) => SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Padding(
          padding: const EdgeInsets.only(bottom: PrivacySpace.md),
          child: Column(
            children: [
              PrivacyField(
                key: const Key('privacy_task_title'),
                controller: title,
                label: PrivacyCopy.taskHint,
                autofocus: true,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: PrivacySpace.sm),
              PrivacyField(
                controller: note,
                label: PrivacyCopy.taskNote,
                maxLines: 4,
              ),
              const SizedBox(height: PrivacySpace.md),
              PrivacyButton(
                key: const Key('privacy_save_task'),
                label: PrivacyCopy.saveTask,
                expand: true,
                onPressed: () async => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    final nextTitle = title.text.trim();
    final nextNote = note.text.trim();
    title.dispose();
    note.dispose();
    if (saved != true || nextTitle.isEmpty) return;
    final result = await store.createTask(title: nextTitle, note: nextNote.isEmpty ? null : nextNote);
    if (result.ok) await _changed();
  }

  Future<void> _changed() async {
    await widget.onChanged();
    if (mounted) setState(() {});
  }

  static Future<_TaskBundle> _load(PrivacyStore store) async {
    return _TaskBundle(
      tasks: await store.tasks(),
      candidates: await store.pendingCandidates(),
      projects: await store.projects(),
      habits: await store.habits(),
      habitCompletions: await store.habitCompletions(),
    );
  }
}

class _TaskBundle {
  const _TaskBundle({
    required this.tasks,
    required this.candidates,
    required this.projects,
    required this.habits,
    required this.habitCompletions,
  });
  final List<PrivacyTaskRecord> tasks;
  final List<PrivacyCandidateRecord> candidates;
  final List<PrivacyProjectRecord> projects;
  final List<PrivacyHabitRecord> habits;
  final List<PrivacyHabitCompletionRecord> habitCompletions;
}

class _CandidateTile extends StatefulWidget {
  const _CandidateTile({
    super.key,
    required this.store,
    required this.candidate,
    required this.onChanged,
    this.intelligenceClient,
  });

  final PrivacyStore store;
  final PrivacyCandidateRecord candidate;
  final Future<void> Function() onChanged;
  final PrivacyIntelligenceClient? intelligenceClient;

  @override
  State<_CandidateTile> createState() => _CandidateTileState();
}

class _CandidateTileState extends State<_CandidateTile> {
  late final TextEditingController _edit = TextEditingController(text: widget.candidate.proposedText);
  PrivacyIntelligenceClient? _ownedClient;
  bool _busy = false;
  String? _status;
  String? _reconcileOperationId;

  PrivacyIntelligenceClient get _client =>
      widget.intelligenceClient ??
      (_ownedClient ??= PrivacyIntelligenceClient(credentials: PrivacyIntelligenceCredentialStore()));

  PrivacyIntelligenceCoordinator get _coordinator =>
      PrivacyIntelligenceCoordinator(client: _client, store: widget.store);

  @override
  void dispose() {
    _edit.dispose();
    _ownedClient?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    final taskSuggestion = {'task', 'commitment', 'intention'}.contains(widget.candidate.suggestedType);
    return PrivacyCard(
      key: Key('privacy_suggestion_${widget.candidate.candidateId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_outline, size: 20, color: theme.palette.suggestion),
              const SizedBox(width: PrivacySpace.xs),
              Expanded(
                child: Text(
                  switch (widget.candidate.suggestedType) {
                    'calendar_event' => PrivacyCopy.calendarSuggestion,
                    'habit' => PrivacyCopy.habitSuggestion,
                    'project' => PrivacyCopy.projectSuggestion,
                    _ => PrivacyCopy.suggestionNotTask,
                  },
                  style: theme.meta().copyWith(color: theme.palette.suggestion, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: PrivacySpace.sm),
          Text(widget.candidate.proposedText, style: theme.body().copyWith(fontWeight: FontWeight.w600)),
          if (widget.candidate.description?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: PrivacySpace.xs),
            Text(
              widget.candidate.description!,
              key: Key('privacy_suggestion_description_${widget.candidate.candidateId}'),
              style: theme.body(),
            ),
          ],
          const SizedBox(height: PrivacySpace.xs),
          Text(
            widget.candidate.excerpt,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.meta(),
          ),
          if (widget.candidate.proposedTimeText != null) ...[
            const SizedBox(height: PrivacySpace.xs),
            Text(widget.candidate.proposedTimeText!, style: theme.meta()),
          ],
          if (widget.candidate.uncertainty != null) ...[
            const SizedBox(height: PrivacySpace.xxs),
            Text(PrivacyCopy.uncertainty(widget.candidate.uncertainty!), style: theme.caption()),
          ],
          if (widget.candidate.suggestedType == 'calendar_event') ...[
            const SizedBox(height: PrivacySpace.sm),
            Text(PrivacyCopy.calendarSuggestionReview, style: theme.meta()),
          ],
          const SizedBox(height: PrivacySpace.md),
          Wrap(
            spacing: PrivacySpace.xs,
            runSpacing: PrivacySpace.xs,
            children: [
              if (taskSuggestion)
                PrivacyButton(
                  key: Key('privacy_accept_${widget.candidate.candidateId}'),
                  label: PrivacyCopy.accept,
                  onPressed: _busy
                      ? null
                      : () async {
                          final result = await widget.store.acceptCandidate(widget.candidate.candidateId);
                          if (result.ok) await widget.onChanged();
                        },
                ),
              if (taskSuggestion)
                PrivacyButton.secondary(
                  key: Key('privacy_edit_accept_action_${widget.candidate.candidateId}'),
                  label: PrivacyCopy.editAccept,
                  onPressed: _busy ? null : _editAndAccept,
                ),
              if (widget.candidate.suggestedType == 'habit')
                PrivacyButton(
                  key: Key('privacy_accept_habit_${widget.candidate.candidateId}'),
                  label: PrivacyCopy.acceptHabit,
                  onPressed: _busy
                      ? null
                      : () async {
                          final result = await widget.store.acceptCandidateAsHabit(widget.candidate.candidateId);
                          if (result.ok) await widget.onChanged();
                        },
                ),
              if (widget.candidate.suggestedType == 'project')
                PrivacyButton(
                  key: Key('privacy_accept_project_${widget.candidate.candidateId}'),
                  label: PrivacyCopy.acceptProject,
                  onPressed: _busy
                      ? null
                      : () async {
                          final result = await widget.store.acceptCandidateAsProject(widget.candidate.candidateId);
                          if (result.ok) await widget.onChanged();
                        },
                ),
              if (widget.candidate.suggestedType == 'calendar_event')
                PrivacyButton(
                  key: Key('privacy_review_calendar_${widget.candidate.candidateId}'),
                  label: PrivacyCopy.reviewCalendarSuggestion,
                  onPressed: _busy ? null : _reviewCalendar,
                ),
              if (_reconcileOperationId != null)
                PrivacyButton.secondary(
                  key: Key('privacy_reconcile_candidate_${widget.candidate.candidateId}'),
                  label: PrivacyCopy.reconcileCalendar,
                  onPressed: _busy ? null : _reconcileCalendar,
                ),
              PrivacyButton.quiet(
                key: Key('privacy_dismiss_${widget.candidate.candidateId}'),
                label: PrivacyCopy.dismiss,
                onPressed: _busy
                    ? null
                    : () async {
                        final result = await widget.store.dismissCandidate(widget.candidate.candidateId);
                        if (result.ok) await widget.onChanged();
                      },
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: PrivacySpace.sm),
            const OmiLoadingState(label: PrivacyCopy.working),
          ],
          if (_status != null) ...[
            const SizedBox(height: PrivacySpace.sm),
            Text(_status!, style: theme.meta()),
          ],
        ],
      ),
    );
  }

  Future<void> _editAndAccept() async {
    final accepted = await showOmiSheet<bool>(
      context: context,
      title: PrivacyCopy.editSuggestion,
      builder: (sheetContext) => SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Padding(
          padding: const EdgeInsets.only(bottom: PrivacySpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _PrivacyNotice(
                icon: Icons.lightbulb_outline,
                title: PrivacyCopy.suggestionNotTask,
                message: PrivacyCopy.notATask,
              ),
              const SizedBox(height: PrivacySpace.md),
              PrivacyField(
                key: Key('privacy_edit_accept_${widget.candidate.candidateId}'),
                controller: _edit,
                label: PrivacyCopy.taskHint,
                autofocus: true,
              ),
              const SizedBox(height: PrivacySpace.md),
              PrivacyButton(
                label: PrivacyCopy.editAccept,
                expand: true,
                onPressed: () async => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    if (accepted != true || _edit.text.trim().isEmpty) return;
    final result = await widget.store.acceptCandidate(
      widget.candidate.candidateId,
      editedTitle: _edit.text.trim(),
    );
    if (result.ok) await widget.onChanged();
  }

  Future<void> _reviewCalendar() async {
    final candidate = widget.candidate;
    if (candidate.proposedStartAt == null ||
        candidate.proposedEndAt == null ||
        (candidate.timezone?.trim().isEmpty ?? true)) {
      setState(() => _status = PrivacyCopy.incompleteCalendarSuggestion);
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final calendars = await _client.calendars();
      if (!mounted) return;
      final calendar = await _chooseCalendar(calendars);
      if (!mounted || calendar == null) return;
      final proposal = _coordinator.calendarProposalForCandidate(
        candidate: candidate,
        calendarId: calendar.id,
      );
      final preview = await _coordinator.prepare(proposal);
      if (!mounted) return;
      final approved = await showOmiConfirm(
        context,
        title: PrivacyCopy.reviewCalendarChange,
        message: _previewMessage(preview),
        confirmLabel: PrivacyCopy.confirmCalendarChange,
      );
      if (!approved || !mounted) return;
      try {
        final outcome = await _coordinator.confirmCalendarCandidate(
          candidateId: candidate.candidateId,
          approvedPreview: preview,
        );
        if (!mounted) return;
        if (outcome.status == PrivacyIntelligenceOperationStatus.succeeded) {
          await widget.onChanged();
          return;
        }
        setState(() {
          _status = outcome.message;
          _reconcileOperationId = outcome.requiresReconciliation ? outcome.operationId : null;
        });
      } on PrivacyIntelligenceClientException {
        if (!mounted) return;
        setState(() {
          _status = PrivacyCopy.calendarUncertain;
          _reconcileOperationId = preview.operationId;
        });
      }
    } on PrivacyIntelligenceClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = error.kind == PrivacyIntelligenceFailureKind.notConfigured
            ? PrivacyCopy.intelligenceNotConfigured
            : PrivacyCopy.intelligenceUnavailable;
      });
    } on ArgumentError {
      if (mounted) setState(() => _status = PrivacyCopy.incompleteCalendarSuggestion);
    } catch (_) {
      if (mounted) setState(() => _status = PrivacyCopy.intelligenceUnavailable);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<PrivacyIntelligenceCalendar?> _chooseCalendar(List<PrivacyIntelligenceCalendar> calendars) async {
    if (calendars.isEmpty) {
      setState(() => _status = PrivacyCopy.noCalendars);
      return null;
    }
    if (calendars.length == 1) return calendars.single;
    return showOmiSheet<PrivacyIntelligenceCalendar>(
      context: context,
      title: PrivacyCopy.chooseCalendar,
      builder: (sheetContext) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 400),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final calendar in calendars)
              PrivacyButton.secondary(
                label: calendar.name,
                onPressed: () async => Navigator.of(sheetContext).pop(calendar),
              ),
          ],
        ),
      ),
    );
  }

  String _previewMessage(PrivacyIntelligenceCalendarOperationPreview preview) {
    final when = OmiDateFormat.of(context).timeRange(preview.startAt.toLocal(), preview.endAt.toLocal());
    final scope = preview.recurrenceScope == PrivacyIntelligencePreviewRecurrenceScope.series
        ? PrivacyCopy.entireRecurringSeries
        : PrivacyCopy.oneNonRecurringEvent;
    return '${preview.calendarName}\n${preview.title}\n$when\n${preview.timezone}\n$scope\n${preview.changes.join(', ')}';
  }

  Future<void> _reconcileCalendar() async {
    final operationId = _reconcileOperationId;
    if (operationId == null) return;
    setState(() => _busy = true);
    try {
      final outcome = await _coordinator.reconcileCalendarCandidate(
        candidateId: widget.candidate.candidateId,
        operationId: operationId,
      );
      if (!mounted) return;
      if (outcome.status == PrivacyIntelligenceOperationStatus.succeeded) {
        await widget.onChanged();
        return;
      }
      setState(() {
        _status = outcome.message;
        _reconcileOperationId = outcome.requiresReconciliation ? operationId : null;
      });
    } catch (_) {
      if (mounted) setState(() => _status = PrivacyCopy.intelligenceUnavailable);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _TaskTile extends StatefulWidget {
  const _TaskTile({
    super.key,
    required this.store,
    required this.task,
    required this.now,
    required this.onChanged,
    this.projectName,
  });

  final PrivacyStore store;
  final PrivacyTaskRecord task;
  final DateTime now;
  final Future<void> Function() onChanged;
  final String? projectName;

  @override
  State<_TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends State<_TaskTile> {
  late final TextEditingController _title = TextEditingController(text: widget.task.title);
  late final TextEditingController _note = TextEditingController(text: widget.task.note ?? '');
  var _statusBusy = false;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final due = task.dueAt == null ? PrivacyCopy.none : OmiDateFormat.of(context).dateTime(task.dueAt!);
    final bucket = privacyTaskOverdue(task.dueAt, widget.now)
        ? PrivacyCopy.overdue
        : privacyTaskDueToday(task.dueAt, widget.now)
            ? PrivacyCopy.dueToday
            : PrivacyCopy.none;
    final theme = PrivacyScope.of(context);
    final dueLabel = bucket == PrivacyCopy.none ? (task.dueAt == null ? null : due) : '$bucket · $due';
    return PrivacyCard(
      key: Key('privacy_task_${task.taskId}'),
      semanticLabel: '${task.title}. Open task details.',
      onTap: _openDetails,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OmiIconButton(
            key: Key('privacy_task_complete_${task.taskId}'),
            icon: Icon(task.isOpen ? Icons.radio_button_unchecked : Icons.check_circle_rounded),
            label: task.isOpen ? 'Complete ${task.title}' : 'Reopen ${task.title}',
            color: task.isOpen ? theme.palette.textSecondary : theme.palette.success,
            onPressed: _statusBusy
                ? null
                : () async {
                    final targetId = task.taskId;
                    final completed = task.isOpen;
                    setState(() => _statusBusy = true);
                    try {
                      final result = await widget.store.setTaskStatus(
                        targetId,
                        completed: completed,
                        at: widget.now,
                      );
                      if (result.ok) {
                        OmiHaptics.success();
                        await widget.onChanged();
                      }
                    } finally {
                      if (mounted) setState(() => _statusBusy = false);
                    }
                  },
          ),
          const SizedBox(width: PrivacySpace.xs),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: PrivacySpace.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.body().copyWith(
                          fontWeight: FontWeight.w600,
                          decoration: task.isOpen ? null : TextDecoration.lineThrough,
                        ),
                  ),
                  if (dueLabel != null || widget.projectName != null) ...[
                    const SizedBox(height: PrivacySpace.xxs),
                    Text(
                      [if (dueLabel != null) dueLabel, if (widget.projectName != null) widget.projectName!].join(' · '),
                      style: theme.meta().copyWith(
                            color: bucket == PrivacyCopy.overdue ? theme.palette.warning : theme.palette.textSecondary,
                          ),
                    ),
                  ],
                  if (task.creationOrigin != 'manual' || task.sourceSessionId != null) ...[
                    const SizedBox(height: PrivacySpace.xs),
                    Text(_provenance(task), style: theme.caption()),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: PrivacySpace.sm),
            child: Icon(Icons.chevron_right, color: theme.palette.textSecondary),
          ),
        ],
      ),
    );
  }

  Future<void> _openDetails() async {
    final task = widget.task;
    await showOmiSheet<void>(
      context: context,
      title: PrivacyCopy.taskDetails,
      builder: (sheetContext) => SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Padding(
          padding: const EdgeInsets.only(bottom: PrivacySpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PrivacyField(
                key: Key('privacy_task_edit_${task.taskId}'),
                controller: _title,
                label: PrivacyCopy.editTask,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: PrivacySpace.sm),
              PrivacyField(
                controller: _note,
                label: PrivacyCopy.taskNote,
                maxLines: 4,
              ),
              const SizedBox(height: PrivacySpace.md),
              _SummaryRow(
                label: PrivacyCopy.due,
                value: task.dueAt == null ? PrivacyCopy.none : OmiDateFormat.of(context).dateTime(task.dueAt!),
              ),
              _SummaryRow(label: PrivacyCopy.projects, value: widget.projectName ?? PrivacyCopy.none),
              _SummaryRow(label: PrivacyCopy.provenance, value: _provenance(task)),
              const SizedBox(height: PrivacySpace.sm),
              Wrap(
                spacing: PrivacySpace.xs,
                runSpacing: PrivacySpace.xs,
                children: [
                  PrivacyButton.secondary(label: PrivacyCopy.chooseDue, onPressed: _pickDue),
                  if (task.dueAt != null)
                    PrivacyButton.quiet(
                      label: PrivacyCopy.clearDue,
                      onPressed: () async {
                        final result = await widget.store.updateTask(task.taskId, clearDue: true, at: widget.now);
                        if (result.ok) await widget.onChanged();
                      },
                    ),
                  PrivacyButton.secondary(label: PrivacyCopy.assignProject, onPressed: _assign),
                  if (task.projectId != null)
                    PrivacyButton.quiet(
                      label: PrivacyCopy.unassign,
                      onPressed: () async {
                        final result = await widget.store.updateTask(task.taskId, clearProject: true, at: widget.now);
                        if (result.ok) await widget.onChanged();
                      },
                    ),
                  if (task.isOpen)
                    PrivacyButton.quiet(
                      label: privacyTaskSelectedToday(task, widget.now)
                          ? PrivacyCopy.removeFromToday
                          : PrivacyCopy.addToToday,
                      onPressed: () async {
                        final result = await widget.store.setTaskToday(
                          task.taskId,
                          selected: !privacyTaskSelectedToday(task, widget.now),
                          at: widget.now,
                        );
                        if (result.ok) await widget.onChanged();
                      },
                    ),
                ],
              ),
              const SizedBox(height: PrivacySpace.md),
              PrivacyButton(
                label: PrivacyCopy.saveEdits,
                expand: true,
                onPressed: () async {
                  final result = await widget.store.updateTask(
                    task.taskId,
                    title: _title.text,
                    note: _note.text,
                    clearNote: _note.text.trim().isEmpty,
                    at: widget.now,
                  );
                  if (!result.ok) return;
                  await widget.onChanged();
                  if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                },
              ),
              const SizedBox(height: PrivacySpace.lg),
              Divider(color: PrivacyScope.of(sheetContext).palette.border),
              const SizedBox(height: PrivacySpace.sm),
              PrivacyButton.destructive(label: PrivacyCopy.delete, onPressed: () => _delete(sheetContext)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext sheetContext) async {
    final confirmed = await showOmiConfirm(
      sheetContext,
      title: PrivacyCopy.delete,
      confirmLabel: PrivacyCopy.confirmDelete,
      destructive: true,
    );
    if (!confirmed) return;
    final result = await widget.store.deleteTask(widget.task.taskId);
    if (!result.ok) return;
    await widget.onChanged();
    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
  }

  static String _provenance(PrivacyTaskRecord task) {
    if (task.creationOrigin == 'accepted_suggestion') return PrivacyCopy.createdFromSuggestion;
    if (task.sourceSessionId != null) return PrivacyCopy.createdFromSession;
    return PrivacyCopy.createdManually;
  }

  Future<void> _pickDue() async {
    final initial = widget.task.dueAt?.toLocal() ?? widget.now;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(initial.year - 1),
      lastDate: DateTime(initial.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null || !mounted) return;
    final due = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    final result = await widget.store.updateTask(widget.task.taskId, dueAt: due, at: widget.now);
    if (result.ok) await widget.onChanged();
  }

  Future<void> _assign() async {
    final projects = await widget.store.projects(includeArchived: false);
    if (!mounted || projects.isEmpty) return;
    final selected = await showOmiSheet<String>(
      context: context,
      title: PrivacyCopy.pickProject,
      builder: (sheetContext) => Column(
        children: [
          for (final project in projects)
            PrivacyButton.secondary(
              label: project.name,
              onPressed: () async {
                Navigator.of(sheetContext).pop(project.projectId);
              },
            ),
        ],
      ),
    );
    if (selected == null) return;
    final result = await widget.store.updateTask(widget.task.taskId, projectId: selected, at: widget.now);
    if (result.ok) await widget.onChanged();
  }
}

class _ProjectsWorkspace extends StatelessWidget {
  const _ProjectsWorkspace({
    required this.store,
    required this.bundle,
    required this.now,
    required this.showArchived,
    required this.onShowArchived,
    required this.onChanged,
  });

  final PrivacyStore store;
  final _TaskBundle bundle;
  final DateTime now;
  final bool showArchived;
  final ValueChanged<bool> onShowArchived;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final projects = bundle.projects.where((project) => project.archived == showArchived).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(PrivacySpace.md, 0, PrivacySpace.md, PrivacySpace.xs),
          child: Wrap(
            spacing: PrivacySpace.xs,
            runSpacing: PrivacySpace.xxs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OmiFilterChip(
                label: PrivacyCopy.activeProjects,
                count: bundle.projects.where((project) => !project.archived).length,
                selected: !showArchived,
                onSelected: () => onShowArchived(false),
              ),
              OmiFilterChip(
                key: const Key('privacy_projects_archived'),
                label: PrivacyCopy.archivedProjects,
                count: bundle.projects.where((project) => project.archived).length,
                selected: showArchived,
                onSelected: () => onShowArchived(true),
              ),
              if (!showArchived)
                OmiIconButton.filled(
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: PrivacyCopy.createProject,
                  onPressed: () => _createProject(context),
                  color: PrivacyScope.of(context).palette.text,
                  fillColor: PrivacyScope.of(context).palette.surface,
                ),
            ],
          ),
        ),
        Expanded(
          child: projects.isEmpty
              ? OmiEmptyState(
                  icon: showArchived ? Icons.archive_outlined : Icons.folder_outlined,
                  title: showArchived ? PrivacyCopy.noArchivedProjects : PrivacyCopy.noProjects,
                  message: showArchived
                      ? 'Projects you archive will remain available here.'
                      : 'Create a project to group related tasks.',
                  action: showArchived
                      ? null
                      : PrivacyButton.secondary(
                          label: PrivacyCopy.createProject,
                          onPressed: () => _createProject(context),
                        ),
                )
              : ListView(
                  key: PageStorageKey('privacy_projects_${showArchived ? 'archived' : 'active'}_scroll'),
                  padding: const EdgeInsets.fromLTRB(
                    PrivacySpace.md,
                    PrivacySpace.xs,
                    PrivacySpace.md,
                    PrivacySpace.xxl,
                  ),
                  children: [
                    for (final project in projects) _projectCard(context, project),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _projectCard(BuildContext context, PrivacyProjectRecord project) {
    final tasks = bundle.tasks.where((task) => task.projectId == project.projectId && task.isOpen).toList();
    final overdue = tasks.where((task) => privacyTaskOverdue(task.dueAt, now)).length;
    final theme = PrivacyScope.of(context);
    return PrivacyCard(
      key: Key('privacy_project_${project.projectId}'),
      semanticLabel: '${project.name}. ${tasks.length} open tasks. Open project.',
      onTap: () => _openProject(context, project),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: theme.palette.surfaceSecondary,
              borderRadius: BorderRadius.circular(PrivacyRadius.control),
            ),
            child: Icon(project.archived ? Icons.archive_outlined : Icons.folder_outlined, color: theme.palette.accent),
          ),
          const SizedBox(width: PrivacySpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(project.name, style: theme.body().copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: PrivacySpace.xxs),
                Text(
                  overdue > 0
                      ? '${tasks.length} ${PrivacyCopy.openTasks} · $overdue overdue'
                      : '${tasks.length} ${PrivacyCopy.openTasks}',
                  style:
                      theme.meta().copyWith(color: overdue > 0 ? theme.palette.warning : theme.palette.textSecondary),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: theme.palette.textSecondary),
        ],
      ),
    );
  }

  Future<void> _createProject(BuildContext context) async {
    final name = TextEditingController();
    final saved = await showOmiSheet<bool>(
      context: context,
      title: PrivacyCopy.createProject,
      builder: (sheetContext) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.only(bottom: PrivacySpace.md),
          child: Column(
            children: [
              PrivacyField(
                controller: name,
                label: PrivacyCopy.projectName,
                autofocus: true,
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: PrivacySpace.md),
              PrivacyButton(
                label: PrivacyCopy.createProject,
                expand: true,
                onPressed: () async => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    final value = name.text.trim();
    name.dispose();
    if (saved != true || value.isEmpty) return;
    final result = await store.createProject(value);
    if (result.ok) await onChanged();
  }

  Future<void> _openProject(BuildContext context, PrivacyProjectRecord project) async {
    await _routeToPrivacyPage(
      context,
      _ProjectDetail(store: store, project: project, now: now, onChanged: onChanged),
    );
    await onChanged();
  }
}

class _ProjectDetail extends StatefulWidget {
  const _ProjectDetail({required this.store, required this.project, required this.now, required this.onChanged});

  final PrivacyStore store;
  final PrivacyProjectRecord project;
  final DateTime now;
  final Future<void> Function() onChanged;

  @override
  State<_ProjectDetail> createState() => _ProjectDetailState();
}

class _ProjectDetailState extends State<_ProjectDetail> {
  late PrivacyProjectRecord _project = widget.project;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    return Scaffold(
      backgroundColor: theme.palette.background,
      appBar: AppBar(
        backgroundColor: theme.palette.background,
        leading: const OmiBackButton(),
        title: Text(_project.name),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Project actions',
            icon: const Icon(Icons.more_horiz),
            onSelected: (action) {
              if (action == 'rename') unawaited(_rename());
              if (action == 'archive') unawaited(_toggleArchive());
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'rename', child: Text(PrivacyCopy.rename)),
              PopupMenuItem(
                value: 'archive',
                child: Text(_project.archived ? PrivacyCopy.unarchive : PrivacyCopy.archive),
              ),
            ],
          ),
        ],
      ),
      body: FutureBuilder<List<PrivacyTaskRecord>>(
        future: widget.store.tasks(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const OmiLoadingState(label: PrivacyCopy.loadingTasks);
          }
          if (snapshot.hasError) return const OmiErrorState(message: PrivacyCopy.loadFailed);
          final tasks = (snapshot.data ?? const <PrivacyTaskRecord>[])
              .where((task) => task.projectId == _project.projectId && task.isOpen)
              .toList();
          if (tasks.isEmpty) {
            return const OmiEmptyState(
              icon: Icons.check_circle_outline,
              title: 'No Open Tasks',
              message: 'Tasks assigned to this project will appear here.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              PrivacySpace.md,
              PrivacySpace.sm,
              PrivacySpace.md,
              PrivacySpace.xxl,
            ),
            children: [
              for (final task in tasks)
                _TaskTile(
                  key: ValueKey(task.taskId),
                  store: widget.store,
                  task: task,
                  now: widget.now,
                  projectName: _project.name,
                  onChanged: _changed,
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _rename() async {
    final name = TextEditingController(text: _project.name);
    final saved = await showOmiSheet<bool>(
      context: context,
      title: PrivacyCopy.rename,
      builder: (sheetContext) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.only(bottom: PrivacySpace.md),
          child: Column(
            children: [
              PrivacyField(
                key: Key('privacy_project_rename_${_project.projectId}'),
                controller: name,
                label: PrivacyCopy.projectName,
                autofocus: true,
              ),
              const SizedBox(height: PrivacySpace.md),
              PrivacyButton(
                label: PrivacyCopy.rename,
                expand: true,
                onPressed: () async => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    final value = name.text.trim();
    name.dispose();
    if (saved != true || value.isEmpty) return;
    final result = await widget.store.renameProject(_project.projectId, value);
    if (!result.ok || !mounted) return;
    setState(() => _project = result.value!);
    await widget.onChanged();
  }

  Future<void> _toggleArchive() async {
    if (!_project.archived) {
      final confirmed = await showOmiConfirm(
        context,
        title: PrivacyCopy.archiveConfirm,
        confirmLabel: PrivacyCopy.archive,
      );
      if (!confirmed || !mounted) return;
    }
    final result = await widget.store.archiveProject(_project.projectId, archived: !_project.archived);
    if (!result.ok || !mounted) return;
    setState(() => _project = result.value!);
    await widget.onChanged();
  }

  Future<void> _changed() async {
    await widget.onChanged();
    if (mounted) setState(() {});
  }
}

class _HabitsWorkspace extends StatelessWidget {
  const _HabitsWorkspace({
    required this.store,
    required this.bundle,
    required this.now,
    required this.onChanged,
  });

  final PrivacyStore store;
  final _TaskBundle bundle;
  final DateTime now;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final habits = bundle.habits.where((habit) => !habit.archived).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(PrivacySpace.md, 0, PrivacySpace.md, PrivacySpace.xs),
          child: Align(
            alignment: Alignment.centerRight,
            child: OmiIconButton.filled(
              key: const Key('privacy_new_habit'),
              icon: const Icon(Icons.add_rounded),
              label: PrivacyCopy.createHabit,
              onPressed: () => _createHabit(context),
              color: PrivacyScope.of(context).palette.text,
              fillColor: PrivacyScope.of(context).palette.surface,
            ),
          ),
        ),
        Expanded(
          child: habits.isEmpty
              ? const OmiEmptyState(
                  icon: Icons.repeat_rounded,
                  title: PrivacyCopy.noHabits,
                  message: PrivacyCopy.noHabitsMessage,
                )
              : ListView(
                  key: const PageStorageKey('privacy_habits_scroll'),
                  padding: const EdgeInsets.fromLTRB(
                    PrivacySpace.md,
                    PrivacySpace.xs,
                    PrivacySpace.md,
                    PrivacySpace.xxl,
                  ),
                  children: [
                    for (final habit in habits)
                      _HabitCard(
                        store: store,
                        habit: habit,
                        completions: bundle.habitCompletions,
                        now: now,
                        onChanged: onChanged,
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _createHabit(BuildContext context) async {
    final title = TextEditingController();
    final saved = await showOmiSheet<bool>(
      context: context,
      title: PrivacyCopy.createHabit,
      builder: (sheetContext) => SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Padding(
          padding: const EdgeInsets.only(bottom: PrivacySpace.md),
          child: Column(
            children: [
              PrivacyField(
                key: const Key('privacy_habit_title'),
                controller: title,
                label: PrivacyCopy.habitName,
                autofocus: true,
              ),
              const SizedBox(height: PrivacySpace.md),
              PrivacyButton(
                label: PrivacyCopy.createHabit,
                expand: true,
                onPressed: () async => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    final nextTitle = title.text.trim();
    title.dispose();
    if (saved != true || nextTitle.isEmpty) return;
    final result = await store.createHabit(nextTitle, at: now);
    if (result.ok) await onChanged();
  }
}

class _HabitCard extends StatelessWidget {
  const _HabitCard({
    required this.store,
    required this.habit,
    required this.completions,
    required this.now,
    required this.onChanged,
  });

  final PrivacyStore store;
  final PrivacyHabitRecord habit;
  final List<PrivacyHabitCompletionRecord> completions;
  final DateTime now;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = PrivacyScope.of(context);
    final todayKey = privacyDateKey(now);
    final doneToday = completions.any((item) => item.habitId == habit.habitId && item.dateKey == todayKey);
    final recent = completions.where((item) => item.habitId == habit.habitId).take(7).length;
    return PrivacyCard(
      child: Row(
        children: [
          OmiIconButton(
            icon: Icon(doneToday ? Icons.check_circle_rounded : Icons.radio_button_unchecked),
            label: doneToday ? PrivacyCopy.notDoneToday : PrivacyCopy.doneToday,
            color: doneToday ? theme.palette.success : theme.palette.textSecondary,
            onPressed: () async {
              final result = await store.setHabitCompleted(habit.habitId, day: now, completed: !doneToday);
              if (result.ok) await onChanged();
            },
          ),
          const SizedBox(width: PrivacySpace.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(habit.title, style: theme.body().copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: PrivacySpace.xxs),
                Text(PrivacyCopy.recentCompletions(recent), style: theme.meta()),
              ],
            ),
          ),
          OmiIconButton(
            icon: const Icon(Icons.archive_outlined),
            label: PrivacyCopy.archive,
            color: theme.palette.textSecondary,
            onPressed: () async {
              final result = await store.updateHabit(habit.habitId, archived: true, at: now);
              if (result.ok) await onChanged();
            },
          ),
        ],
      ),
    );
  }
}

class _SettingsTab extends StatefulWidget {
  const _SettingsTab({
    required this.store,
    required this.retention,
    required this.onRetention,
    required this.themes,
    required this.onOpenSwitcher,
    required this.quick,
    required this.quickLoaded,
    required this.onOpenQuick,
    this.quickMessage,
    this.receipt,
  });

  final PrivacyStore? store;
  final PrivacyRetentionChoice? retention;
  final Future<void> Function(PrivacyRetentionChoice choice) onRetention;
  final PrivacyThemeController themes;
  final VoidCallback onOpenSwitcher;
  final QuickSelfCaptureSettings quick;
  final bool quickLoaded;
  final Future<void> Function() onOpenQuick;
  final String? quickMessage;
  final String? receipt;

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  var _hasToken = false;
  String? _probe;
  String? _receipt;

  @override
  void initState() {
    super.initState();
    _url.text = PrivacyCaptureConfig.stagingLiveUrl;
    unawaited(_load());
  }

  Future<void> _load() async {
    PrivacyCredentials? stored;
    try {
      stored = await SecurePrivacyCredentialStore().read();
    } catch (_) {
      stored = null;
    }
    if (!mounted) return;
    setState(() {
      final url = stored?.url.trim() ?? '';
      if (url.isNotEmpty) _url.text = url;
      _hasToken = stored?.bearerToken.trim().isNotEmpty ?? false;
      _token.clear();
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final quickValue = !widget.quickLoaded
        ? PrivacyCopy.looking
        : widget.quick.ready
            ? PrivacyCopy.ready
            : widget.quick.enabled
                ? PrivacyCopy.needsSetup
                : PrivacyCopy.disabled;
    return Column(
      children: [
        PrivacyPageHeader(
          title: PrivacyCopy.settings,
          subtitle: PrivacyCopy.settingsDescription,
          onOpenSwitcher: widget.onOpenSwitcher,
        ),
        Expanded(
          child: ListView(
            key: const PageStorageKey('privacy_settings_scroll'),
            padding: const EdgeInsets.fromLTRB(
              PrivacySpace.md,
              PrivacySpace.xs,
              PrivacySpace.md,
              PrivacySpace.xxl,
            ),
            children: [
              if (widget.quickMessage != null) ...[
                _PrivacyNotice(
                  icon: Icons.info_outline,
                  title: PrivacyCopy.quickSelfCapture,
                  message: widget.quickMessage!,
                  kind: 'interrupted',
                ),
                const SizedBox(height: PrivacySpace.md),
              ],
              if (_receipt != null || widget.receipt != null) ...[
                _PrivacyNotice(
                  icon: Icons.check_circle_outline,
                  title: PrivacyCopy.deletedSuccess,
                  message: _receipt ?? widget.receipt!,
                ),
                const SizedBox(height: PrivacySpace.md),
              ],
              PrivacySettingsGroup(
                children: [
                  PrivacySettingsRow(
                    key: const Key('privacy_settings_quick'),
                    icon: Icons.bolt_outlined,
                    title: PrivacyCopy.quickSelfCapture,
                    subtitle: widget.quick.ready ? PrivacyCopy.quickDoubleTap : PrivacyCopy.quickBenefit,
                    value: quickValue,
                    onTap: () => unawaited(widget.onOpenQuick()),
                  ),
                ],
              ),
              PrivacySettingsGroup(
                children: [
                  PrivacySettingsRow(
                    icon: Icons.palette_outlined,
                    title: PrivacyCopy.appearance,
                    subtitle: 'Preview changes immediately',
                    value: widget.themes.theme.name,
                    onTap: _openAppearance,
                  ),
                  PrivacySettingsRow(
                    icon: Icons.link_outlined,
                    title: PrivacyCopy.connectionSection,
                    subtitle: _probe ?? 'Transcription service credentials',
                    value: _hasToken ? 'Configured' : PrivacyCopy.needsSetup,
                    onTap: _openConnection,
                  ),
                  PrivacySettingsRow(
                    key: const Key('privacy_settings_intelligence'),
                    icon: Icons.auto_awesome_outlined,
                    title: PrivacyCopy.intelligence,
                    subtitle: PrivacyCopy.intelligenceSettingsDescription,
                    onTap: _openIntelligence,
                  ),
                  PrivacySettingsRow(
                    icon: Icons.shield_outlined,
                    title: PrivacyCopy.privacyAndRetention,
                    subtitle: 'Consent meaning and local transcript lifetime',
                    value: widget.retention == null
                        ? PrivacyCopy.needsSetup
                        : _PrivacyShellState._retentionLabel(widget.retention!),
                    onTap: _openPrivacy,
                  ),
                ],
              ),
              PrivacySettingsGroup(
                children: [
                  PrivacySettingsRow(
                    icon: Icons.phone_iphone_outlined,
                    title: PrivacyCopy.localData,
                    subtitle: 'Review deletion scope before clearing this phone',
                    onTap: _openLocalData,
                  ),
                  PrivacySettingsRow(
                    icon: Icons.monitor_heart_outlined,
                    title: PrivacyCopy.diagnostics,
                    subtitle: 'Connection and capture-state events only',
                    onTap: _openDiagnostics,
                  ),
                  PrivacySettingsRow(
                    icon: Icons.info_outline,
                    title: PrivacyCopy.about,
                    subtitle: PrivacyCopy.aboutExperiment,
                    onTap: _openAbout,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openAppearance() async {
    await showOmiSheet<void>(
      context: context,
      title: PrivacyCopy.appearance,
      builder: (sheetContext) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.only(bottom: PrivacySpace.md),
          child: Column(
            children: [
              for (final id in PrivacyThemeId.values)
                PrivacyThemeTile(
                  theme: privacyThemeById(id),
                  selected: widget.themes.id == id,
                  onTap: () => widget.themes.select(id),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openConnection() async {
    await showOmiSheet<void>(
      context: context,
      title: PrivacyCopy.connectionDetails,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Padding(
            padding: const EdgeInsets.only(bottom: PrivacySpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PrivacyField(
                  key: const Key('privacy_url'),
                  controller: _url,
                  label: PrivacyCopy.urlLabel,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: PrivacySpace.sm),
                PrivacyField(
                  key: const Key('privacy_token'),
                  controller: _token,
                  label: PrivacyCopy.tokenLabel,
                  obscure: true,
                  autocorrect: false,
                ),
                const SizedBox(height: PrivacySpace.xs),
                if (_hasToken) Text(PrivacyCopy.tokenSaved, style: PrivacyScope.of(sheetContext).meta()),
                Text(PrivacyCopy.tokenBlank, style: PrivacyScope.of(sheetContext).meta()),
                if (_probe != null) ...[
                  const SizedBox(height: PrivacySpace.sm),
                  _PrivacyNotice(
                    icon: Icons.wifi_tethering_outlined,
                    title: PrivacyCopy.connectionStatus,
                    message: _probe!,
                    kind: _probe!.toLowerCase().contains('failed') ? 'interrupted' : 'accent',
                  ),
                ],
                const SizedBox(height: PrivacySpace.md),
                Wrap(
                  spacing: PrivacySpace.xs,
                  runSpacing: PrivacySpace.xs,
                  children: [
                    PrivacyButton(
                      label: PrivacyCopy.save,
                      onPressed: () async {
                        await _save();
                        if (sheetContext.mounted) setSheetState(() {});
                      },
                    ),
                    PrivacyButton.secondary(
                      label: PrivacyCopy.testConnection,
                      onPressed: () async {
                        await _probeConnection();
                        if (sheetContext.mounted) setSheetState(() {});
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openIntelligence() async {
    await showOmiSheet<void>(
      context: context,
      title: PrivacyCopy.intelligence,
      builder: (sheetContext) => const SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Padding(
          padding: EdgeInsets.only(bottom: PrivacySpace.md),
          child: PrivacyIntelligenceSettings(),
        ),
      ),
    );
  }

  Future<void> _openPrivacy() async {
    await showOmiSheet<void>(
      context: context,
      title: PrivacyCopy.privacyAndRetention,
      builder: (sheetContext) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.only(bottom: PrivacySpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(PrivacyCopy.privacyExplain, style: PrivacyScope.of(sheetContext).body()),
              const SizedBox(height: PrivacySpace.sm),
              Text(PrivacyActionConfig.retentionNote, style: PrivacyScope.of(sheetContext).meta()),
              const PrivacySectionLabel(PrivacyCopy.chooseRetention),
              for (final choice in PrivacyRetentionChoice.values)
                PrivacyChoiceRow(
                  label: _PrivacyShellState._retentionLabel(choice),
                  selected: widget.retention == choice,
                  onTap: () => widget.onRetention(choice),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openLocalData() async {
    await showOmiSheet<void>(
      context: context,
      title: PrivacyCopy.localData,
      builder: (sheetContext) => SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.only(bottom: PrivacySpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(PrivacyCopy.clearPreview, style: PrivacyScope.of(sheetContext).body()),
              const SizedBox(height: PrivacySpace.xs),
              Text(PrivacyCopy.remoteUnavailable, style: PrivacyScope.of(sheetContext).meta()),
              const SizedBox(height: PrivacySpace.xl),
              Divider(color: PrivacyScope.of(sheetContext).palette.border),
              const SizedBox(height: PrivacySpace.sm),
              PrivacyButton.destructive(label: PrivacyCopy.clearLocal, onPressed: _clear),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openDiagnostics() async {
    await showOmiSheet<void>(
      context: context,
      title: PrivacyCopy.diagnostics,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.only(bottom: PrivacySpace.md),
        child: Wrap(
          spacing: PrivacySpace.xs,
          runSpacing: PrivacySpace.xs,
          children: [
            PrivacyButton.secondary(
              label: PrivacyCopy.clearDiagnostics,
              onPressed: () async => widget.store?.clearDiagnostics(),
            ),
            PrivacyButton.quiet(
              label: PrivacyCopy.exportDiagnostics,
              onPressed: () async {
                final text = await widget.store?.exportDiagnostics() ?? '[]';
                if (!sheetContext.mounted) return;
                await OmiClipboard.copy(sheetContext, text, what: PrivacyCopy.diagnostics);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAbout() async {
    await showOmiSheet<void>(
      context: context,
      title: PrivacyCopy.about,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.only(bottom: PrivacySpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(PrivacyCopy.aboutExperiment, style: PrivacyScope.of(sheetContext).section()),
            const SizedBox(height: PrivacySpace.sm),
            Text(PrivacyCopy.retentionNote, style: PrivacyScope.of(sheetContext).body()),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    PrivacyCredentials? existing;
    try {
      existing = await SecurePrivacyCredentialStore().read();
    } catch (_) {
      existing = null;
    }
    final typed = _token.text.trim();
    final bearer = typed.isNotEmpty ? typed : (existing?.bearerToken.trim() ?? '');
    final url = validatePrivacyLiveUrl(_url.text.trim());
    if (url == null || bearer.isEmpty) return;
    try {
      await SecurePrivacyCredentialStore().write(url: url.toString(), bearerToken: bearer);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _hasToken = true;
      _token.clear();
    });
  }

  Future<void> _probeConnection() async {
    final outcome = await probePrivacyConnection(
      credentials: SecurePrivacyCredentialStore(),
      connect: IoPrivacySocket().connect,
    );
    if (!mounted) return;
    setState(() => _probe = outcome.label);
  }

  Future<void> _clear() async {
    final store = widget.store;
    if (store == null) return;
    final preview = await store.previewAll();
    if (!mounted) return;
    final confirmed = await showOmiConfirm(
      context,
      title: PrivacyCopy.clearLocal,
      message: '${PrivacyCopy.clearPreview} ${preview.sessionCount}. ${PrivacyCopy.remoteUnavailable}',
      confirmLabel: PrivacyCopy.confirmDelete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final result = await store.clearLocal();
    if (!mounted || !result.ok) return;
    setState(() => _receipt = '${PrivacyCopy.deletedPhone} ${PrivacyCopy.remoteUnavailable}');
  }
}
