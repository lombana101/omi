import 'dart:async';

import 'package:flutter/material.dart';

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
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:omi/services/privacy_capture/privacy_suggestion.dart';
import 'package:omi/services/privacy_capture/privacy_theme.dart';
import 'package:omi/services/privacy_capture/privacy_widgets.dart';
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
    this.intelligenceClient,
  });

  final Future<String> Function()? findPendant;
  final PrivacyStore? store;
  final PrivacyCaptureController? controller;
  final DateTime Function()? clock;
  final int initialTab;
  final PrivacyThemeStore? themeStore;
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
    _tab = widget.initialTab;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_themes.load());
    unawaited(_boot());
  }

  Future<void> _boot() async {
    if (widget.store != null) {
      _store = widget.store;
      await _store!.recoverLaunch(_now);
      await _store!.expireDue(_now);
    } else if (privacyCaptureEnabled) {
      await PrivacyCaptureHost.ensureReady();
      _store = PrivacyCaptureHost.store;
    }
    final retention = await _store?.readRetention();
    if (!mounted) return;
    setState(() => _retention = retention);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached || state == AppLifecycleState.hidden) {
      unawaited(_controller?.onBackground());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
        return PrivacyScope(
          theme: theme,
          child: Theme(
            data: theme.toThemeData(),
            child: PrivacyScaffold(
              navigation: NavigationBar(
                backgroundColor: theme.palette.surface,
                indicatorColor: theme.palette.accent.withValues(alpha: 0.2),
                selectedIndex: _tab,
                onDestinationSelected: (index) => setState(() => _tab = index),
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.mic_none), label: PrivacyCopy.capture),
                  NavigationDestination(icon: Icon(Icons.list_alt), label: PrivacyCopy.sessions),
                  NavigationDestination(icon: Icon(Icons.check_circle_outline), label: PrivacyCopy.plan),
                  NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), label: PrivacyCopy.assistant),
                  NavigationDestination(icon: Icon(Icons.settings_outlined), label: PrivacyCopy.settings),
                ],
              ),
              body: _tabBody(),
            ),
          ),
        );
      },
    );
  }

  Widget _tabBody() {
    switch (_tab) {
      case 1:
        return _SessionsTab(store: _store, now: _now, onChanged: _refresh);
      case 2:
        return _TasksTab(
          store: _store,
          now: _now,
          onChanged: _refresh,
          intelligenceClient: widget.intelligenceClient,
        );
      case 3:
        return PrivacyAssistantTab(
          store: _store,
          now: _now,
          onChanged: _refresh,
          client: widget.intelligenceClient,
        );
      case 4:
        return _SettingsTab(
          store: _store,
          retention: _retention,
          onRetention: _setRetention,
          receipt: _receipt,
          themes: _themes,
        );
      default:
        return _capture();
    }
  }

  Future<void> _refresh() async {
    if (mounted) setState(() {});
  }

  Future<void> _setRetention(PrivacyRetentionChoice choice) async {
    final result = await _store?.setRetention(choice, at: _now);
    if (!mounted || result == null || !result.ok) return;
    setState(() => _retention = choice);
  }

  Widget _capture() {
    final controller = _controller;
    final missing = _missingStart;
    return ListView(
      padding: const EdgeInsets.all(PrivacySpace.md),
      children: [
        ValueListenableBuilder<PrivacyCaptureState>(
          valueListenable: privacyCaptureEnabled ? PrivacyCaptureHost.state : _localState,
          builder: (context, hostState, _) {
            final state = controller?.state ?? hostState;
            final label = _status(state, controller);
            final kind = _stateKind(state, controller);
            return Semantics(
              key: const Key('privacy_state'),
              label: label,
              child: PrivacyCaptureOrb(label: label, kind: kind, icon: _stateIcon(kind)),
            );
          },
        ),
        if (missing != null)
          Text(missing, key: const Key('privacy_start_missing'), style: PrivacyScope.of(context).meta()),
        if (PrivacyCaptureHost.bootError != null)
          Text(PrivacyCaptureHost.bootError!, style: PrivacyScope.of(context).meta()),
        const SizedBox(height: PrivacySpace.md),
        PrivacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_link, style: PrivacyScope.of(context).body()),
              ValueListenableBuilder<PrivacyLinkDiagnostics>(
                valueListenable: PrivacyCaptureHost.diagnostics,
                builder: (context, diag, _) => Text(
                  '${diag.buttonSubscribed ? PrivacyCopy.buttonOn : PrivacyCopy.buttonOff}. ${diag.audioSubscribed ? PrivacyCopy.audioOn : PrivacyCopy.audioOff}.',
                  style: PrivacyScope.of(context).meta(),
                ),
              ),
            ],
          ),
        ),
        const PrivacySectionLabel(PrivacyCopy.chooseRetention),
        Text(PrivacyCopy.retentionNote, style: PrivacyScope.of(context).meta()),
        if (_retention == PrivacyRetentionChoice.sessionOnly)
          Text(PrivacyCopy.sessionOnlyHint, style: PrivacyScope.of(context).meta()),
        const SizedBox(height: PrivacySpace.sm),
        for (final choice in PrivacyRetentionChoice.values)
          PrivacyChoiceRow(
            label: _retentionLabel(choice),
            selected: _retention == choice,
            onTap: () => _setRetention(choice),
          ),
        const SizedBox(height: PrivacySpace.md),
        TextField(
          key: const Key('privacy_purpose'),
          controller: _purpose,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: PrivacyCopy.purposeLabel),
        ),
        const SizedBox(height: PrivacySpace.sm),
        Text(PrivacyCopy.selfOnlyExplain, style: PrivacyScope.of(context).meta()),
        CheckboxListTile(
          key: const Key('privacy_self_only'),
          value: _selfOnly,
          onChanged: (value) => setState(() {
            _selfOnly = value ?? false;
            if (_selfOnly) _mixed = false;
          }),
          title: const Text(PrivacyCopy.assertSelfOnly),
        ),
        CheckboxListTile(
          key: const Key('privacy_mixed'),
          value: _mixed,
          onChanged: (value) => setState(() {
            _mixed = value ?? false;
            if (_mixed) _selfOnly = false;
          }),
          title: const Text(PrivacyCopy.assertMixed),
        ),
        const SizedBox(height: PrivacySpace.md),
        PrivacyButton(
          key: const Key('privacy_connect'),
          label: _busy ? PrivacyCopy.looking : PrivacyCopy.connect,
          kind: PrivacyButtonKind.secondary,
          onPressed: _busy ? null : _find,
        ),
        const SizedBox(height: PrivacySpace.sm),
        PrivacyButton(
          key: const Key('privacy_start'),
          label: PrivacyCopy.start,
          onPressed: missing == null ? _start : null,
        ),
        const SizedBox(height: PrivacySpace.sm),
        PrivacyButton.destructive(
          key: const Key('privacy_stop'),
          label: PrivacyCopy.stop,
          onPressed: () async {
            await _controller?.stop();
          },
        ),
      ],
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
}

