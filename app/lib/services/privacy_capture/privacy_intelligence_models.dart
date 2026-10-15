enum PrivacyIntelligenceSuggestionType {
  task('task'),
  calendarEvent('calendar_event'),
  commitment('commitment'),
  project('project'),
  habit('habit'),
  intention('intention'),
  advice('advice');

  const PrivacyIntelligenceSuggestionType(this.wireName);
  final String wireName;
}

enum PrivacyIntelligenceSourceKind {
  selfAuthoredTranscript('self_authored_transcript'),
  manualText('manual_text'),
  ownerNote('owner_note'),
  consentedConversation('consented_conversation');

  const PrivacyIntelligenceSourceKind(this.wireName);
  final String wireName;
}

enum PrivacyIntelligenceAuthorizationBasis {
  selfOnly('self_only'),
  participantsConsented('participants_consented');

  const PrivacyIntelligenceAuthorizationBasis(this.wireName);
  final String wireName;
}

enum PrivacyIntelligenceCalendarOperationKind {
  create('create'),
  update('update'),
  delete('delete');

  const PrivacyIntelligenceCalendarOperationKind(this.wireName);
  final String wireName;
}

enum PrivacyIntelligenceEditScope {
  occurrence('occurrence'),
  series('series');

  const PrivacyIntelligenceEditScope(this.wireName);
  final String wireName;
}

enum PrivacyIntelligencePreviewRecurrenceScope {
  notRecurring('not_recurring'),
  series('series');

  const PrivacyIntelligencePreviewRecurrenceScope(this.wireName);
  final String wireName;
}

enum PrivacyIntelligenceOperationStatus {
  pending('pending'),
  succeeded('succeeded'),
  failed('failed'),
  uncertain('uncertain');

  const PrivacyIntelligenceOperationStatus(this.wireName);
  final String wireName;
}

class PrivacyIntelligenceIntegrationStatus {
  const PrivacyIntelligenceIntegrationStatus({
    required this.localIntelligence,
    required this.timeTree,
    required this.genericCalendarUsesTimeTree,
  });

  final bool localIntelligence;
  final bool timeTree;
  final bool genericCalendarUsesTimeTree;

  factory PrivacyIntelligenceIntegrationStatus.fromJson(Map<String, Object?> json) {
    return PrivacyIntelligenceIntegrationStatus(
      localIntelligence: _requiredBool(json, 'local_intelligence'),
      timeTree: _requiredBool(json, 'timetree'),
      genericCalendarUsesTimeTree: _requiredBool(json, 'generic_calendar_uses_timetree'),
    );
  }
}

class PrivacyIntelligenceCalendar {
  const PrivacyIntelligenceCalendar({required this.id, required this.name});

  final String id;
  final String name;

  factory PrivacyIntelligenceCalendar.fromJson(Map<String, Object?> json) => PrivacyIntelligenceCalendar(
        id: _requiredString(json, 'id'),
        name: _requiredString(json, 'name'),
      );
}

class PrivacyIntelligenceEventQuery {
  PrivacyIntelligenceEventQuery({
    this.calendarId,
    this.query,
    this.startAt,
    this.endAt,
    this.limit = 50,
  }) {
    if (calendarId != null) _requireIdentifier(calendarId!, 'calendar_id');
    if (query != null) _requireBoundedText(query!, 'query', 300, allowEmpty: true);
    if (limit < 1 || limit > 200) throw ArgumentError.value(limit, 'limit', 'must be between 1 and 200');
    if (startAt != null && endAt != null && !endAt!.isAfter(startAt!)) {
      throw ArgumentError('endAt must be after startAt');
    }
  }

  final String? calendarId;
  final String? query;
  final DateTime? startAt;
  final DateTime? endAt;
  final int limit;

  Map<String, String> toQueryParameters() => <String, String>{
        if (calendarId != null) 'calendar_id': calendarId!,
        if (query != null && query!.isNotEmpty) 'query': query!,
        if (startAt != null) 'start_at': _wireDateTime(startAt!),
        if (endAt != null) 'end_at': _wireDateTime(endAt!),
        'limit': limit.toString(),
      };
}

class PrivacyIntelligenceEvent {
  PrivacyIntelligenceEvent({
    required this.uuid,
    required this.calendarId,
    required this.title,
    required this.allDay,
    required this.startAt,
    required this.endAt,
    required this.startTimezone,
    required this.endTimezone,
    required List<Object?> recurrences,
    this.authorId,
    this.parentId,
    this.deactivatedAt,
    this.location,
    this.note,
  }) : recurrences = List<Object?>.unmodifiable(recurrences);

