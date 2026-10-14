class PrivacyWriteResult<T> {
  const PrivacyWriteResult.ok(this.value) : error = null;
  const PrivacyWriteResult.failed(this.error) : value = null;

  final T? value;
  final String? error;
  bool get ok => error == null;
}

enum PrivacyRetentionChoice { sessionOnly, hours24, days7, untilDeleted }

PrivacyRetentionChoice? privacyRetentionFromName(String? name) {
  for (final choice in PrivacyRetentionChoice.values) {
    if (choice.name == name) return choice;
  }
  return null;
}

class PrivacySessionRecord {
  const PrivacySessionRecord({
    required this.localId,
    required this.captureId,
    required this.startedAt,
    required this.purpose,
    required this.ownerPurpose,
    required this.consentBasis,
    String? wireConsentBasis,
    required this.protocolVersion,
    required this.policyRevision,
    required this.outcome,
    required this.incomplete,
    this.stoppedAt,
    this.completedAt,
    this.consentAssertedAt,
    this.configuredPurpose,
    this.captureOrigin = 'phone_manual_capture',
    this.failureClass,
    this.retentionChoice,
    this.expiresAt,
    this.deleteOnNextLaunch = false,
  }) : wireConsentBasis = wireConsentBasis ?? consentBasis;

  final String localId;
  final String captureId;
  final DateTime startedAt;
  final DateTime? stoppedAt;
  final DateTime? completedAt;
  final String purpose;
  final String ownerPurpose;

  /// Local assertion basis. Quick sessions use `self_only_quick_gesture`.
  final String consentBasis;

  /// Value sent to the current backend contract.
  final String wireConsentBasis;
  final DateTime? consentAssertedAt;
  final String? configuredPurpose;
  final String captureOrigin;
  final int protocolVersion;
  final int policyRevision;
  final String outcome;
  final bool incomplete;
  final String? failureClass;
  final String? retentionChoice;
  final DateTime? expiresAt;
  final bool deleteOnNextLaunch;

  bool get isActive => outcome == 'authorizing' || outcome == 'recording' || outcome == 'finalizing';

  PrivacySessionRecord copyWith({
    String? outcome,
    bool? incomplete,
    DateTime? stoppedAt,
    DateTime? completedAt,
    String? failureClass,
    String? retentionChoice,
    DateTime? expiresAt,
    bool? deleteOnNextLaunch,
    bool clearExpires = false,
  }) {
    return PrivacySessionRecord(
      localId: localId,
      captureId: captureId,
      startedAt: startedAt,
      purpose: purpose,
      ownerPurpose: ownerPurpose,
      consentBasis: consentBasis,
      wireConsentBasis: wireConsentBasis,
      protocolVersion: protocolVersion,
      policyRevision: policyRevision,
      outcome: outcome ?? this.outcome,
      incomplete: incomplete ?? this.incomplete,
      stoppedAt: stoppedAt ?? this.stoppedAt,
      completedAt: completedAt ?? this.completedAt,
      consentAssertedAt: consentAssertedAt,
      configuredPurpose: configuredPurpose,
      captureOrigin: captureOrigin,
      failureClass: failureClass ?? this.failureClass,
      retentionChoice: retentionChoice ?? this.retentionChoice,
      expiresAt: clearExpires ? null : (expiresAt ?? this.expiresAt),
      deleteOnNextLaunch: deleteOnNextLaunch ?? this.deleteOnNextLaunch,
    );
  }

  Map<String, Object?> toJson() => {
        'local_id': localId,
        'capture_id': captureId,
        'started_at': startedAt.toUtc().toIso8601String(),
        'stopped_at': stoppedAt?.toUtc().toIso8601String(),
        'completed_at': completedAt?.toUtc().toIso8601String(),
        'purpose': purpose,
        'owner_purpose': ownerPurpose,
        'consent_basis': consentBasis,
        'wire_consent_basis': wireConsentBasis,
        'consent_asserted_at': consentAssertedAt?.toUtc().toIso8601String(),
        'configured_purpose': configuredPurpose,
        'capture_origin': captureOrigin,
        'protocol_version': protocolVersion,
        'policy_revision': policyRevision,
        'outcome': outcome,
        'incomplete': incomplete,
        'failure_class': failureClass,
        'retention_choice': retentionChoice,
        'expires_at': expiresAt?.toUtc().toIso8601String(),
        'delete_on_next_launch': deleteOnNextLaunch,
      };

