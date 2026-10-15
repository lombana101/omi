import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:uuid/uuid.dart';

import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_client.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_config.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_coordinator.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_models.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:omi/services/privacy_capture/privacy_theme.dart';
import 'package:omi/services/privacy_capture/privacy_widgets.dart';
import 'package:omi/ui/ui.dart';

Future<String> _privacyTimezone() async {
  try {
    return (await FlutterTimezone.getLocalTimezone()).identifier;
  } catch (_) {
    return 'UTC';
  }
}

class PrivacyAssistantTab extends StatefulWidget {
  const PrivacyAssistantTab({
    super.key,
    required this.store,
    required this.now,
    required this.onChanged,
    this.client,
    this.timezoneLoader,
    this.onOpenSwitcher,
  });

  final PrivacyStore? store;
  final DateTime now;
  final Future<void> Function() onChanged;
  final PrivacyIntelligenceClient? client;
  final Future<String> Function()? timezoneLoader;
  final VoidCallback? onOpenSwitcher;

  @override
  State<PrivacyAssistantTab> createState() => _PrivacyAssistantTabState();
}

class _PrivacyAssistantTabState extends State<PrivacyAssistantTab> {
  final _message = TextEditingController();
  late final PrivacyIntelligenceClient _client;
  late final bool _ownsClient;
  bool _busy = false;
  String? _status;
  PrivacyIntelligenceAssistantResponse? _response;
  List<PrivacyIntelligenceEvent> _events = const [];
  Map<String, String> _calendarNames = const {};
  String? _reconcileOperationId;

  PrivacyIntelligenceCoordinator? get _coordinator {
    final store = widget.store;
    if (store == null) return null;
    return PrivacyIntelligenceCoordinator(client: _client, store: store);
  }

  @override
  void initState() {
    super.initState();
    _ownsClient = widget.client == null;
    _client = widget.client ??
        PrivacyIntelligenceClient(
          credentials: PrivacyIntelligenceCredentialStore(),
        );
    // Standalone widget consumers expect an initial read. The privacy shell
    // keeps this tab alive offstage, so it defers all network work until the
    // owner explicitly refreshes or sends a message.
    if (widget.onOpenSwitcher == null) unawaited(_refreshCalendar(silent: true));
  }