final _localState = ValueNotifier<PrivacyCaptureState>(PrivacyCaptureState.off);

Future<String> _discoverPendant() async {
  final devices = PrivacyCaptureHost.devices;
  await devices.discover(timeout: 8);
  final found = devices.devices.where((device) => device.name.toLowerCase().contains('omi')).toList();
  final device = found.isEmpty ? (devices.devices.isEmpty ? null : devices.devices.first) : found.first;
  if (device == null) return 'No pendant found';
  final connection = await devices.ensureConnection(device.id, force: true);
  final decision = decidePrivacyConnect(linkEstablished: connection != null, name: device.name);
  if (!decision.armButton || connection == null) return decision.label;
  await PrivacyCaptureHost.armConnectedLink(connection.transport, deviceId: device.id);
  return decision.label;
}

class _SessionsTab extends StatefulWidget {
  const _SessionsTab({required this.store, required this.now, required this.onChanged});

  final PrivacyStore? store;
  final DateTime now;
  final Future<void> Function() onChanged;

  @override
  State<_SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<_SessionsTab> {
  String? _receipt;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    if (store == null) return const Center(child: Text(PrivacyCopy.noSessions));
    return FutureBuilder<List<PrivacySessionRecord>>(
      future: store.sessions(),
      builder: (context, snapshot) {
        final sessions = snapshot.data ?? const <PrivacySessionRecord>[];
        return ListView(
          children: [
            if (_receipt != null) Text(_receipt!),
            if (sessions.isEmpty) const Text(PrivacyCopy.noSessions),
            for (final session in sessions)
              PrivacyCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_sessionTitle(session)),
                  subtitle: Text(OmiDateFormat.of(context).dateTime(session.startedAt)),
                  onTap: () async {
                    final receipt = await routeToPage(
                      context,
                      _SessionDetail(store: store, session: session, onChanged: widget.onChanged),
                    );
                    if (!mounted) return;
                    if (receipt is String) setState(() => _receipt = receipt);
                    await widget.onChanged();
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  static String _sessionTitle(PrivacySessionRecord session) {
    if (session.incomplete || session.outcome == 'interrupted') return PrivacyCopy.interrupted;
    if (session.outcome == 'completed') return PrivacyCopy.completed;
    return PrivacyCopy.recordingOff;
  }
}

class _SessionDetail extends StatefulWidget {
  const _SessionDetail({required this.store, required this.session, required this.onChanged});

  final PrivacyStore store;
  final PrivacySessionRecord session;
  final Future<void> Function() onChanged;

  @override
  State<_SessionDetail> createState() => _SessionDetailState();
}

class _SessionDetailState extends State<_SessionDetail> {
  final _note = TextEditingController();
  var _deleted = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_deleted) {
      return Scaffold(
        appBar: AppBar(leading: const OmiBackButton(), title: const Text(PrivacyCopy.sessions)),
        body: const Padding(
          padding: EdgeInsets.all(OmiSpacing.md),
          child: Text(PrivacyCopy.deletedPhone),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(leading: const OmiBackButton(), title: const Text(PrivacyCopy.sessions)),
      body: FutureBuilder<_SessionBundle>(
        future: _loadSession(widget.store, widget.session.localId),
        builder: (context, snapshot) {
          final chunks = snapshot.data?.chunks ?? const <PrivacyChunkRecord>[];
          final notes = snapshot.data?.notes ?? const <PrivacyNoteRecord>[];
          return ListView(
            padding: const EdgeInsets.all(OmiSpacing.md),
            children: [
              Text(widget.session.incomplete ? PrivacyCopy.incomplete : PrivacyCopy.localOnly),
              Text(widget.session.ownerPurpose),
              Text('${PrivacyCopy.machine}. ${widget.session.consentBasis}'),
              for (final chunk in chunks)
                _ChunkEditor(
                  chunk: chunk,
                  onCorrect: (text) => _correct(chunk, text),
                  onCreateTask: () => _taskFrom(chunk),
                ),
              const PrivacySectionLabel(PrivacyCopy.ownerNote),
              if (notes.isEmpty) const Text(PrivacyCopy.noNotes),
              for (final note in notes) Text(note.text),
              TextField(
                key: const Key('privacy_owner_note'),
                controller: _note,
                decoration: const InputDecoration(labelText: PrivacyCopy.noteHint),
              ),
              PrivacyButton.secondary(label: PrivacyCopy.saveNote, onPressed: _saveNote),
              PrivacyButton.secondary(
                label: PrivacyCopy.findSuggestions,
                onPressed: () async {
                  await widget.store.refreshSuggestions(
                    service: const ActionSuggestionService(),
                    sessionId: widget.session.localId,
                  );
                  await widget.onChanged();
                },
              ),
              PrivacyIntelligenceExtractionButton(
                store: widget.store,
                session: widget.session,
                chunks: chunks,
                notes: notes,
                now: DateTime.now(),
                onChanged: widget.onChanged,
              ),
              PrivacyButton.destructive(label: PrivacyCopy.deleteSession, onPressed: _delete),
            ],
          );
        },
      ),
    );
  }

  static Future<_SessionBundle> _loadSession(PrivacyStore store, String sessionId) async => _SessionBundle(
        chunks: await store.chunks(sessionId),
        notes: await store.notes(sessionId),
      );

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
    setState(() {});
  }

  Future<void> _saveNote() async {
    final result = await widget.store.addNote(sessionId: widget.session.localId, text: _note.text);
    if (!mounted || !result.ok) return;
    _note.clear();
    setState(() {});
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

class _SessionBundle {
  const _SessionBundle({required this.chunks, required this.notes});

  final List<PrivacyChunkRecord> chunks;
  final List<PrivacyNoteRecord> notes;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.chunk.machineText),
        const Text(PrivacyCopy.machine),
        if (widget.chunk.correction != null) Text('${PrivacyCopy.correction}: ${widget.chunk.correction}'),
        TextField(
          key: Key('privacy_correction_${widget.chunk.sequence}'),
          controller: _correction,
          decoration: const InputDecoration(labelText: PrivacyCopy.correctionHint),
        ),
        PrivacyButton.quiet(
          label: PrivacyCopy.saveCorrection,
          onPressed: () => widget.onCorrect(_correction.text),
        ),
        PrivacyButton.secondary(
          label: PrivacyCopy.copyText,
          onPressed: () => OmiClipboard.copy(context, widget.chunk.displayText, what: PrivacyCopy.machine),
        ),
        PrivacyButton.secondary(
          label: PrivacyCopy.createFromChunk,
          onPressed: widget.onCreateTask,
        ),
      ],
    );
  }
}

class _TasksTab extends StatelessWidget {
  const _TasksTab({
    required this.store,
    required this.now,
    required this.onChanged,
    required this.intelligenceClient,
  });

  final PrivacyStore? store;
  final DateTime now;
  final Future<void> Function() onChanged;
  final PrivacyIntelligenceClient? intelligenceClient;

  @override
  Widget build(BuildContext context) {
    if (store == null) return const Center(child: Text(PrivacyCopy.inbox));
    return FutureBuilder<_TaskBundle>(
      future: _load(store!),
      builder: (context, snapshot) {
        final bundle = snapshot.data;
        if (bundle == null) return const OmiSpinner();
        final today = bundle.tasks
            .where((task) =>
                task.isOpen &&
                (privacyTaskSelectedToday(task, now) ||
                    privacyTaskDueToday(task.dueAt, now) ||
                    privacyTaskOverdue(task.dueAt, now)))
            .toList()
          ..sort((a, b) => (a.todayRank ?? 1 << 30).compareTo(b.todayRank ?? 1 << 30));
        final inbox = bundle.tasks.where((task) => task.isOpen && task.projectId == null);
        final completed = bundle.tasks.where((task) => !task.isOpen);
        return ListView(
          padding: const EdgeInsets.all(OmiSpacing.md),
          children: [
            Text(PrivacyCopy.suggestions, style: Theme.of(context).textTheme.titleMedium),
            for (final candidate in bundle.candidates)
              _CandidateTile(
                store: store!,
                candidate: candidate,
                onChanged: onChanged,
                intelligenceClient: intelligenceClient,
              ),
            Text(PrivacyCopy.today, style: Theme.of(context).textTheme.titleMedium),
            for (final task in today) _TaskTile(store: store!, task: task, now: now, onChanged: onChanged),
            Text(PrivacyCopy.inbox, style: Theme.of(context).textTheme.titleMedium),
            for (final task in inbox) _TaskTile(store: store!, task: task, now: now, onChanged: onChanged),
            Text(PrivacyCopy.projects, style: Theme.of(context).textTheme.titleMedium),
            for (final project in bundle.projects)
              _ProjectRow(
                store: store!,
                project: project,
                tasks: bundle.tasks.where((task) => task.projectId == project.projectId).toList(),
                now: now,
                onChanged: onChanged,
              ),
            _ProjectCreator(store: store!, onChanged: onChanged),
            Text(PrivacyCopy.habits, style: Theme.of(context).textTheme.titleMedium),
            for (final habit in bundle.habits)
              _HabitRow(
                store: store!,
                habit: habit,
                completions: bundle.habitCompletions,
                now: now,
                onChanged: onChanged,
              ),
            _HabitCreator(store: store!, now: now, onChanged: onChanged),
            Text(PrivacyCopy.completedFilter, style: Theme.of(context).textTheme.titleMedium),
            for (final task in completed) _TaskTile(store: store!, task: task, now: now, onChanged: onChanged),
            _ManualTask(store: store!, onChanged: onChanged),
          ],
        );
      },
    );
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
    required this.store,
    required this.candidate,
    required this.onChanged,
    required this.intelligenceClient,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if ({'task', 'commitment', 'intention'}.contains(widget.candidate.suggestedType))
          const Text(PrivacyCopy.notATask),
        Text('${PrivacyCopy.suggestionLabel}. ${widget.candidate.extractionVersion}'),
        Text(widget.candidate.proposedText),
        Text(widget.candidate.excerpt),
        if (widget.candidate.proposedTimeText != null) Text(widget.candidate.proposedTimeText!),
        if (widget.candidate.uncertainty != null) Text(PrivacyCopy.uncertainty(widget.candidate.uncertainty!)),
        if ({'task', 'commitment', 'intention'}.contains(widget.candidate.suggestedType)) ...[
          PrivacyButton(
            label: PrivacyCopy.accept,
            onPressed: () async {
              final result = await widget.store.acceptCandidate(widget.candidate.candidateId);
              if (result.ok) await widget.onChanged();
            },
          ),
          TextField(
            key: Key('privacy_edit_accept_${widget.candidate.candidateId}'),
            controller: _edit,
            decoration: const InputDecoration(labelText: PrivacyCopy.editAccept),
          ),
          PrivacyButton.secondary(
            label: PrivacyCopy.editAccept,
            onPressed: () async {
              final result = await widget.store.acceptCandidate(
                widget.candidate.candidateId,
                editedTitle: _edit.text,
              );
              if (result.ok) await widget.onChanged();
            },
          ),
        ],
        if (widget.candidate.suggestedType == 'habit')
          PrivacyButton(
            label: PrivacyCopy.acceptHabit,
            onPressed: () async {
              final result = await widget.store.acceptCandidateAsHabit(widget.candidate.candidateId);
              if (result.ok) await widget.onChanged();
            },
          ),
        if (widget.candidate.suggestedType == 'project')
          PrivacyButton(
            label: PrivacyCopy.acceptProject,
            onPressed: () async {
              final result = await widget.store.acceptCandidateAsProject(widget.candidate.candidateId);
              if (result.ok) await widget.onChanged();
            },
          ),
        if (widget.candidate.suggestedType == 'calendar_event') ...[
          const Text(PrivacyCopy.calendarSuggestionReview),
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
          if (_busy) const OmiSpinner(),
          if (_status != null) Text(_status!),
        ],
        PrivacyButton.secondary(
          label: PrivacyCopy.dismiss,
          onPressed: _busy
              ? null
              : () async {
                  final result = await widget.store.dismissCandidate(widget.candidate.candidateId);
                  if (result.ok) await widget.onChanged();
                },
        ),
      ],
    );
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
  const _TaskTile({required this.store, required this.task, required this.now, required this.onChanged});

  final PrivacyStore store;
  final PrivacyTaskRecord task;
  final DateTime now;
  final Future<void> Function() onChanged;

  @override
  State<_TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends State<_TaskTile> {
  late final TextEditingController _title = TextEditingController(text: widget.task.title);
  late final TextEditingController _note = TextEditingController(text: widget.task.note ?? '');

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(task.title),
        Text('$bucket. $due'),
        TextField(
          key: Key('privacy_task_edit_${task.taskId}'),
          controller: _title,
          decoration: const InputDecoration(labelText: PrivacyCopy.editTask),
        ),
        TextField(
          controller: _note,
          decoration: const InputDecoration(labelText: PrivacyCopy.taskNote),
        ),
        PrivacyButton.secondary(
          label: PrivacyCopy.saveEdits,
          onPressed: () async {
            final result = await widget.store.updateTask(
              task.taskId,
              title: _title.text,
              note: _note.text,
              clearNote: _note.text.trim().isEmpty,
              at: widget.now,
            );
            if (result.ok) await widget.onChanged();
          },
        ),
        PrivacyButton.secondary(
          label: task.isOpen ? PrivacyCopy.complete : PrivacyCopy.reopen,
          onPressed: () async {
            final result = await widget.store.setTaskStatus(task.taskId, completed: task.isOpen, at: widget.now);
            if (result.ok) await widget.onChanged();
          },
        ),
        if (task.isOpen)
          PrivacyButton.quiet(
            label: privacyTaskSelectedToday(task, widget.now) ? PrivacyCopy.removeFromToday : PrivacyCopy.addToToday,
            onPressed: () async {
              final result = await widget.store.setTaskToday(
                task.taskId,
                selected: !privacyTaskSelectedToday(task, widget.now),
                at: widget.now,
              );
              if (result.ok) await widget.onChanged();
            },
          ),
        PrivacyButton.quiet(
          label: PrivacyCopy.delete,
          onPressed: () async {
            final confirmed = await showOmiConfirm(
              context,
              title: PrivacyCopy.delete,
              confirmLabel: PrivacyCopy.confirmDelete,
              destructive: true,
            );
            if (!confirmed) return;
            final result = await widget.store.deleteTask(task.taskId);
            if (result.ok) await widget.onChanged();
          },
        ),
        PrivacyButton.quiet(
          label: PrivacyCopy.chooseDue,
          onPressed: _pickDue,
        ),
        PrivacyButton.quiet(
          label: PrivacyCopy.clearDue,
          onPressed: () async {
            final result = await widget.store.updateTask(task.taskId, clearDue: true, at: widget.now);
            if (result.ok) await widget.onChanged();
          },
        ),
        PrivacyButton.quiet(
          label: PrivacyCopy.assignProject,
          onPressed: _assign,
        ),
        PrivacyButton.quiet(
          label: PrivacyCopy.unassign,
          onPressed: () async {
            final result = await widget.store.updateTask(task.taskId, clearProject: true, at: widget.now);
            if (result.ok) await widget.onChanged();
          },
        ),
      ],
    );
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

class _ProjectRow extends StatefulWidget {
  const _ProjectRow({
    required this.store,
    required this.project,
    required this.tasks,
    required this.now,
    required this.onChanged,
  });