  final String uuid;
  final String calendarId;
  final String title;
  final bool allDay;
  final DateTime startAt;
  final DateTime endAt;
  final String startTimezone;
  final String endTimezone;
  final List<Object?> recurrences;
  final int? authorId;
  final String? parentId;
  final int? deactivatedAt;
  final String? location;
  final String? note;

  bool get isRecurring => recurrences.isNotEmpty || parentId != null;
  bool get isDeleted => deactivatedAt != null;

  factory PrivacyIntelligenceEvent.fromJson(Map<String, Object?> json) => PrivacyIntelligenceEvent(
        uuid: _requiredString(json, 'uuid'),
        calendarId: _requiredString(json, 'calendar_id'),
        title: _requiredString(json, 'title'),
        allDay: _requiredBool(json, 'all_day'),
        startAt: _requiredDateTime(json, 'start_at'),
        endAt: _requiredDateTime(json, 'end_at'),
        startTimezone: _optionalString(json, 'start_timezone') ?? 'UTC',
        endTimezone: _optionalString(json, 'end_timezone') ?? 'UTC',
        recurrences: _optionalList(json, 'recurrences') ?? const <Object?>[],
        authorId: _optionalInt(json, 'author_id'),
        parentId: _optionalString(json, 'parent_id'),
        deactivatedAt: _optionalInt(json, 'deactivated_at'),
        location: _optionalString(json, 'location'),
        note: _optionalString(json, 'note'),
      );
}

class PrivacyIntelligenceStructuredSuggestion {
  const PrivacyIntelligenceStructuredSuggestion({
    required this.suggestedType,
    required this.title,
    required this.sourceRef,
    required this.supportingExcerpt,
    required this.uncertainty,
    this.description,
    this.proposedTimeText,
    this.startAt,
    this.endAt,
    this.timezone,
  });

  final PrivacyIntelligenceSuggestionType suggestedType;
  final String title;
  final String? description;
  final String? proposedTimeText;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? timezone;
  final String sourceRef;
  final String supportingExcerpt;
  final double uncertainty;

  factory PrivacyIntelligenceStructuredSuggestion.fromJson(Map<String, Object?> json) {
    final reviewState = _requiredString(json, 'review_state');
    if (reviewState != 'pending') throw const FormatException('invalid field: review_state');
    final uncertainty = _requiredDouble(json, 'uncertainty');
    if (uncertainty < 0 || uncertainty > 1) throw const FormatException('invalid field: uncertainty');
    final startAt = _optionalDateTime(json, 'start_at');
    final endAt = _optionalDateTime(json, 'end_at');
    if (startAt != null && endAt != null && !endAt.isAfter(startAt)) {
      throw const FormatException('invalid field: end_at');
    }
    return PrivacyIntelligenceStructuredSuggestion(
      suggestedType: _suggestionType(_requiredString(json, 'suggested_type')),
      title: _requiredString(json, 'title'),
      description: _optionalString(json, 'description'),
      proposedTimeText: _optionalString(json, 'proposed_time_text'),
      startAt: startAt,
      endAt: endAt,
      timezone: _optionalString(json, 'timezone'),
      sourceRef: _requiredString(json, 'source_ref'),
      supportingExcerpt: _requiredString(json, 'supporting_excerpt'),
      uncertainty: uncertainty,
    );
  }
}

class PrivacyIntelligenceExtractionRequest {
  PrivacyIntelligenceExtractionRequest({
    required this.sourceRef,
    required this.sourceKind,
    required this.authorizationBasis,
    required this.text,
    required this.timezone,
    required this.now,
  }) {
    _requireBoundedText(sourceRef, 'sourceRef', 160);
    _requireBoundedText(text, 'text', 12000);
    _requireBoundedText(timezone, 'timezone', 64);
    final conversation = sourceKind == PrivacyIntelligenceSourceKind.consentedConversation;
    if (conversation != (authorizationBasis == PrivacyIntelligenceAuthorizationBasis.participantsConsented)) {
      throw ArgumentError('source kind and authorization basis do not match');
    }
  }

  final String sourceRef;
  final PrivacyIntelligenceSourceKind sourceKind;
  final PrivacyIntelligenceAuthorizationBasis authorizationBasis;
  final String text;
  final String timezone;
  final DateTime now;