  static PrivacySessionRecord fromJson(Map<String, dynamic> json) {
    return PrivacySessionRecord(
      localId: json['local_id'] as String,
      captureId: json['capture_id'] as String,
      startedAt: DateTime.parse(json['started_at'] as String),
      stoppedAt: _time(json['stopped_at']),
      completedAt: _time(json['completed_at']),
      purpose: json['purpose'] as String? ?? 'personal_memory',
      ownerPurpose: json['owner_purpose'] as String? ?? '',
      consentBasis: json['consent_basis'] as String? ?? 'self_only',
      wireConsentBasis: json['wire_consent_basis'] as String?,
      consentAssertedAt: _time(json['consent_asserted_at']),
      configuredPurpose: json['configured_purpose'] as String?,
      captureOrigin: json['capture_origin'] as String? ?? 'phone_manual_capture',
      protocolVersion: json['protocol_version'] as int? ?? 1,
      policyRevision: json['policy_revision'] as int? ?? 1,
      outcome: json['outcome'] as String? ?? 'interrupted',
      incomplete: json['incomplete'] as bool? ?? true,
      failureClass: json['failure_class'] as String?,
      retentionChoice: json['retention_choice'] as String?,
      expiresAt: _time(json['expires_at']),
      deleteOnNextLaunch: json['delete_on_next_launch'] as bool? ?? false,
    );
  }
}

class PrivacyChunkRecord {
  const PrivacyChunkRecord({
    required this.sessionId,
    required this.captureId,
    required this.sequence,
    required this.machineText,
    this.correction,
    this.startSeconds,
    this.endSeconds,
    this.origin = 'machine_transcription',
    this.uncertain = false,
  });

  final String sessionId;
  final String captureId;
  final int sequence;
  final String machineText;
  final String? correction;
  final double? startSeconds;
  final double? endSeconds;
  final String origin;
  final bool uncertain;

  String get displayText => (correction != null && correction!.trim().isNotEmpty) ? correction! : machineText;

  PrivacyChunkRecord copyWith({String? correction, bool clearCorrection = false}) {
    return PrivacyChunkRecord(
      sessionId: sessionId,
      captureId: captureId,
      sequence: sequence,
      machineText: machineText,
      correction: clearCorrection ? null : (correction ?? this.correction),
      startSeconds: startSeconds,
      endSeconds: endSeconds,
      origin: origin,
      uncertain: uncertain,
    );
  }

  Map<String, Object?> toJson() => {
        'session_id': sessionId,
        'capture_id': captureId,
        'sequence': sequence,
        'machine_text': machineText,
        'correction': correction,
        'start_seconds': startSeconds,
        'end_seconds': endSeconds,
        'origin': origin,
        'uncertain': uncertain,
      };

  static PrivacyChunkRecord fromJson(Map<String, dynamic> json) {
    return PrivacyChunkRecord(
      sessionId: json['session_id'] as String,
      captureId: json['capture_id'] as String,
      sequence: json['sequence'] as int,
      machineText: json['machine_text'] as String,
      correction: json['correction'] as String?,
      startSeconds: (json['start_seconds'] as num?)?.toDouble(),
      endSeconds: (json['end_seconds'] as num?)?.toDouble(),
      origin: json['origin'] as String? ?? 'machine_transcription',
      uncertain: json['uncertain'] as bool? ?? false,
    );
  }
}

class PrivacyNoteRecord {
  const PrivacyNoteRecord({
    required this.noteId,
    required this.sessionId,
    required this.text,
    required this.createdAt,
    this.origin = 'owner_note',
  });