  final PrivacyStore store;
  final PrivacyProjectRecord project;
  final List<PrivacyTaskRecord> tasks;
  final DateTime now;
  final Future<void> Function() onChanged;

  @override
  State<_ProjectRow> createState() => _ProjectRowState();
}

class _ProjectRowState extends State<_ProjectRow> {
  late final TextEditingController _name = TextEditingController(text: widget.project.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(project.archived ? '${project.name}. ${PrivacyCopy.archive}' : project.name),
        Text(PrivacyCopy.projectProgress(widget.tasks.where((task) => !task.isOpen).length, widget.tasks.length)),
        for (final task in widget.tasks.where((task) => task.isOpen))
          _TaskTile(store: widget.store, task: task, now: widget.now, onChanged: widget.onChanged),
        if (!project.archived)
          TextField(
            key: Key('privacy_project_rename_${project.projectId}'),
            controller: _name,
            decoration: const InputDecoration(labelText: PrivacyCopy.rename),
          ),
        if (!project.archived)
          PrivacyButton.secondary(
            label: PrivacyCopy.rename,
            onPressed: () async {
              final result = await widget.store.renameProject(project.projectId, _name.text);
              if (result.ok) await widget.onChanged();
            },
          ),
        PrivacyButton.quiet(
          label: project.archived ? PrivacyCopy.unarchive : PrivacyCopy.archive,
          onPressed: () async {
            if (!project.archived) {
              final confirmed = await showOmiConfirm(
                context,
                title: PrivacyCopy.archiveConfirm,
                confirmLabel: PrivacyCopy.archive,
              );
              if (!confirmed || !mounted) return;
            }
            final result = await widget.store.archiveProject(project.projectId, archived: !project.archived);
            if (result.ok) await widget.onChanged();
          },
        ),
      ],
    );
  }
}