  Map<String, Object?> toJson() => <String, Object?>{
        'source_ref': sourceRef,
        'source_kind': sourceKind.wireName,
        'authorization_basis': authorizationBasis.wireName,
        'text': text,
        'timezone': timezone,
        'now': _wireDateTime(now),
      };
}

class PrivacyIntelligenceExtractionResponse {
  PrivacyIntelligenceExtractionResponse(
      {required List<PrivacyIntelligenceStructuredSuggestion> suggestions, required this.extractor})
      : suggestions = List<PrivacyIntelligenceStructuredSuggestion>.unmodifiable(suggestions);

  final List<PrivacyIntelligenceStructuredSuggestion> suggestions;
  final String extractor;

  factory PrivacyIntelligenceExtractionResponse.fromJson(Map<String, Object?> json) {
    return PrivacyIntelligenceExtractionResponse(
      suggestions: _requiredObjectList(json, 'suggestions')
          .map(PrivacyIntelligenceStructuredSuggestion.fromJson)
          .toList(growable: false),
      extractor: _requiredString(json, 'extractor'),
    );
  }
}

class PrivacyIntelligenceLocalTaskContext {
  PrivacyIntelligenceLocalTaskContext({
    required this.taskId,
    required this.title,
    this.dueAt,
    this.projectName,
    this.inToday = false,
  }) {
    _requireBoundedText(taskId, 'taskId', 160);
    _requireBoundedText(title, 'title', 300);
    if (projectName != null) _requireBoundedText(projectName!, 'projectName', 200);
  }

  final String taskId;
  final String title;
  final DateTime? dueAt;
  final String? projectName;
  final bool inToday;

  Map<String, Object?> toJson() => <String, Object?>{
        'task_id': taskId,
        'title': title,
        if (dueAt != null) 'due_at': _wireDateTime(dueAt!),
        if (projectName != null) 'project_name': projectName,
        'in_today': inToday,
      };
}

class PrivacyIntelligenceAssistantRequest {
  PrivacyIntelligenceAssistantRequest({
    required this.message,
    required this.timezone,
    required this.now,
    List<PrivacyIntelligenceLocalTaskContext> openTasks = const [],
  }) : openTasks = List<PrivacyIntelligenceLocalTaskContext>.unmodifiable(openTasks) {
    _requireBoundedText(message, 'message', 3000);
    _requireBoundedText(timezone, 'timezone', 64);
    if (openTasks.length > 250) throw ArgumentError.value(openTasks.length, 'openTasks', 'must not exceed 250');
  }

  final String message;
  final String timezone;
  final DateTime now;
  final List<PrivacyIntelligenceLocalTaskContext> openTasks;

  Map<String, Object?> toJson() => <String, Object?>{
        'message': message,
        'timezone': timezone,
        'now': _wireDateTime(now),
        'open_tasks': openTasks.map((task) => task.toJson()).toList(growable: false),
      };
}

class PrivacyIntelligenceProactiveEvaluationRequest {
  PrivacyIntelligenceProactiveEvaluationRequest({
    required this.timezone,
    required this.now,
    List<PrivacyIntelligenceLocalTaskContext> openTasks = const [],
  }) : openTasks = List<PrivacyIntelligenceLocalTaskContext>.unmodifiable(openTasks) {
    _requireBoundedText(timezone, 'timezone', 64);
    if (openTasks.length > 250) throw ArgumentError.value(openTasks.length, 'openTasks', 'must not exceed 250');
  }

  final String timezone;
  final DateTime now;
  final List<PrivacyIntelligenceLocalTaskContext> openTasks;

  Map<String, Object?> toJson() => <String, Object?>{
        'timezone': timezone,
        'now': _wireDateTime(now),
        'open_tasks': openTasks.map((task) => task.toJson()).toList(growable: false),
      };
}

class PrivacyIntelligenceProactiveEvaluationResponse {
  PrivacyIntelligenceProactiveEvaluationResponse({
    required List<PrivacyIntelligenceStructuredSuggestion> suggestions,
    required this.usedLocalTasks,
    required this.usedTimeTree,
    required this.calendarStatus,
  }) : suggestions = List<PrivacyIntelligenceStructuredSuggestion>.unmodifiable(suggestions) {
    if (!const {'not_configured', 'available', 'unavailable'}.contains(calendarStatus)) {
      throw const FormatException('invalid field: calendar_status');
    }
  }