  final String noteId;
  final String sessionId;
  final String text;
  final String origin;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'note_id': noteId,
        'session_id': sessionId,
        'text': text,
        'origin': origin,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  static PrivacyNoteRecord fromJson(Map<String, dynamic> json) {
    return PrivacyNoteRecord(
      noteId: json['note_id'] as String,
      sessionId: json['session_id'] as String,
      text: json['text'] as String,
      origin: json['origin'] as String? ?? 'owner_note',
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

class PrivacyCandidateRecord {
  const PrivacyCandidateRecord({
    required this.candidateId,
    required this.sessionId,
    required this.captureId,
    required this.sequence,
    required this.proposedText,
    required this.excerpt,
    required this.createdAt,
    this.extractionKind = 'deterministic_commitment',
    this.extractionVersion = 'deterministic-v1',
    this.origin = 'heuristic_suggestion',
    this.status = 'pending',
    this.expiresAt,
    this.tombstone = false,
    this.suggestedType = 'task',
    this.description,
    this.proposedTimeText,
    this.proposedStartAt,
    this.proposedEndAt,
    this.timezone,
    this.uncertainty,
    this.sourceRef,
    this.fingerprint,
  });

  final String candidateId;
  final String sessionId;
  final String captureId;
  final int sequence;
  final String proposedText;
  final String excerpt;
  final String extractionKind;
  final String extractionVersion;
  final String origin;
  final String status;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final bool tombstone;
  final String suggestedType;
  final String? description;
  final String? proposedTimeText;
  final DateTime? proposedStartAt;
  final DateTime? proposedEndAt;
  final String? timezone;
  final double? uncertainty;
  final String? sourceRef;
  final String? fingerprint;

  Map<String, Object?> toJson() => {
        'candidate_id': candidateId,
        'session_id': sessionId,
        'capture_id': captureId,
        'sequence': sequence,
        'proposed_text': tombstone ? '' : proposedText,
        'excerpt': tombstone ? '' : excerpt,
        'extraction_kind': extractionKind,
        'extraction_version': extractionVersion,
        'origin': origin,
        'status': status,
        'created_at': createdAt.toUtc().toIso8601String(),
        'expires_at': expiresAt?.toUtc().toIso8601String(),
        'tombstone': tombstone,
        'suggested_type': suggestedType,
        'description': tombstone ? null : description,
        'proposed_time_text': tombstone ? null : proposedTimeText,
        'proposed_start_at': tombstone ? null : proposedStartAt?.toUtc().toIso8601String(),
        'proposed_end_at': tombstone ? null : proposedEndAt?.toUtc().toIso8601String(),
        'timezone': timezone,
        'uncertainty': uncertainty,
        'source_ref': sourceRef,
        'fingerprint': fingerprint,
      };

  static PrivacyCandidateRecord fromJson(Map<String, dynamic> json) {
    return PrivacyCandidateRecord(
      candidateId: json['candidate_id'] as String,
      sessionId: json['session_id'] as String,
      captureId: json['capture_id'] as String,
      sequence: json['sequence'] as int? ?? 0,
      proposedText: json['proposed_text'] as String? ?? '',
      excerpt: json['excerpt'] as String? ?? '',
      extractionKind: json['extraction_kind'] as String? ?? 'deterministic_commitment',
      extractionVersion: json['extraction_version'] as String? ?? 'deterministic-v1',
      origin: json['origin'] as String? ?? 'heuristic_suggestion',
      status: json['status'] as String? ?? 'pending',
      createdAt: DateTime.parse(json['created_at'] as String),
      expiresAt: _time(json['expires_at']),
      tombstone: json['tombstone'] as bool? ?? false,
      suggestedType: json['suggested_type'] as String? ?? 'task',
      description: json['description'] as String?,
      proposedTimeText: json['proposed_time_text'] as String?,
      proposedStartAt: _time(json['proposed_start_at']),
      proposedEndAt: _time(json['proposed_end_at']),
      timezone: json['timezone'] as String?,
      uncertainty: (json['uncertainty'] as num?)?.toDouble(),
      sourceRef: json['source_ref'] as String?,
      fingerprint: json['fingerprint'] as String?,
    );
  }
}

class PrivacyTaskRecord {
  const PrivacyTaskRecord({
    required this.taskId,
    required this.title,
    required this.status,
    required this.creationOrigin,
    required this.createdAt,
    required this.updatedAt,
    this.note,
    this.dueAt,
    this.projectId,
    this.sourceSessionId,
    this.sourceKind,
    this.excerpt,
    this.completedAt,
    this.todayDateKey,
    this.todayRank,
  });

  final String taskId;
  final String title;
  final String? note;
  final String status;
  final DateTime? dueAt;
  final String? projectId;
  final String creationOrigin;
  final String? sourceSessionId;
  final String? sourceKind;
  final String? excerpt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final String? todayDateKey;
  final int? todayRank;

  bool get isOpen => status == 'open';

  PrivacyTaskRecord copyWith({
    String? taskId,
    String? title,
    String? note,
    bool clearNote = false,
    String? status,
    DateTime? dueAt,
    bool clearDue = false,
    String? projectId,
    bool clearProject = false,
    String? sourceSessionId,
    bool clearSource = false,
    String? sourceKind,
    String? excerpt,
    bool clearExcerpt = false,
    DateTime? updatedAt,
    DateTime? completedAt,
    bool clearCompleted = false,
    String? todayDateKey,
    int? todayRank,
    bool clearToday = false,
  }) {
    return PrivacyTaskRecord(
      taskId: taskId ?? this.taskId,
      title: title ?? this.title,
      note: clearNote ? null : (note ?? this.note),
      status: status ?? this.status,
      dueAt: clearDue ? null : (dueAt ?? this.dueAt),
      projectId: clearProject ? null : (projectId ?? this.projectId),
      creationOrigin: creationOrigin,
      sourceSessionId: clearSource ? null : (sourceSessionId ?? this.sourceSessionId),
      sourceKind: clearSource ? null : (sourceKind ?? this.sourceKind),
      excerpt: clearExcerpt ? null : (excerpt ?? this.excerpt),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      completedAt: clearCompleted ? null : (completedAt ?? this.completedAt),
      todayDateKey: clearToday ? null : (todayDateKey ?? this.todayDateKey),
      todayRank: clearToday ? null : (todayRank ?? this.todayRank),
    );
  }

  Map<String, Object?> toJson() => {
        'task_id': taskId,
        'title': title,
        'note': note,
        'status': status,
        'due_at': dueAt?.toUtc().toIso8601String(),
        'project_id': projectId,
        'creation_origin': creationOrigin,
        'source_session_id': sourceSessionId,
        'source_kind': sourceKind,
        'excerpt': excerpt,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'completed_at': completedAt?.toUtc().toIso8601String(),
        'today_date_key': todayDateKey,
        'today_rank': todayRank,
      };

  static PrivacyTaskRecord fromJson(Map<String, dynamic> json) {
    return PrivacyTaskRecord(
      taskId: json['task_id'] as String,
      title: json['title'] as String,
      note: json['note'] as String?,
      status: json['status'] as String? ?? 'open',
      dueAt: _time(json['due_at']),
      projectId: json['project_id'] as String?,
      creationOrigin: json['creation_origin'] as String? ?? 'manual',
      sourceSessionId: json['source_session_id'] as String?,
      sourceKind: json['source_kind'] as String?,
      excerpt: json['excerpt'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      completedAt: _time(json['completed_at']),
      todayDateKey: json['today_date_key'] as String?,
      todayRank: json['today_rank'] as int?,
    );
  }
}

class PrivacyHabitRecord {
  const PrivacyHabitRecord({
    required this.habitId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.archived = false,
  });

  final String habitId;
  final String title;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;

  PrivacyHabitRecord copyWith({String? title, bool? archived, DateTime? updatedAt}) => PrivacyHabitRecord(
        habitId: habitId,
        title: title ?? this.title,
        archived: archived ?? this.archived,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
        'habit_id': habitId,
        'title': title,
        'archived': archived,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  static PrivacyHabitRecord fromJson(Map<String, dynamic> json) => PrivacyHabitRecord(
        habitId: json['habit_id'] as String,
        title: json['title'] as String,
        archived: json['archived'] as bool? ?? false,
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );
}

class PrivacyHabitCompletionRecord {
  const PrivacyHabitCompletionRecord({required this.habitId, required this.dateKey, required this.completedAt});

  final String habitId;
  final String dateKey;
  final DateTime completedAt;

  Map<String, Object?> toJson() => {
        'habit_id': habitId,
        'date_key': dateKey,
        'completed_at': completedAt.toUtc().toIso8601String(),
      };

  static PrivacyHabitCompletionRecord fromJson(Map<String, dynamic> json) => PrivacyHabitCompletionRecord(
        habitId: json['habit_id'] as String,
        dateKey: json['date_key'] as String,
        completedAt: DateTime.parse(json['completed_at'] as String),
      );
}

class PrivacyProjectRecord {
  const PrivacyProjectRecord({
    required this.projectId,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.archived = false,
  });

  final String projectId;
  final String name;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;

  PrivacyProjectRecord copyWith({String? name, bool? archived, DateTime? updatedAt}) {
    return PrivacyProjectRecord(
      projectId: projectId,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      archived: archived ?? this.archived,
    );
  }

  Map<String, Object?> toJson() => {
        'project_id': projectId,
        'name': name,
        'archived': archived,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  static PrivacyProjectRecord fromJson(Map<String, dynamic> json) {
    return PrivacyProjectRecord(
      projectId: json['project_id'] as String,
      name: json['name'] as String,
      archived: json['archived'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}

class PrivacyDiagnosticRecord {
  const PrivacyDiagnosticRecord({required this.at, required this.kind, required this.state, this.closeCode});

  final DateTime at;
  final String kind;
  final String state;
  final int? closeCode;

  Map<String, Object?> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'kind': kind,
        'state': state,
        'close_code': closeCode,
      };

  static PrivacyDiagnosticRecord fromJson(Map<String, dynamic> json) {
    return PrivacyDiagnosticRecord(
      at: DateTime.parse(json['at'] as String),
      kind: json['kind'] as String,
      state: json['state'] as String,
      closeCode: json['close_code'] as int?,
    );
  }
}

class PrivacyReceiptRecord {
  const PrivacyReceiptRecord({
    required this.receiptId,
    required this.at,
    required this.scope,
    required this.sessionsDeleted,
    required this.chunksDeleted,
    required this.notesDeleted,
    required this.candidatesDeleted,
    required this.excerptsCleared,
    required this.tasksDeleted,
    required this.tasksKept,
    required this.diagnosticsCleared,
    this.localResult = 'deleted_from_this_phone',
    this.remoteResult = 'remote_deletion_unavailable',
  });

  final String receiptId;
  final DateTime at;
  final String scope;
  final String localResult;
  final String remoteResult;
  final int sessionsDeleted;
  final int chunksDeleted;
  final int notesDeleted;
  final int candidatesDeleted;
  final int excerptsCleared;
  final int tasksDeleted;
  final int tasksKept;
  final int diagnosticsCleared;

  Map<String, Object?> toJson() => {
        'receipt_id': receiptId,
        'at': at.toUtc().toIso8601String(),
        'scope': scope,
        'local_result': localResult,
        'remote_result': remoteResult,
        'sessions_deleted': sessionsDeleted,
        'chunks_deleted': chunksDeleted,
        'notes_deleted': notesDeleted,
        'candidates_deleted': candidatesDeleted,
        'excerpts_cleared': excerptsCleared,
        'tasks_deleted': tasksDeleted,
        'tasks_kept': tasksKept,
        'diagnostics_cleared': diagnosticsCleared,
      };

  static PrivacyReceiptRecord fromJson(Map<String, dynamic> json) {
    return PrivacyReceiptRecord(
      receiptId: json['receipt_id'] as String,
      at: DateTime.parse(json['at'] as String),
      scope: json['scope'] as String,
      localResult: json['local_result'] as String? ?? 'deleted_from_this_phone',
      remoteResult: json['remote_result'] as String? ?? 'remote_deletion_unavailable',
      sessionsDeleted: json['sessions_deleted'] as int? ?? 0,
      chunksDeleted: json['chunks_deleted'] as int? ?? 0,
      notesDeleted: json['notes_deleted'] as int? ?? 0,
      candidatesDeleted: json['candidates_deleted'] as int? ?? 0,
      excerptsCleared: json['excerpts_cleared'] as int? ?? 0,
      tasksDeleted: json['tasks_deleted'] as int? ?? 0,
      tasksKept: json['tasks_kept'] as int? ?? 0,
      diagnosticsCleared: json['diagnostics_cleared'] as int? ?? 0,
    );
  }
}

class PrivacyDeletionPreview {
  const PrivacyDeletionPreview({
    required this.sessionCount,
    required this.chunkCount,
    required this.noteCount,
    required this.pendingCandidateCount,
    required this.acceptedTaskCount,
    required this.excerptCount,
    required this.diagnosticCount,
    required this.remoteDeletion,
  });

  final int sessionCount;
  final int chunkCount;
  final int noteCount;
  final int pendingCandidateCount;
  final int acceptedTaskCount;
  final int excerptCount;
  final int diagnosticCount;
  final String remoteDeletion;
}

DateTime? _time(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.parse(value);
}

bool privacyTaskDueToday(DateTime? due, DateTime now) {
  if (due == null) return false;
  final local = due.toLocal();
  final clock = now.toLocal();
  return local.year == clock.year && local.month == clock.month && local.day == clock.day;
}

bool privacyTaskOverdue(DateTime? due, DateTime now) {
  if (due == null) return false;
  final clock = now.toLocal();
  final start = DateTime(clock.year, clock.month, clock.day);
  return due.toLocal().isBefore(start);
}

String privacyDateKey(DateTime value) {
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}

bool privacyTaskSelectedToday(PrivacyTaskRecord task, DateTime now) => task.todayDateKey == privacyDateKey(now);