class _ManualTask extends StatefulWidget {
  const _ManualTask({required this.store, required this.onChanged});
  final PrivacyStore store;
  final Future<void> Function() onChanged;

  @override
  State<_ManualTask> createState() => _ManualTaskState();
}

class _ManualTaskState extends State<_ManualTask> {
  final _title = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
            key: const Key('privacy_task_title'),
            controller: _title,
            decoration: const InputDecoration(labelText: PrivacyCopy.taskHint)),
        PrivacyButton(
          key: const Key('privacy_save_task'),
          label: PrivacyCopy.saveTask,
          onPressed: () async {
            final result = await widget.store.createTask(title: _title.text);
            if (!result.ok || !mounted) return;
            _title.clear();
            await widget.onChanged();
          },
        ),
      ],
    );
  }
}

class _ProjectCreator extends StatefulWidget {
  const _ProjectCreator({required this.store, required this.onChanged});
  final PrivacyStore store;
  final Future<void> Function() onChanged;

  @override
  State<_ProjectCreator> createState() => _ProjectCreatorState();
}

class _ProjectCreatorState extends State<_ProjectCreator> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: PrivacyCopy.projectName)),
        PrivacyButton.secondary(
          label: PrivacyCopy.createProject,
          onPressed: () async {
            final result = await widget.store.createProject(_name.text);
            if (!result.ok || !mounted) return;
            _name.clear();
            await widget.onChanged();
          },
        ),
      ],
    );
  }
}