  final List<PrivacyIntelligenceStructuredSuggestion> suggestions;
  final bool usedLocalTasks;
  final bool usedTimeTree;
  final String calendarStatus;

  factory PrivacyIntelligenceProactiveEvaluationResponse.fromJson(Map<String, Object?> json) {
    return PrivacyIntelligenceProactiveEvaluationResponse(
      suggestions: _requiredObjectList(json, 'suggestions')
          .map(PrivacyIntelligenceStructuredSuggestion.fromJson)
          .toList(growable: false),
      usedLocalTasks: _requiredBool(json, 'used_local_tasks'),
      usedTimeTree: _requiredBool(json, 'used_timetree'),
      calendarStatus: _requiredString(json, 'calendar_status'),
    );
  }
}

class PrivacyIntelligenceCalendarEventDraft {
  PrivacyIntelligenceCalendarEventDraft({
    required this.title,
    required this.startAt,
    required this.endAt,
    required this.startTimezone,
    required this.endTimezone,
    this.allDay = false,
    this.note,
    this.location,
    this.labelId,
    this.category = 1,
    List<int> attendees = const [],
    List<String> recurrences = const [],
    List<Object?> alerts = const [],
    List<String> fileUuids = const [],
  })  : attendees = List<int>.unmodifiable(attendees),
        recurrences = List<String>.unmodifiable(recurrences),
        alerts = List<Object?>.unmodifiable(alerts),
        fileUuids = List<String>.unmodifiable(fileUuids) {
    _requireBoundedText(title, 'title', 300);
    _requireBoundedText(startTimezone, 'startTimezone', 64);
    _requireBoundedText(endTimezone, 'endTimezone', 64);
    if (note != null) _requireBoundedText(note!, 'note', 4000, allowEmpty: true);
    if (location != null) _requireBoundedText(location!, 'location', 500, allowEmpty: true);
    if (labelId != null && (labelId! < 1 || labelId! > 10)) throw ArgumentError.value(labelId, 'labelId');
    if (endAt.isBefore(startAt) || (!allDay && endAt.isAtSameMomentAs(startAt))) {
      throw ArgumentError('event end must be after its start');
    }
    if (attendees.length > 100 || recurrences.length > 20 || alerts.length > 20 || fileUuids.length > 20) {
      throw ArgumentError('calendar event collection exceeds its limit');
    }
  }

  final String title;
  final bool allDay;
  final DateTime startAt;
  final DateTime endAt;
  final String startTimezone;
  final String endTimezone;
  final String? note;
  final String? location;
  final int? labelId;
  final int category;
  final List<int> attendees;
  final List<String> recurrences;
  final List<Object?> alerts;
  final List<String> fileUuids;

  Map<String, Object?> toJson() => <String, Object?>{
        'title': title,
        'all_day': allDay,
        'start_at': _wireDateTime(startAt),
        'end_at': _wireDateTime(endAt),
        'start_timezone': startTimezone,
        'end_timezone': endTimezone,
        if (note != null) 'note': note,
        if (location != null) 'location': location,
        if (labelId != null) 'label_id': labelId,
        'category': category,
        'attendees': attendees,
        'recurrences': recurrences,
        'alerts': alerts,
        'file_uuids': fileUuids,
      };

  factory PrivacyIntelligenceCalendarEventDraft.fromJson(Map<String, Object?> json) {
    return PrivacyIntelligenceCalendarEventDraft(
      title: _requiredString(json, 'title'),
      allDay: _optionalBool(json, 'all_day') ?? false,
      startAt: _requiredDateTime(json, 'start_at'),
      endAt: _requiredDateTime(json, 'end_at'),
      startTimezone: _requiredString(json, 'start_timezone'),
      endTimezone: _requiredString(json, 'end_timezone'),
      note: _optionalString(json, 'note'),
      location: _optionalString(json, 'location'),
      labelId: _optionalInt(json, 'label_id'),
      category: _optionalInt(json, 'category') ?? 1,
      attendees: _optionalIntList(json, 'attendees') ?? const <int>[],
      recurrences: _optionalStringList(json, 'recurrences') ?? const <String>[],
      alerts: _optionalList(json, 'alerts') ?? const <Object?>[],
      fileUuids: _optionalStringList(json, 'file_uuids') ?? const <String>[],
    );
  }
}