  @override
  void dispose() {
    _message.dispose();
    if (_ownsClient) _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final response = _response;
    return Column(
      children: [
        PrivacyPageHeader(
          title: PrivacyCopy.assistant,
          subtitle: PrivacyCopy.assistantDescription,
          onOpenSwitcher: widget.onOpenSwitcher ?? () {},
          trailing: OmiIconButton.filled(
            icon: const Icon(Icons.refresh_rounded),
            label: PrivacyCopy.refreshCalendar,
            onPressed: _busy ? null : _refreshCalendar,
            color: PrivacyScope.of(context).palette.text,
            fillColor: PrivacyScope.of(context).palette.surface,
          ),
        ),
        Expanded(
          child: ListView(
            key: const PageStorageKey('privacy_assistant_scroll'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                    Text(PrivacyCopy.askHint, style: PrivacyScope.of(context).section()),
                    const SizedBox(height: PrivacySpace.sm),
                    PrivacyField(
                      key: const Key('privacy_assistant_message'),
                      controller: _message,
                      label: PrivacyCopy.askHint,
                      minLines: 2,
                      maxLines: 5,
                    ),
                    const SizedBox(height: PrivacySpace.sm),
                    Wrap(
                      spacing: PrivacySpace.xs,
                      runSpacing: PrivacySpace.xs,
                      children: [
                        PrivacyButton(
                          key: const Key('privacy_assistant_ask'),
                          label: PrivacyCopy.ask,
                          onPressed: _busy ? null : _ask,
                        ),
                        PrivacyButton.secondary(
                          key: const Key('privacy_extract_manual'),
                          label: PrivacyCopy.extractActions,
                          onPressed: _busy ? null : _extractManual,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_busy) const OmiLoadingState(label: PrivacyCopy.working),
              if (_status != null)
                PrivacyCard(
                  tint: PrivacyScope.of(context).palette.surfaceSecondary,
                  child: Text(_status!, key: const Key('privacy_intelligence_status')),
                ),
              if (response != null) ...[
                PrivacyCard(child: Text(response.message, style: PrivacyScope.of(context).body())),
                for (final event in response.events) _eventCard(event),
                if (response.taskSuggestions.isNotEmpty)
                  const PrivacyCard(child: Text(PrivacyCopy.pendingSuggestionsSaved)),
                if (response.calendarProposal != null)
                  PrivacyButton(
                    key: const Key('privacy_review_calendar_proposal'),
                    label: PrivacyCopy.reviewCalendarChange,
                    onPressed: _busy ? null : () => _reviewProposal(response.calendarProposal!),
                  ),
              ],
              if (_reconcileOperationId != null)
                PrivacyButton.secondary(
                  key: const Key('privacy_reconcile_calendar'),
                  label: PrivacyCopy.reconcileCalendar,
                  onPressed: _busy ? null : _reconcile,
                ),
              const PrivacySectionLabel(PrivacyCopy.upcomingEvents),
              if (_events.isEmpty && !_busy)
                const OmiEmptyState(
                  icon: Icons.event_available_outlined,
                  title: PrivacyCopy.noEvents,
                  message: 'Your private TimeTree events will appear here after the backend is configured.',
                ),
              for (final event in _events) _eventCard(event, editable: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _eventCard(PrivacyIntelligenceEvent event, {bool editable = false}) {
    final calendar = _calendarNames[event.calendarId] ?? event.calendarId;
    return PrivacyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(event.title),
          Text(calendar),
          Text(OmiDateFormat.of(context).timeRange(event.startAt.toLocal(), event.endAt.toLocal())),
          Text(event.startTimezone),
          if (event.isRecurring) const Text(PrivacyCopy.recurringSeries),
          if (editable) ...[
            PrivacyButton.secondary(
              label: PrivacyCopy.editEventTitle,
              onPressed: _busy ? null : () => _editEvent(event),
            ),
            PrivacyButton.destructive(
              label: PrivacyCopy.deleteEvent,
              onPressed: _busy ? null : () => _deleteEvent(event),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _ask() async {
    final coordinator = _coordinator;
    final text = _message.text.trim();
    if (coordinator == null || text.isEmpty) return;
    await _run(() async {
      final response = await coordinator.ask(
        message: text,
        timezone: await (widget.timezoneLoader ?? _privacyTimezone)(),
        now: widget.now,
      );
      if (!mounted) return;
      setState(() {
        _response = response;
        _status = response.taskSuggestions.isEmpty ? null : PrivacyCopy.pendingSuggestionsSaved;
      });
      await widget.onChanged();
    });
  }

  Future<void> _extractManual() async {
    final coordinator = _coordinator;
    final text = _message.text.trim();
    if (coordinator == null || text.isEmpty) return;
    await _run(() async {
      final count = await coordinator.extract(
        sourceRef: 'manual:${const Uuid().v4()}',
        sourceKind: PrivacyIntelligenceSourceKind.manualText,
        authorizationBasis: PrivacyIntelligenceAuthorizationBasis.selfOnly,
        text: text,
        timezone: await (widget.timezoneLoader ?? _privacyTimezone)(),
        now: widget.now,
      );
      if (!mounted) return;
      setState(() => _status = count == 0 ? PrivacyCopy.noGroundedActions : PrivacyCopy.pendingSuggestionsSaved);
      await widget.onChanged();
    });
  }

  Future<void> _refreshCalendar({bool silent = false}) async {
    await _run(
      () async {
        final coordinator = _coordinator;
        if (coordinator != null) {
          await coordinator.evaluateProactive(
            timezone: await (widget.timezoneLoader ?? _privacyTimezone)(),
            now: widget.now,
          );
          await widget.onChanged();
        }
        await _loadCalendar(silent: silent);
      },
      silent: silent,
    );
  }

  Future<void> _loadCalendar({required bool silent}) async {
    final calendars = await _client.calendars();
    final events = await _client.events(
      query: PrivacyIntelligenceEventQuery(
        startAt: widget.now,
        endAt: widget.now.add(const Duration(days: 30)),
        limit: 100,
      ),
    );
    if (!mounted) return;
    setState(() {
      _calendarNames = {for (final calendar in calendars) calendar.id: calendar.name};
      _events = events;
      if (!silent) _status = null;
    });
  }

  Future<void> _bestEffortCalendarRefresh() async {
    try {
      await _loadCalendar(silent: true);
    } catch (_) {
      // A confirmed provider result remains authoritative even when the
      // follow-up read is temporarily unavailable.
    }
  }

  Future<void> _reviewProposal(PrivacyIntelligenceCalendarWriteProposal proposal) async {
    final coordinator = _coordinator;
    if (coordinator == null) return;
    await _run(() async {
      final preview = await coordinator.prepare(proposal);
      await _approveAndConfirm(preview);
    });
  }

  Future<void> _editEvent(PrivacyIntelligenceEvent event) async {
    final controller = TextEditingController(text: event.title);
    final accepted = await showOmiSheet<bool>(
      context: context,
      title: PrivacyCopy.editEventTitle,
      builder: (sheetContext) => Column(
        children: [
          TextField(
            key: const Key('privacy_calendar_edit_title'),
            controller: controller,
            decoration: const InputDecoration(labelText: PrivacyCopy.editEventTitle),
          ),
          PrivacyButton(
            label: PrivacyCopy.saveTitle,
            onPressed: () async => Navigator.of(sheetContext).pop(true),
          ),
        ],
      ),
    );
    final title = controller.text.trim();
    controller.dispose();
    if (accepted != true || title.isEmpty || title == event.title || !mounted) return;
    final request = PrivacyIntelligenceCalendarOperationRequest(
      kind: PrivacyIntelligenceCalendarOperationKind.update,
      idempotencyKey: const Uuid().v4().replaceAll('-', ''),
      calendarId: event.calendarId,
      eventUuid: event.uuid,
      changes: PrivacyIntelligenceCalendarEventPatch(title: title),
      recurrenceScope: event.isRecurring ? PrivacyIntelligenceEditScope.series : null,
    );
    await _prepareRequest(request);
  }

  Future<void> _deleteEvent(PrivacyIntelligenceEvent event) async {
    final request = PrivacyIntelligenceCalendarOperationRequest(
      kind: PrivacyIntelligenceCalendarOperationKind.delete,
      idempotencyKey: const Uuid().v4().replaceAll('-', ''),
      calendarId: event.calendarId,
      eventUuid: event.uuid,
      recurrenceScope: event.isRecurring ? PrivacyIntelligenceEditScope.series : null,
    );
    await _prepareRequest(request);
  }

  Future<void> _prepareRequest(PrivacyIntelligenceCalendarOperationRequest request) async {
    final coordinator = _coordinator;
    if (coordinator == null) return;
    await _run(() async {
      final preview = await coordinator.prepareRequest(request);
      await _approveAndConfirm(preview);
    });
  }

  Future<void> _approveAndConfirm(PrivacyIntelligenceCalendarOperationPreview preview) async {
    if (!mounted) return;
    final approved = await showOmiConfirm(
      context,
      title: PrivacyCopy.reviewCalendarChange,
      message: _previewMessage(preview),
      confirmLabel: PrivacyCopy.confirmCalendarChange,
      destructive: preview.kind == PrivacyIntelligenceCalendarOperationKind.delete,
    );
    if (!approved || !mounted) return;
    try {
      final outcome = await _coordinator!.confirm(preview);
      if (!mounted) return;
      setState(() {
        _status = outcome.message;
        _reconcileOperationId = outcome.requiresReconciliation ? outcome.operationId : null;
      });
      if (outcome.status == PrivacyIntelligenceOperationStatus.succeeded) {
        await _bestEffortCalendarRefresh();
      }
    } on PrivacyIntelligenceClientException {
      if (!mounted) return;
      setState(() {
        _status = PrivacyCopy.calendarUncertain;
        _reconcileOperationId = preview.operationId;
      });
    }
  }

  String _previewMessage(PrivacyIntelligenceCalendarOperationPreview preview) {
    final when = OmiDateFormat.of(context).timeRange(preview.startAt.toLocal(), preview.endAt.toLocal());
    final scope = preview.recurrenceScope == PrivacyIntelligencePreviewRecurrenceScope.series
        ? PrivacyCopy.entireRecurringSeries
        : PrivacyCopy.oneNonRecurringEvent;
    return '${preview.calendarName}\n${preview.title}\n$when\n${preview.timezone}\n$scope\n${preview.changes.join(', ')}';
  }

  Future<void> _reconcile() async {
    final operationId = _reconcileOperationId;
    final coordinator = _coordinator;
    if (operationId == null || coordinator == null) return;
    await _run(() async {
      final outcome = await coordinator.reconcile(operationId);
      if (!mounted) return;
      setState(() {
        _status = outcome.message;
        _reconcileOperationId = outcome.requiresReconciliation ? operationId : null;
      });
      if (outcome.status == PrivacyIntelligenceOperationStatus.succeeded) {
        await _bestEffortCalendarRefresh();
      }
    });
  }

  Future<void> _run(Future<void> Function() action, {bool silent = false}) async {
    if (_busy) return;
    if (mounted) setState(() => _busy = true);
    try {
      await action();
    } on PrivacyIntelligenceClientException catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _status = error.kind == PrivacyIntelligenceFailureKind.notConfigured
            ? PrivacyCopy.intelligenceNotConfigured
            : PrivacyCopy.intelligenceUnavailable;
      });
    } catch (_) {
      if (!mounted || silent) return;
      setState(() => _status = PrivacyCopy.intelligenceUnavailable);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class PrivacyIntelligenceExtractionButton extends StatefulWidget {
  const PrivacyIntelligenceExtractionButton({
    super.key,
    required this.store,
    required this.session,
    required this.chunks,
    required this.notes,
    required this.now,
    required this.onChanged,
  });

  final PrivacyStore store;
  final PrivacySessionRecord session;
  final List<PrivacyChunkRecord> chunks;
  final List<PrivacyNoteRecord> notes;
  final DateTime now;
  final Future<void> Function() onChanged;

  @override
  State<PrivacyIntelligenceExtractionButton> createState() => _PrivacyIntelligenceExtractionButtonState();
}

class _PrivacyIntelligenceExtractionButtonState extends State<PrivacyIntelligenceExtractionButton> {
  bool _busy = false;
  String? _status;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PrivacyButton.secondary(
            key: const Key('privacy_extract_session'),
            label: PrivacyCopy.intelligentSuggestions,
            onPressed: _busy ? null : _extract,
          ),
          if (_busy) const OmiSpinner(),
          if (_status != null) Text(_status!),
        ],
      );

  Future<void> _extract() async {
    final text = <String>[
      ...widget.chunks.map((chunk) => chunk.displayText),
      ...widget.notes.map((note) => note.text),
    ].where((value) => value.trim().isNotEmpty).join('\n');
    if (text.isEmpty) return;
    final client = PrivacyIntelligenceClient(credentials: PrivacyIntelligenceCredentialStore());
    final coordinator = PrivacyIntelligenceCoordinator(client: client, store: widget.store);
    setState(() => _busy = true);
    try {
      final mixed = widget.session.consentBasis == 'participants_consented';
      final count = await coordinator.extract(
        sourceRef: 'session:${widget.session.localId}',
        sourceKind: mixed
            ? PrivacyIntelligenceSourceKind.consentedConversation
            : PrivacyIntelligenceSourceKind.selfAuthoredTranscript,
        authorizationBasis: mixed
            ? PrivacyIntelligenceAuthorizationBasis.participantsConsented
            : PrivacyIntelligenceAuthorizationBasis.selfOnly,
        text: text,
        timezone: await _privacyTimezone(),
        now: widget.now,
        sessionId: widget.session.localId,
        captureId: widget.session.captureId,
      );
      if (!mounted) return;
      setState(() => _status = count == 0 ? PrivacyCopy.noGroundedActions : PrivacyCopy.pendingSuggestionsSaved);
      await widget.onChanged();
    } on PrivacyIntelligenceClientException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = error.kind == PrivacyIntelligenceFailureKind.notConfigured
            ? PrivacyCopy.intelligenceNotConfigured
            : PrivacyCopy.intelligenceUnavailable;
      });
    } catch (_) {
      if (mounted) setState(() => _status = PrivacyCopy.intelligenceUnavailable);
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }
}

class PrivacyIntelligenceSettings extends StatefulWidget {
  const PrivacyIntelligenceSettings({super.key});

  @override
  State<PrivacyIntelligenceSettings> createState() => _PrivacyIntelligenceSettingsState();
}

class _PrivacyIntelligenceSettingsState extends State<PrivacyIntelligenceSettings> {
  final _url = TextEditingController();
  final _owner = TextEditingController();
  final _token = TextEditingController();
  final _credentials = PrivacyIntelligenceCredentialStore();
  bool _hasToken = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _url.dispose();
    _owner.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            PrivacyCopy.intelligenceSettingsDescription,
            style: PrivacyScope.of(context).body(),
          ),
          const SizedBox(height: PrivacySpace.md),
          PrivacyField(
            key: const Key('privacy_intelligence_url'),
            controller: _url,
            label: PrivacyCopy.intelligenceUrl,
            autocorrect: false,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: PrivacySpace.sm),
          PrivacyField(
            key: const Key('privacy_intelligence_owner'),
            controller: _owner,
            label: PrivacyCopy.intelligenceOwner,
            autocorrect: false,
          ),
          const SizedBox(height: PrivacySpace.sm),
          PrivacyField(
            key: const Key('privacy_intelligence_token'),
            controller: _token,
            label: PrivacyCopy.intelligenceToken,
            obscure: true,
            autocorrect: false,
          ),
          const SizedBox(height: PrivacySpace.xs),
          if (_hasToken) Text(PrivacyCopy.tokenSaved, style: PrivacyScope.of(context).meta()),
          Text(PrivacyCopy.tokenBlank, style: PrivacyScope.of(context).meta()),
          if (_status != null) ...[
            const SizedBox(height: PrivacySpace.sm),
            PrivacyCard(
              tint: PrivacyScope.of(context).palette.surfaceSecondary,
              child: Text(_status!, key: const Key('privacy_intelligence_settings_status')),
            ),
          ],
          const SizedBox(height: PrivacySpace.md),
          Wrap(
            spacing: PrivacySpace.xs,
            runSpacing: PrivacySpace.xs,
            children: [
              PrivacyButton(label: PrivacyCopy.save, onPressed: _save),
              PrivacyButton.secondary(label: PrivacyCopy.testConnection, onPressed: _test),
            ],
          ),
          const SizedBox(height: PrivacySpace.sm),
          PrivacyButton.destructive(label: PrivacyCopy.clearIntelligence, onPressed: _clear),
        ],
      );

  Future<void> _load() async {
    try {
      final value = await _credentials.read();
      if (!mounted || value == null) return;
      setState(() {
        _url.text = value.baseUrl;
        _owner.text = value.ownerMappingId;
        _hasToken = true;
      });
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      PrivacyIntelligenceCredentials? existing;
      try {
        existing = await _credentials.read();
      } on PrivacyIntelligenceConfigurationException {
        // A previously interrupted write is deliberately unreadable. A new,
        // complete form submission with a replacement token may repair it.
      }
      final enteredToken = _token.text.trim();
      final token = enteredToken.isEmpty ? existing?.bearerToken : enteredToken;
      if (token == null) {
        if (mounted) setState(() => _status = PrivacyCopy.intelligenceNotConfigured);
        return;
      }
      await _credentials.write(
        baseUrl: _url.text.trim(),
        ownerMappingId: _owner.text.trim(),
        bearerToken: token,
      );
      if (!mounted) return;
      setState(() {
        _token.clear();
        _hasToken = true;
        _status = PrivacyCopy.intelligenceSaved;
      });
    } catch (_) {
      if (mounted) setState(() => _status = PrivacyCopy.intelligenceNotConfigured);
    }
  }

  Future<void> _test() async {
    final client = PrivacyIntelligenceClient(credentials: _credentials);
    try {
      await client.integrationStatus();
      if (mounted) setState(() => _status = PrivacyCopy.intelligenceConnected);
    } catch (_) {
      if (mounted) setState(() => _status = PrivacyCopy.intelligenceUnavailable);
    } finally {
      client.close();
    }
  }

  Future<void> _clear() async {
    final confirmed = await showOmiConfirm(
      context,
      title: PrivacyCopy.clearIntelligence,
      message: PrivacyCopy.clearIntelligenceMessage,
      confirmLabel: PrivacyCopy.clearIntelligence,
      destructive: true,
    );
    if (!confirmed) return;
    await _credentials.clear();
    if (!mounted) return;
    setState(() {
      _url.clear();
      _owner.clear();
      _token.clear();
      _hasToken = false;
      _status = null;
    });
  }
}