class _HabitRow extends StatelessWidget {
  const _HabitRow({
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
    final todayKey = privacyDateKey(now);
    final doneToday = completions.any((item) => item.habitId == habit.habitId && item.dateKey == todayKey);
    final history = completions.where((item) => item.habitId == habit.habitId).map((item) => item.dateKey).join(', ');
    return PrivacyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(habit.title),
          Text('${PrivacyCopy.recentHistory}: ${history.isEmpty ? PrivacyCopy.none : history}'),
          PrivacyButton.secondary(
            label: doneToday ? PrivacyCopy.notDoneToday : PrivacyCopy.doneToday,
            onPressed: () async {
              final result = await store.setHabitCompleted(habit.habitId, day: now, completed: !doneToday);
              if (result.ok) await onChanged();
            },
          ),
          PrivacyButton.quiet(
            label: PrivacyCopy.archive,
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

class _HabitCreator extends StatefulWidget {
  const _HabitCreator({required this.store, required this.now, required this.onChanged});

  final PrivacyStore store;
  final DateTime now;
  final Future<void> Function() onChanged;

  @override
  State<_HabitCreator> createState() => _HabitCreatorState();
}

class _HabitCreatorState extends State<_HabitCreator> {
  final _title = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          key: const Key('privacy_habit_title'),
          controller: _title,
          decoration: const InputDecoration(labelText: PrivacyCopy.habitName),
        ),
        PrivacyButton.secondary(
          label: PrivacyCopy.createHabit,
          onPressed: () async {
            final result = await widget.store.createHabit(_title.text, at: widget.now);
            if (!result.ok || !mounted) return;
            _title.clear();
            await widget.onChanged();
          },
        ),
      ],
    );
  }
}