class PrivacyIntelligenceCalendarEventPatch {
  PrivacyIntelligenceCalendarEventPatch({
    this.title,
    this.allDay,
    this.startAt,
    this.endAt,
    this.startTimezone,
    this.endTimezone,
    this.note,
    this.clearNote = false,
    this.location,
    this.clearLocation = false,
    this.labelId,
    this.clearLabelId = false,
    this.category,
    this.attendees,
    this.recurrences,
    this.alerts,
    this.fileUuids,
  }) {
    if (!hasChanges) throw ArgumentError('calendar patch must contain a change');
    if (note != null && clearNote) throw ArgumentError('note cannot be set and cleared');
    if (location != null && clearLocation) throw ArgumentError('location cannot be set and cleared');
    if (labelId != null && clearLabelId) throw ArgumentError('labelId cannot be set and cleared');
    if (title != null) _requireBoundedText(title!, 'title', 300);
    if (startTimezone != null) _requireBoundedText(startTimezone!, 'startTimezone', 64);
    if (endTimezone != null) _requireBoundedText(endTimezone!, 'endTimezone', 64);
    if (note != null) _requireBoundedText(note!, 'note', 4000, allowEmpty: true);
    if (location != null) _requireBoundedText(location!, 'location', 500, allowEmpty: true);
    if (labelId != null && (labelId! < 1 || labelId! > 10)) throw ArgumentError.value(labelId, 'labelId');
  }

  final String? title;
  final bool? allDay;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? startTimezone;
  final String? endTimezone;
  final String? note;
  final bool clearNote;
  final String? location;
  final bool clearLocation;
  final int? labelId;
  final bool clearLabelId;
  final int? category;
  final List<int>? attendees;
  final List<String>? recurrences;
  final List<Object?>? alerts;
  final List<String>? fileUuids;

  bool get hasChanges =>
      title != null ||
      allDay != null ||
      startAt != null ||
      endAt != null ||
      startTimezone != null ||
      endTimezone != null ||
      note != null ||
      clearNote ||
      location != null ||
      clearLocation ||
      labelId != null ||
      clearLabelId ||
      category != null ||
      attendees != null ||
      recurrences != null ||
      alerts != null ||
      fileUuids != null;

  Map<String, Object?> toJson() => <String, Object?>{
        if (title != null) 'title': title,
        if (allDay != null) 'all_day': allDay,
        if (startAt != null) 'start_at': _wireDateTime(startAt!),
        if (endAt != null) 'end_at': _wireDateTime(endAt!),
        if (startTimezone != null) 'start_timezone': startTimezone,
        if (endTimezone != null) 'end_timezone': endTimezone,
        if (note != null || clearNote) 'note': note,
        if (location != null || clearLocation) 'location': location,
        if (labelId != null || clearLabelId) 'label_id': labelId,
        if (category != null) 'category': category,
        if (attendees != null) 'attendees': attendees,
        if (recurrences != null) 'recurrences': recurrences,
        if (alerts != null) 'alerts': alerts,
        if (fileUuids != null) 'file_uuids': fileUuids,
      };

  factory PrivacyIntelligenceCalendarEventPatch.fromJson(Map<String, Object?> json) {
    if (json.isEmpty) throw const FormatException('invalid calendar patch');
    const nonNullableWhenPresent = <String>{
      'title',
      'all_day',
      'start_at',
      'end_at',
      'start_timezone',
      'end_timezone',
      'category',
      'attendees',
      'recurrences',
      'alerts',
      'file_uuids',
    };
    if (nonNullableWhenPresent.any((field) => json.containsKey(field) && json[field] == null)) {
      throw const FormatException('invalid nullable calendar patch field');
    }
    return PrivacyIntelligenceCalendarEventPatch(
      title: _optionalString(json, 'title'),
      allDay: _optionalBool(json, 'all_day'),
      startAt: _optionalDateTime(json, 'start_at'),
      endAt: _optionalDateTime(json, 'end_at'),
      startTimezone: _optionalString(json, 'start_timezone'),
      endTimezone: _optionalString(json, 'end_timezone'),
      note: _optionalString(json, 'note'),
      clearNote: json.containsKey('note') && json['note'] == null,
      location: _optionalString(json, 'location'),
      clearLocation: json.containsKey('location') && json['location'] == null,
      labelId: _optionalInt(json, 'label_id'),
      clearLabelId: json.containsKey('label_id') && json['label_id'] == null,
      category: _optionalInt(json, 'category'),
      attendees: _optionalIntList(json, 'attendees'),
      recurrences: _optionalStringList(json, 'recurrences'),
      alerts: _optionalList(json, 'alerts'),
      fileUuids: _optionalStringList(json, 'file_uuids'),
    );
  }
}

class PrivacyIntelligenceCalendarOperationRequest {
  PrivacyIntelligenceCalendarOperationRequest({
    required this.kind,
    required this.idempotencyKey,
    this.calendarId,
    this.eventUuid,
    this.event,
    this.changes,
    this.recurrenceScope,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(idempotencyKey)) {
      throw ArgumentError.value(idempotencyKey, 'idempotencyKey', 'invalid format');
    }
    if (calendarId != null) _requireIdentifier(calendarId!, 'calendarId');
    if (eventUuid != null) _requireIdentifier(eventUuid!, 'eventUuid');
    switch (kind) {
      case PrivacyIntelligenceCalendarOperationKind.create:
        if (event == null || eventUuid != null || changes != null || recurrenceScope != null) {
          throw ArgumentError('create requires only an event');
        }
      case PrivacyIntelligenceCalendarOperationKind.update:
        if (eventUuid == null || changes == null || event != null) {
          throw ArgumentError('update requires an event UUID and changes');
        }
      case PrivacyIntelligenceCalendarOperationKind.delete:
        if (eventUuid == null || event != null || changes != null) {
          throw ArgumentError('delete requires only an event UUID');
        }
    }
  }

  final PrivacyIntelligenceCalendarOperationKind kind;
  final String idempotencyKey;
  final String? calendarId;
  final String? eventUuid;
  final PrivacyIntelligenceCalendarEventDraft? event;
  final PrivacyIntelligenceCalendarEventPatch? changes;
  final PrivacyIntelligenceEditScope? recurrenceScope;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.wireName,
        'idempotency_key': idempotencyKey,
        if (calendarId != null) 'calendar_id': calendarId,
        if (eventUuid != null) 'event_uuid': eventUuid,
        if (event != null) 'event': event!.toJson(),
        if (changes != null) 'changes': changes!.toJson(),
        if (recurrenceScope != null) 'recurrence_scope': recurrenceScope!.wireName,
      };
}

class PrivacyIntelligenceCalendarOperationPreview {
  PrivacyIntelligenceCalendarOperationPreview({
    required this.operationId,
    required this.kind,
    required this.calendarId,
    required this.calendarName,
    required this.title,
    required this.startAt,
    required this.endAt,
    required this.timezone,
    required this.allDay,
    required this.recurrenceScope,
    required List<String> changes,
    required this.expiresAt,
    this.eventUuid,
  }) : changes = List<String>.unmodifiable(changes);

  final String operationId;
  final PrivacyIntelligenceCalendarOperationKind kind;
  final String calendarId;
  final String calendarName;
  final String? eventUuid;
  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final String timezone;
  final bool allDay;
  final PrivacyIntelligencePreviewRecurrenceScope recurrenceScope;
  final List<String> changes;
  final DateTime expiresAt;

  factory PrivacyIntelligenceCalendarOperationPreview.fromJson(Map<String, Object?> json) {
    return PrivacyIntelligenceCalendarOperationPreview(
      operationId: _requiredOperationId(json, 'operation_id'),
      kind: _operationKind(_requiredString(json, 'kind')),
      calendarId: _requiredString(json, 'calendar_id'),
      calendarName: _requiredString(json, 'calendar_name'),
      eventUuid: _optionalString(json, 'event_uuid'),
      title: _requiredString(json, 'title'),
      startAt: _requiredDateTime(json, 'start_at'),
      endAt: _requiredDateTime(json, 'end_at'),
      timezone: _requiredString(json, 'timezone'),
      allDay: _requiredBool(json, 'all_day'),
      recurrenceScope: _previewScope(_requiredString(json, 'recurrence_scope')),
      changes: _optionalStringList(json, 'changes') ?? const <String>[],
      expiresAt: _requiredDateTime(json, 'expires_at'),
    );
  }
}

class PrivacyIntelligenceCalendarOperationOutcome {
  const PrivacyIntelligenceCalendarOperationOutcome({
    required this.operationId,
    required this.status,
    required this.message,
    this.event,
  });

  final String operationId;
  final PrivacyIntelligenceOperationStatus status;
  final String message;
  final PrivacyIntelligenceEvent? event;

  bool get requiresReconciliation => status == PrivacyIntelligenceOperationStatus.uncertain;