class _SettingsTab extends StatefulWidget {
  const _SettingsTab({
    required this.store,
    required this.retention,
    required this.onRetention,
    required this.themes,
    this.receipt,
  });

  final PrivacyStore? store;
  final PrivacyRetentionChoice? retention;
  final Future<void> Function(PrivacyRetentionChoice choice) onRetention;
  final PrivacyThemeController themes;
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
    final stored = await SecurePrivacyCredentialStore().read();
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
    return ListView(
      padding: const EdgeInsets.all(PrivacySpace.md),
      children: [
        const PrivacySectionLabel(PrivacyCopy.appearance),
        for (final id in PrivacyThemeId.values)
          PrivacyThemeTile(
            theme: privacyThemeById(id),
            selected: widget.themes.id == id,
            onTap: () => widget.themes.select(id),
          ),
        const PrivacySectionLabel(PrivacyCopy.connectionSection),
        TextField(
          key: const Key('privacy_url'),
          controller: _url,
          decoration: const InputDecoration(labelText: PrivacyCopy.urlLabel),
          autocorrect: false,
        ),
        TextField(
          key: const Key('privacy_token'),
          controller: _token,
          decoration: const InputDecoration(labelText: PrivacyCopy.tokenLabel),
          obscureText: true,
          autocorrect: false,
        ),
        if (_hasToken) const Text(PrivacyCopy.tokenSaved),
        const Text(PrivacyCopy.tokenBlank),
        PrivacyButton(label: PrivacyCopy.save, onPressed: _save),
        PrivacyButton.secondary(label: PrivacyCopy.testConnection, onPressed: _probeConnection),
        if (_probe != null) Text(_probe!),
        const PrivacyIntelligenceSettings(),
        const PrivacySectionLabel(PrivacyCopy.localData),
        const Text(PrivacyCopy.privacyExplain),
        const Text(PrivacyActionConfig.retentionNote),
        PrivacyButton.destructive(label: PrivacyCopy.clearLocal, onPressed: _clear),
        const PrivacySectionLabel(PrivacyCopy.diagnostics),
        PrivacyButton.secondary(
          label: PrivacyCopy.clearDiagnostics,
          onPressed: () async {
            await widget.store?.clearDiagnostics();
          },
        ),
        PrivacyButton.quiet(
          label: PrivacyCopy.exportDiagnostics,
          onPressed: () async {
            final text = await widget.store?.exportDiagnostics() ?? '[]';
            if (!context.mounted) return;
            await OmiClipboard.copy(context, text, what: PrivacyCopy.diagnostics);
          },
        ),
        if (_receipt != null) Text(_receipt!),
        if (widget.receipt != null) Text(widget.receipt!),
        const PrivacySectionLabel(PrivacyCopy.aboutExperiment),
        const Text(PrivacyCopy.retentionNote),
      ],
    );
  }

  Future<void> _save() async {
    final existing = await SecurePrivacyCredentialStore().read();
    final typed = _token.text.trim();
    final bearer = typed.isNotEmpty ? typed : (existing?.bearerToken.trim() ?? '');
    final url = validatePrivacyLiveUrl(_url.text.trim());
    if (url == null || bearer.isEmpty) return;
    await SecurePrivacyCredentialStore().write(url: url.toString(), bearerToken: bearer);
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