  factory PrivacyIntelligenceCalendarOperationOutcome.fromJson(Map<String, Object?> json) {
    final eventJson = _optionalObject(json, 'event');
    return PrivacyIntelligenceCalendarOperationOutcome(
      operationId: _requiredOperationId(json, 'operation_id'),
      status: _operationStatus(_requiredString(json, 'status')),
      message: _requiredString(json, 'message'),
      event: eventJson == null ? null : PrivacyIntelligenceEvent.fromJson(eventJson),
    );
  }
}

class PrivacyIntelligenceCalendarWriteProposal {
  PrivacyIntelligenceCalendarWriteProposal({
    required this.kind,
    required this.explanation,
    this.calendarId,
    this.eventUuid,
    this.event,
    this.changes,
    this.recurrenceScope,
  }) {
    _requireBoundedText(explanation, 'explanation', 500);
    if (calendarId != null) _requireIdentifier(calendarId!, 'calendarId');
    if (eventUuid != null) _requireIdentifier(eventUuid!, 'eventUuid');
    switch (kind) {
      case PrivacyIntelligenceCalendarOperationKind.create:
        if (event == null || eventUuid != null || changes != null || recurrenceScope != null) {
          throw const FormatException('invalid create calendar proposal');
        }
      case PrivacyIntelligenceCalendarOperationKind.update:
        if (eventUuid == null || changes == null || event != null) {
          throw const FormatException('invalid update calendar proposal');
        }
      case PrivacyIntelligenceCalendarOperationKind.delete:
        if (eventUuid == null || event != null || changes != null) {
          throw const FormatException('invalid delete calendar proposal');
        }
    }
  }

  final PrivacyIntelligenceCalendarOperationKind kind;
  final String? calendarId;
  final String? eventUuid;
  final PrivacyIntelligenceCalendarEventDraft? event;
  final PrivacyIntelligenceCalendarEventPatch? changes;
  final PrivacyIntelligenceEditScope? recurrenceScope;
  final String explanation;

  factory PrivacyIntelligenceCalendarWriteProposal.fromJson(Map<String, Object?> json) {
    final eventJson = _optionalObject(json, 'event');
    final changesJson = _optionalObject(json, 'changes');
    return PrivacyIntelligenceCalendarWriteProposal(
      kind: _operationKind(_requiredString(json, 'kind')),
      calendarId: _optionalString(json, 'calendar_id'),
      eventUuid: _optionalString(json, 'event_uuid'),
      event: eventJson == null ? null : PrivacyIntelligenceCalendarEventDraft.fromJson(eventJson),
      changes: changesJson == null ? null : PrivacyIntelligenceCalendarEventPatch.fromJson(changesJson),
      recurrenceScope: _optionalEditScope(json, 'recurrence_scope'),
      explanation: _requiredString(json, 'explanation'),
    );
  }

  PrivacyIntelligenceCalendarOperationRequest prepareRequest({required String idempotencyKey}) {
    return PrivacyIntelligenceCalendarOperationRequest(
      kind: kind,
      idempotencyKey: idempotencyKey,
      calendarId: calendarId,
      eventUuid: eventUuid,
      event: event,
      changes: changes,
      recurrenceScope: recurrenceScope,
    );
  }
}

class PrivacyIntelligenceAssistantResponse {
  PrivacyIntelligenceAssistantResponse({
    required this.message,
    required List<PrivacyIntelligenceEvent> events,
    required List<PrivacyIntelligenceStructuredSuggestion> taskSuggestions,
    required this.usedLocalTasks,
    required this.usedTimeTree,
    this.calendarProposal,
  })  : events = List<PrivacyIntelligenceEvent>.unmodifiable(events),
        taskSuggestions = List<PrivacyIntelligenceStructuredSuggestion>.unmodifiable(taskSuggestions);

  final String message;
  final List<PrivacyIntelligenceEvent> events;
  final List<PrivacyIntelligenceStructuredSuggestion> taskSuggestions;
  final PrivacyIntelligenceCalendarWriteProposal? calendarProposal;
  final bool usedLocalTasks;
  final bool usedTimeTree;

  factory PrivacyIntelligenceAssistantResponse.fromJson(Map<String, Object?> json) {
    final proposalJson = _optionalObject(json, 'calendar_proposal');
    return PrivacyIntelligenceAssistantResponse(
      message: _requiredString(json, 'message'),
      events: _requiredObjectList(json, 'events').map(PrivacyIntelligenceEvent.fromJson).toList(growable: false),
      taskSuggestions: _requiredObjectList(json, 'task_suggestions')
          .map(PrivacyIntelligenceStructuredSuggestion.fromJson)
          .toList(growable: false),
      calendarProposal: proposalJson == null ? null : PrivacyIntelligenceCalendarWriteProposal.fromJson(proposalJson),
      usedLocalTasks: _requiredBool(json, 'used_local_tasks'),
      usedTimeTree: _requiredBool(json, 'used_timetree'),
    );
  }
}

String _wireDateTime(DateTime value) => value.toUtc().toIso8601String();

void _requireBoundedText(String value, String name, int maxLength, {bool allowEmpty = false}) {
  if ((!allowEmpty && value.trim().isEmpty) || value.length > maxLength) {
    throw ArgumentError.value('<redacted>', name, 'invalid length');
  }
}

void _requireIdentifier(String value, String name) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw ArgumentError.value('<redacted>', name, 'invalid identifier');
  }
}

String _requiredOperationId(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) throw FormatException('invalid field: $key');
  return value;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) throw FormatException('invalid field: $key');
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('invalid field: $key');
  return value;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('invalid field: $key');
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! bool) throw FormatException('invalid field: $key');
  return value;
}

int? _optionalInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int) throw FormatException('invalid field: $key');
  return value;
}

double _requiredDouble(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num) throw FormatException('invalid field: $key');
  return value.toDouble();
}

DateTime _requiredDateTime(Map<String, Object?> json, String key) {
  final parsed = _parseDateTime(json[key], key);
  if (parsed == null) throw FormatException('invalid field: $key');
  return parsed;
}

DateTime? _optionalDateTime(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  return _parseDateTime(value, key);
}

DateTime? _parseDateTime(Object? value, String key) {
  if (value is! String || !RegExp(r'(?:Z|[+-]\d\d:\d\d)$').hasMatch(value)) {
    throw FormatException('invalid field: $key');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('invalid field: $key');
  return parsed.toUtc();
}

List<Object?>? _optionalList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! List) throw FormatException('invalid field: $key');
  return List<Object?>.from(value);
}

List<String>? _optionalStringList(Map<String, Object?> json, String key) {
  final values = _optionalList(json, key);
  if (values == null) return null;
  if (values.any((value) => value is! String)) throw FormatException('invalid field: $key');
  return values.cast<String>();
}

List<int>? _optionalIntList(Map<String, Object?> json, String key) {
  final values = _optionalList(json, key);
  if (values == null) return null;
  if (values.any((value) => value is! int)) throw FormatException('invalid field: $key');
  return values.cast<int>();
}

Map<String, Object?>? _optionalObject(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map) throw FormatException('invalid field: $key');
  return _stringObjectMap(value, key);
}

List<Map<String, Object?>> _requiredObjectList(Map<String, Object?> json, String key) {
  final values = _optionalList(json, key);
  if (values == null) throw FormatException('invalid field: $key');
  return values.map((value) {
    if (value is! Map) throw FormatException('invalid field: $key');
    return _stringObjectMap(value, key);
  }).toList(growable: false);
}

Map<String, Object?> _stringObjectMap(Map<dynamic, dynamic> value, String key) {
  if (value.keys.any((item) => item is! String)) throw FormatException('invalid field: $key');
  return value.map((mapKey, mapValue) => MapEntry(mapKey as String, mapValue));
}

PrivacyIntelligenceSuggestionType _suggestionType(String value) {
  return PrivacyIntelligenceSuggestionType.values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw const FormatException('invalid field: suggested_type'),
  );
}

PrivacyIntelligenceCalendarOperationKind _operationKind(String value) {
  return PrivacyIntelligenceCalendarOperationKind.values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw const FormatException('invalid field: kind'),
  );
}

PrivacyIntelligenceOperationStatus _operationStatus(String value) {
  return PrivacyIntelligenceOperationStatus.values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw const FormatException('invalid field: status'),
  );
}

PrivacyIntelligencePreviewRecurrenceScope _previewScope(String value) {
  return PrivacyIntelligencePreviewRecurrenceScope.values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw const FormatException('invalid field: recurrence_scope'),
  );
}

PrivacyIntelligenceEditScope? _optionalEditScope(Map<String, Object?> json, String key) {
  final value = _optionalString(json, key);
  if (value == null) return null;
  return PrivacyIntelligenceEditScope.values.firstWhere(
    (item) => item.wireName == value,
    orElse: () => throw FormatException('invalid field: $key'),
  );
}
