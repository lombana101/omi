import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omi/services/privacy_capture/privacy_action_config.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_redaction.dart';
import 'package:omi/services/privacy_capture/privacy_suggestion.dart';

class PrivacyStoreUnavailable implements Exception {
  const PrivacyStoreUnavailable();
}

class PrivacyStore {
  PrivacyStore._(this._file, this._newId, this._protect);

  final File _file;
  final String Function() _newId;
  final Future<void> Function(String path) _protect;
  Future<void> _lock = Future<void>.value();
  _Doc? _cache;

  static Future<PrivacyStore> open(
    Directory directory, {
    String Function()? newId,
    Future<void> Function(String path)? protect,
    DateTime Function()? now,
  }) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/store.json');
    if (protect != null) {
      try {
        await protect(directory.path);
      } catch (_) {
        throw const PrivacyStoreUnavailable();
      }
    }
    await _prepare(file);
    final store = PrivacyStore._(file, newId ?? _defaultId, protect ?? _noopProtect);
    try {
      await store._tx((doc) async {
        doc.diagnostics.add(PrivacyDiagnosticRecord(at: (now ?? DateTime.now)(), kind: 'store_open', state: 'off'));
        _trimDiagnostics(doc);
        return null;
      });
    } catch (_) {
      throw const PrivacyStoreUnavailable();
    }
    return store;
  }

  PrivacyRetentionChoice? get retention => _cache == null ? null : privacyRetentionFromName(_cache!.retention);

  Future<PrivacyRetentionChoice?> readRetention() async {
    final doc = await _read();
    return privacyRetentionFromName(doc.retention);
  }

  Future<PrivacyWriteResult<PrivacyRetentionChoice>> setRetention(PrivacyRetentionChoice choice, {DateTime? at}) async {
    await _tx((doc) async {
      doc.retention = choice.name;
      doc.retentionIsOwnerChoice = true;
      doc.diagnostics.add(PrivacyDiagnosticRecord(
        at: at ?? DateTime.now(),
        kind: 'retention_set',
        state: 'off',
      ));
      _trimDiagnostics(doc);
    });
    return PrivacyWriteResult.ok(choice);
  }

  Future<PrivacyWriteResult<PrivacySessionRecord>> openSession({
    required String captureId,
    required String purpose,
    required String ownerPurpose,
    required String consentBasis,
    required int protocolVersion,
    required int policyRevision,
    required DateTime at,
  }) async {
    final created = await _tx((doc) async {
      final existing = doc.sessions.where((item) => item.captureId == captureId).toList();
      if (existing.isNotEmpty) return existing.single;
      final session = PrivacySessionRecord(
        localId: _newId(),
        captureId: captureId,
        startedAt: at,
        purpose: purpose,
        ownerPurpose: ownerPurpose,
        consentBasis: consentBasis,
        consentAssertedAt: at,
        protocolVersion: protocolVersion,
        policyRevision: policyRevision,
        outcome: 'authorizing',
        incomplete: true,
        retentionChoice: doc.retention,
      );
      doc.sessions.add(session);
      return session;
    });
    return PrivacyWriteResult.ok(created);
  }

  Future<void> markRecording(String captureId) async {
    await _tx((doc) async {
      _replaceSession(doc, captureId, (session) => session.copyWith(outcome: 'recording'));
    });
  }

  Future<bool> upsertChunk({
    required String captureId,
    required int sequence,
    required String machineText,
    double? startSeconds,
    double? endSeconds,
    bool uncertain = false,
  }) async {
    return _tx((doc) async {
      final session = _find(doc, captureId);
      if (session == null) return false;
      final index = doc.chunks.indexWhere((item) => item.captureId == captureId && item.sequence == sequence);
      if (index >= 0) {
        if (doc.chunks[index].machineText != machineText) return false;
        return true;
      }
      doc.chunks.add(PrivacyChunkRecord(
        sessionId: session.localId,
        captureId: captureId,
        sequence: sequence,
        machineText: machineText,
        startSeconds: startSeconds,
        endSeconds: endSeconds,
        uncertain: uncertain,
      ));
      return true;
    });
  }

  Future<void> markTerminal({
    required String captureId,
    required String outcome,
    required bool incomplete,
    required DateTime at,
    String? failureClass,
  }) async {
    await _tx((doc) async {
      final session = _find(doc, captureId);
      if (session == null) return;
      final choice = privacyRetentionFromName(session.retentionChoice ?? doc.retention);
      DateTime? expires;
      var deleteNext = false;
      if (choice == PrivacyRetentionChoice.sessionOnly) {
        deleteNext = true;
      } else if (choice == PrivacyRetentionChoice.hours24) {
        expires = at.add(PrivacyActionConfig.hours24);
      } else if (choice == PrivacyRetentionChoice.days7) {
        expires = at.add(PrivacyActionConfig.days7);
      }
      _replaceSession(
        doc,
        captureId,
        (current) => current.copyWith(
          outcome: incomplete ? 'interrupted' : 'completed',
          incomplete: incomplete,
          stoppedAt: at,
          completedAt: incomplete ? null : at,
          failureClass: failureClass ?? outcome,
          expiresAt: expires,
          deleteOnNextLaunch: deleteNext,
          clearExpires: expires == null && !deleteNext,
        ),
      );
      doc.diagnostics.add(PrivacyDiagnosticRecord(
        at: at,
        kind: incomplete ? 'interrupted' : 'completed',
        state: incomplete ? 'interrupted' : 'completed',
      ));
      _trimDiagnostics(doc);
    });
  }

  Future<List<PrivacySessionRecord>> sessions() async {
    final doc = await _read();
    final copy = doc.sessions.toList()..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return copy;
  }

  Future<List<PrivacyChunkRecord>> chunks(String sessionId) async {
    final doc = await _read();
    final copy = doc.chunks.where((item) => item.sessionId == sessionId).toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    return copy;
  }

  Future<PrivacyWriteResult<PrivacyChunkRecord>> correctChunk({
    required String captureId,
    required int sequence,
    required String correction,
  }) async {
    final updated = await _tx((doc) async {
      final index = doc.chunks.indexWhere((item) => item.captureId == captureId && item.sequence == sequence);
      if (index < 0) return null;
      final next = doc.chunks[index].copyWith(correction: correction);
      if (next.machineText != doc.chunks[index].machineText) return null;
      doc.chunks[index] = next;
      return next;
    });
    if (updated == null) return const PrivacyWriteResult.failed('missing_chunk');
    return PrivacyWriteResult.ok(updated);
  }

  Future<PrivacyWriteResult<PrivacyNoteRecord>> addNote({
    required String sessionId,
    required String text,
    DateTime? at,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const PrivacyWriteResult.failed('empty_note');
    final note = await _tx((doc) async {
      if (!doc.sessions.any((item) => item.localId == sessionId)) return null;
      final created = PrivacyNoteRecord(
        noteId: _newId(),
        sessionId: sessionId,
        text: trimmed,
        createdAt: at ?? DateTime.now(),
      );
      doc.notes.add(created);
      return created;
    });
    if (note == null) return const PrivacyWriteResult.failed('missing_session');
    return PrivacyWriteResult.ok(note);
  }

  Future<List<PrivacyNoteRecord>> notes(String sessionId) async {
    final doc = await _read();
    return doc.notes.where((item) => item.sessionId == sessionId).toList();
  }

  Future<int> refreshSuggestions({
    required ActionSuggestionService service,
    required String sessionId,
    DateTime? at,
  }) async {
    return _tx((doc) async {
      final session = doc.sessions.where((item) => item.localId == sessionId).toList();
      if (session.isEmpty) return 0;
      final current = session.single;
      var added = 0;
      final now = at ?? DateTime.now();
      for (final chunk in doc.chunks.where((item) => item.sessionId == sessionId)) {
        for (final draft in service.extract(chunk.machineText)) {
          final exists = doc.candidates.any((item) =>
              item.sessionId == sessionId &&
              item.sequence == chunk.sequence &&
              item.proposedText.toLowerCase() == draft.text.toLowerCase());
          final tomb = doc.candidates.any((item) =>
              item.tombstone &&
              item.sessionId == sessionId &&
              item.sequence == chunk.sequence &&
              item.proposedText.isEmpty);
          if (exists || tomb) continue;
          doc.candidates.add(PrivacyCandidateRecord(
            candidateId: _newId(),
            sessionId: sessionId,
            captureId: current.captureId,
            sequence: chunk.sequence,
            proposedText: draft.text,
            excerpt: draft.excerpt,
            extractionKind: PrivacyActionConfig.extractorKind,
            extractionVersion: service.version,
            createdAt: now,
            expiresAt: now.add(PrivacyActionConfig.candidateTtl),
          ));
          added++;
        }
      }
      return added;
    });
  }

  Future<List<PrivacyCandidateRecord>> pendingCandidates() async {
    final doc = await _read();
    return doc.candidates.where((item) => item.status == 'pending' && !item.tombstone).toList();
  }

  Future<PrivacyWriteResult<PrivacyTaskRecord>> acceptCandidate(
    String candidateId, {
    String? editedTitle,
    DateTime? at,
  }) async {
    final task = await _tx((doc) async {
      final index = doc.candidates.indexWhere((item) => item.candidateId == candidateId && item.status == 'pending');
      if (index < 0) return null;
      final candidate = doc.candidates[index];
      final title = (editedTitle ?? candidate.proposedText).trim();
      if (title.isEmpty) return null;
      final now = at ?? DateTime.now();
      final created = PrivacyTaskRecord(
        taskId: _newId(),
        title: title,
        status: 'open',
        creationOrigin: 'accepted_candidate',
        sourceSessionId: candidate.sessionId,
        sourceKind: candidate.origin,
        excerpt: boundPrivacyExcerpt(candidate.excerpt),
        createdAt: now,
        updatedAt: now,
      );
      doc.tasks.add(created);
      doc.candidates[index] = PrivacyCandidateRecord(
        candidateId: candidate.candidateId,
        sessionId: candidate.sessionId,
        captureId: candidate.captureId,
        sequence: candidate.sequence,
        proposedText: '',
        excerpt: '',
        extractionKind: candidate.extractionKind,
        extractionVersion: candidate.extractionVersion,
        origin: candidate.origin,
        status: 'accepted',
        createdAt: candidate.createdAt,
        tombstone: true,
      );
      return created;
    });
    if (task == null) return const PrivacyWriteResult.failed('missing_candidate');
    return PrivacyWriteResult.ok(task);
  }

  Future<PrivacyWriteResult<void>> dismissCandidate(String candidateId) async {
    final ok = await _tx((doc) async {
      final index = doc.candidates.indexWhere((item) => item.candidateId == candidateId);
      if (index < 0) return false;
      final candidate = doc.candidates[index];
      doc.candidates[index] = PrivacyCandidateRecord(
        candidateId: candidate.candidateId,
        sessionId: candidate.sessionId,
        captureId: candidate.captureId,
        sequence: candidate.sequence,
        proposedText: '',
        excerpt: '',
        extractionKind: candidate.extractionKind,
        extractionVersion: candidate.extractionVersion,
        origin: candidate.origin,
        status: 'dismissed',
        createdAt: candidate.createdAt,
        tombstone: true,
      );
      return true;
    });
    if (!ok) return const PrivacyWriteResult.failed('missing_candidate');
    return const PrivacyWriteResult.ok(null);
  }

  Future<PrivacyWriteResult<PrivacyTaskRecord>> createTask({
    required String title,
    String? note,
    DateTime? dueAt,
    String? projectId,
    String? sourceSessionId,
    String? sourceKind,
    String? excerpt,
    String creationOrigin = 'manual',
    DateTime? at,
  }) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return const PrivacyWriteResult.failed('empty_title');
    final task = await _tx((doc) async {
      if (projectId != null && !doc.projects.any((item) => item.projectId == projectId && !item.archived)) {
        return null;
      }
      final now = at ?? DateTime.now();
      final created = PrivacyTaskRecord(
        taskId: _newId(),
        title: trimmed,
        note: note?.trim().isEmpty ?? true ? null : note!.trim(),
        status: 'open',
        dueAt: dueAt,
        projectId: projectId,
        creationOrigin: creationOrigin,
        sourceSessionId: sourceSessionId,
        sourceKind: sourceKind,
        excerpt: excerpt == null ? null : boundPrivacyExcerpt(excerpt),
        createdAt: now,
        updatedAt: now,
      );
      doc.tasks.add(created);
      return created;
    });
    if (task == null) return const PrivacyWriteResult.failed('rejected');
    return PrivacyWriteResult.ok(task);
  }

  Future<List<PrivacyTaskRecord>> tasks() async {
    final doc = await _read();
    return doc.tasks.toList();
  }

  Future<PrivacyWriteResult<PrivacyTaskRecord>> updateTask(
    String taskId, {
    String? title,
    String? note,
    bool clearNote = false,
    DateTime? dueAt,
    bool clearDue = false,
    String? projectId,
    bool clearProject = false,
    DateTime? at,
  }) async {
    final updated = await _tx((doc) async {
      final index = doc.tasks.indexWhere((item) => item.taskId == taskId);
      if (index < 0) return null;
      if (projectId != null && !doc.projects.any((item) => item.projectId == projectId && !item.archived)) return null;
      final next = doc.tasks[index].copyWith(
        title: title?.trim(),
        note: note,
        clearNote: clearNote,
        dueAt: dueAt,
        clearDue: clearDue,
        projectId: projectId,
        clearProject: clearProject,
        updatedAt: at ?? DateTime.now(),
      );
      if (next.title.trim().isEmpty) return null;
      doc.tasks[index] = next;
      return next;
    });
    if (updated == null) return const PrivacyWriteResult.failed('missing_task');
    return PrivacyWriteResult.ok(updated);
  }

  Future<PrivacyWriteResult<PrivacyTaskRecord>> setTaskStatus(String taskId,
      {required bool completed, DateTime? at}) async {
    final updated = await _tx((doc) async {
      final index = doc.tasks.indexWhere((item) => item.taskId == taskId);
      if (index < 0) return null;
      final now = at ?? DateTime.now();
      final next = doc.tasks[index].copyWith(
        status: completed ? 'completed' : 'open',
        completedAt: completed ? now : null,
        clearCompleted: !completed,
        updatedAt: now,
      );
      doc.tasks[index] = next;
      return next;
    });
    if (updated == null) return const PrivacyWriteResult.failed('missing_task');
    return PrivacyWriteResult.ok(updated);
  }

  Future<PrivacyWriteResult<void>> deleteTask(String taskId) async {
    final ok = await _tx((doc) async {
      final before = doc.tasks.length;
      doc.tasks.removeWhere((item) => item.taskId == taskId);
      return doc.tasks.length != before;
    });
    if (!ok) return const PrivacyWriteResult.failed('missing_task');
    return const PrivacyWriteResult.ok(null);
  }

  Future<PrivacyWriteResult<PrivacyProjectRecord>> createProject(String name, {DateTime? at}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return const PrivacyWriteResult.failed('empty_name');
    final project = await _tx((doc) async {
      final now = at ?? DateTime.now();
      final created = PrivacyProjectRecord(projectId: _newId(), name: trimmed, createdAt: now, updatedAt: now);
      doc.projects.add(created);
      return created;
    });
    return PrivacyWriteResult.ok(project);
  }

  Future<List<PrivacyProjectRecord>> projects({bool includeArchived = true}) async {
    final doc = await _read();
    return doc.projects.where((item) => includeArchived || !item.archived).toList();
  }

  Future<PrivacyWriteResult<PrivacyProjectRecord>> renameProject(String projectId, String name, {DateTime? at}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return const PrivacyWriteResult.failed('empty_name');
    final updated = await _tx((doc) async {
      final index = doc.projects.indexWhere((item) => item.projectId == projectId);
      if (index < 0) return null;
      final next = doc.projects[index].copyWith(name: trimmed, updatedAt: at ?? DateTime.now());
      doc.projects[index] = next;
      return next;
    });
    if (updated == null) return const PrivacyWriteResult.failed('missing_project');
    return PrivacyWriteResult.ok(updated);
  }

  Future<PrivacyWriteResult<PrivacyProjectRecord>> archiveProject(String projectId,
      {bool archived = true, DateTime? at}) async {
    final updated = await _tx((doc) async {
      final index = doc.projects.indexWhere((item) => item.projectId == projectId);
      if (index < 0) return null;
      final next = doc.projects[index].copyWith(archived: archived, updatedAt: at ?? DateTime.now());
      doc.projects[index] = next;
      return next;
    });
    if (updated == null) return const PrivacyWriteResult.failed('missing_project');
    return PrivacyWriteResult.ok(updated);
  }

  Future<void> recoverLaunch(DateTime now) async {
    await _tx((doc) async {
      final expireNow =
          doc.sessions.where((session) => session.deleteOnNextLaunch).map((session) => session.localId).toSet();
      doc.sessions = doc.sessions.map((session) {
        if (!session.isActive) return session;
        final choice = privacyRetentionFromName(session.retentionChoice ?? doc.retention);
        return session.copyWith(
          outcome: 'interrupted',
          incomplete: true,
          failureClass: 'process_restart',
          stoppedAt: now,
          deleteOnNextLaunch: session.deleteOnNextLaunch || choice == PrivacyRetentionChoice.sessionOnly,
        );
      }).toList();
      final doomed = doc.sessions
          .where((session) {
            if (expireNow.contains(session.localId)) return true;
            final expires = session.expiresAt;
            return expires != null && !expires.isAfter(now);
          })
          .map((session) => session.localId)
          .toSet();
      if (doomed.isNotEmpty) {
        _deleteSessions(doc, doomed, deleteAcceptedTasks: false, scope: 'expiry', at: now);
      }
      doc.candidates.removeWhere((item) {
        if (item.tombstone) return false;
        final expires = item.expiresAt;
        return item.status != 'pending' || (expires != null && !expires.isAfter(now));
      });
    });
  }

  Future<void> expireDue(DateTime now) async {
    await _tx((doc) async {
      _expire(doc, now, launchSweep: false);
    });
  }

  Future<PrivacyDeletionPreview> previewSession(String sessionId) async {
    final doc = await _read();
    return _preview(doc, sessionIds: {sessionId}, includeDiagnostics: false);
  }

  Future<PrivacyDeletionPreview> previewAll() async {
    final doc = await _read();
    return _preview(doc, sessionIds: doc.sessions.map((item) => item.localId).toSet(), includeDiagnostics: true);
  }

  Future<PrivacyWriteResult<PrivacyReceiptRecord>> deleteSession(
    String sessionId, {
    required bool deleteAcceptedTasks,
    DateTime? at,
  }) async {
    final receipt = await _tx((doc) async {
      if (!doc.sessions.any((item) => item.localId == sessionId)) return null;
      return _deleteSessions(doc, {sessionId},
          deleteAcceptedTasks: deleteAcceptedTasks, scope: 'session', at: at ?? DateTime.now());
    });
    if (receipt == null) return const PrivacyWriteResult.failed('missing_session');
    return PrivacyWriteResult.ok(receipt);
  }

  Future<PrivacyWriteResult<PrivacyReceiptRecord>> clearLocal({DateTime? at}) async {
    final receipt = await _tx((doc) async {
      final ids = doc.sessions.map((item) => item.localId).toSet();
      final cleared = _deleteSessions(doc, ids,
          deleteAcceptedTasks: true, scope: 'clear_local', at: at ?? DateTime.now(), clearDiagnostics: true);
      doc.projects.clear();
      doc.tasks.clear();
      return cleared;
    });
    return PrivacyWriteResult.ok(receipt);
  }

  Future<List<PrivacyReceiptRecord>> receipts() async {
    final doc = await _read();
    return doc.receipts.toList();
  }

  Future<List<PrivacyDiagnosticRecord>> diagnostics() async {
    final doc = await _read();
    return doc.diagnostics.toList();
  }

  Future<void> clearDiagnostics() async {
    await _tx((doc) async {
      doc.diagnostics.clear();
    });
  }

  Future<String> exportDiagnostics() async {
    final rows = await diagnostics();
    return jsonEncode(rows.map((item) => item.toJson()).toList());
  }

  Future<T> _tx<T>(Future<T> Function(_Doc doc) body) {
    final run = _lock.then((_) async {
      final doc = await _read();
      final result = await body(doc);
      await _write(doc);
      return result;
    });
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<_Doc> _read() async {
    if (_cache != null) return _cache!;
    if (!await _file.exists()) {
      _cache = _Doc();
      return _cache!;
    }
    final raw = await _file.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('privacy store');
    }
    final version = decoded['schema_version'];
    if (version != PrivacyActionConfig.schemaVersion) {
      throw const FormatException('privacy store version');
    }
    _cache = _Doc.fromJson(decoded);
    return _cache!;
  }

  Future<void> _write(_Doc doc) async {
    final encoded = jsonEncode(doc.toJson());
    final tmp = File('${_file.path}.tmp');
    final previous = await _file.exists() ? await _file.readAsBytes() : null;
    try {
      await tmp.writeAsString(encoded, flush: true);
      await _protect(tmp.path);
      await tmp.rename(_file.path);
      await _protect(_file.path);
      _cache = doc;
    } catch (_) {
      _cache = null;
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      if (previous != null) {
        final current = await _file.exists() ? await _file.readAsBytes() : null;
        if (current == null || !_sameBytes(current, previous)) {
          await _file.writeAsBytes(previous, flush: true);
          try {
            await _protect(_file.path);
          } catch (_) {}
        }
      } else if (await _file.exists()) {
        try {
          if (await _file.readAsString() == encoded) await _file.delete();
        } catch (_) {}
      }
      throw const PrivacyStoreUnavailable();
    }
  }

  static Future<void> _prepare(File file) async {
    final tmp = File('${file.path}.tmp');
    if (await file.exists()) {
      final raw = await file.readAsString();
      if (!_validStore(raw)) throw const PrivacyStoreUnavailable();
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      return;
    }
    if (!await tmp.exists()) return;
    final raw = await tmp.readAsString();
    if (!_validStore(raw)) throw const PrivacyStoreUnavailable();
    await tmp.rename(file.path);
  }

  static bool _validStore(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map && decoded['schema_version'] == PrivacyActionConfig.schemaVersion;
    } catch (_) {
      return false;
    }
  }

  static bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  static PrivacySessionRecord? _find(_Doc doc, String captureId) {
    final matches = doc.sessions.where((item) => item.captureId == captureId).toList();
    if (matches.isEmpty) return null;
    return matches.single;
  }

  static void _replaceSession(_Doc doc, String captureId, PrivacySessionRecord Function(PrivacySessionRecord) update) {
    final index = doc.sessions.indexWhere((item) => item.captureId == captureId);
    if (index < 0) return;
    doc.sessions[index] = update(doc.sessions[index]);
  }

  static void _expire(_Doc doc, DateTime now, {required bool launchSweep}) {
    final doomed = doc.sessions
        .where((session) {
          if (launchSweep && session.deleteOnNextLaunch) return true;
          final expires = session.expiresAt;
          return expires != null && !expires.isAfter(now);
        })
        .map((session) => session.localId)
        .toSet();
    if (doomed.isNotEmpty) {
      _deleteSessions(doc, doomed, deleteAcceptedTasks: false, scope: 'expiry', at: now, recordReceipt: true);
    }
    doc.candidates.removeWhere((item) {
      if (item.tombstone) return false;
      final expires = item.expiresAt;
      return item.status != 'pending' || (expires != null && !expires.isAfter(now));
    });
  }

  static PrivacyDeletionPreview _preview(_Doc doc,
      {required Set<String> sessionIds, required bool includeDiagnostics}) {
    final chunks = doc.chunks.where((item) => sessionIds.contains(item.sessionId)).length;
    final notes = doc.notes.where((item) => sessionIds.contains(item.sessionId)).length;
    final pending =
        doc.candidates.where((item) => sessionIds.contains(item.sessionId) && item.status == 'pending').length;
    final tasks =
        doc.tasks.where((item) => item.sourceSessionId != null && sessionIds.contains(item.sourceSessionId)).toList();
    return PrivacyDeletionPreview(
      sessionCount: doc.sessions.where((item) => sessionIds.contains(item.localId)).length,
      chunkCount: chunks,
      noteCount: notes,
      pendingCandidateCount: pending,
      acceptedTaskCount: tasks.length,
      excerptCount: tasks.where((item) => (item.excerpt ?? '').isNotEmpty).length,
      diagnosticCount: includeDiagnostics ? doc.diagnostics.length : 0,
      remoteDeletion: PrivacyActionConfig.remoteDeletionStatus,
    );
  }

  static PrivacyReceiptRecord _deleteSessions(
    _Doc doc,
    Set<String> sessionIds, {
    required bool deleteAcceptedTasks,
    required String scope,
    required DateTime at,
    bool clearDiagnostics = false,
    bool recordReceipt = true,
  }) {
    final chunks = doc.chunks.where((item) => sessionIds.contains(item.sessionId)).length;
    final notes = doc.notes.where((item) => sessionIds.contains(item.sessionId)).length;
    final candidates = doc.candidates.where((item) => sessionIds.contains(item.sessionId) && !item.tombstone).length;
    final linked =
        doc.tasks.where((item) => item.sourceSessionId != null && sessionIds.contains(item.sourceSessionId)).toList();
    var excerpts = 0;
    var kept = 0;
    var deletedTasks = 0;
    if (deleteAcceptedTasks) {
      deletedTasks = linked.length;
      doc.tasks.removeWhere((item) => item.sourceSessionId != null && sessionIds.contains(item.sourceSessionId));
    } else {
      doc.tasks = doc.tasks.map((task) {
        if (task.sourceSessionId == null || !sessionIds.contains(task.sourceSessionId)) return task;
        if ((task.excerpt ?? '').isNotEmpty) excerpts++;
        kept++;
        return task.copyWith(clearSource: true, clearExcerpt: true, updatedAt: at);
      }).toList();
    }
    doc.sessions.removeWhere((item) => sessionIds.contains(item.localId));
    doc.chunks.removeWhere((item) => sessionIds.contains(item.sessionId));
    doc.notes.removeWhere((item) => sessionIds.contains(item.sessionId));
    doc.candidates.removeWhere((item) => sessionIds.contains(item.sessionId));
    var diagnostics = 0;
    if (clearDiagnostics) {
      diagnostics = doc.diagnostics.length;
      doc.diagnostics.clear();
    }
    final receipt = PrivacyReceiptRecord(
      receiptId: 'receipt-${doc.receipts.length + 1}',
      at: at,
      scope: scope,
      sessionsDeleted: sessionIds.length,
      chunksDeleted: chunks,
      notesDeleted: notes,
      candidatesDeleted: candidates,
      excerptsCleared: excerpts,
      tasksDeleted: deletedTasks,
      tasksKept: kept,
      diagnosticsCleared: diagnostics,
    );
    if (recordReceipt) doc.receipts.add(receipt);
    doc.diagnostics.add(PrivacyDiagnosticRecord(at: at, kind: 'deleted', state: 'off'));
    _trimDiagnostics(doc);
    return receipt;
  }

  static void _trimDiagnostics(_Doc doc) {
    doc.diagnostics.removeWhere((item) => !privacyDiagnosticKindAllowed(item.kind));
    if (doc.diagnostics.length > PrivacyActionConfig.diagnosticCap) {
      doc.diagnostics.removeRange(0, doc.diagnostics.length - PrivacyActionConfig.diagnosticCap);
    }
  }

  static int _id = 0;
  static String _defaultId() {
    _id++;
    final hex = _id.toRadixString(16).padLeft(12, '0');
    return '00000000-0000-4000-8000-$hex';
  }

  static Future<void> _noopProtect(String path) async {}
}

class _Doc {
  int schemaVersion = PrivacyActionConfig.schemaVersion;
  String? retention;
  bool retentionIsOwnerChoice = false;
  List<PrivacySessionRecord> sessions = [];
  List<PrivacyChunkRecord> chunks = [];
  List<PrivacyNoteRecord> notes = [];
  List<PrivacyCandidateRecord> candidates = [];
  List<PrivacyTaskRecord> tasks = [];
  List<PrivacyProjectRecord> projects = [];
  List<PrivacyReceiptRecord> receipts = [];
  List<PrivacyDiagnosticRecord> diagnostics = [];

  Map<String, Object?> toJson() => {
        'schema_version': schemaVersion,
        'retention': retention,
        'retention_is_owner_choice': retentionIsOwnerChoice,
        'retention_note': PrivacyActionConfig.retentionNote,
        'sessions': sessions.map((item) => item.toJson()).toList(),
        'chunks': chunks.map((item) => item.toJson()).toList(),
        'notes': notes.map((item) => item.toJson()).toList(),
        'candidates': candidates.map((item) => item.toJson()).toList(),
        'tasks': tasks.map((item) => item.toJson()).toList(),
        'projects': projects.map((item) => item.toJson()).toList(),
        'receipts': receipts.map((item) => item.toJson()).toList(),
        'diagnostics': diagnostics.map((item) => item.toJson()).toList(),
      };

  static _Doc fromJson(Map<String, dynamic> json) {
    final doc = _Doc()
      ..schemaVersion = json['schema_version'] as int
      ..retention = json['retention'] as String?
      ..retentionIsOwnerChoice = json['retention_is_owner_choice'] as bool? ?? false
      ..sessions = _list(json['sessions'], PrivacySessionRecord.fromJson)
      ..chunks = _list(json['chunks'], PrivacyChunkRecord.fromJson)
      ..notes = _list(json['notes'], PrivacyNoteRecord.fromJson)
      ..candidates = _list(json['candidates'], PrivacyCandidateRecord.fromJson)
      ..tasks = _list(json['tasks'], PrivacyTaskRecord.fromJson)
      ..projects = _list(json['projects'], PrivacyProjectRecord.fromJson)
      ..receipts = _list(json['receipts'], PrivacyReceiptRecord.fromJson)
      ..diagnostics = _list(json['diagnostics'], PrivacyDiagnosticRecord.fromJson);
    return doc;
  }

  static List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) decode) {
    if (raw is! List) return [];
    return raw.whereType<Map>().map((item) => decode(Map<String, dynamic>.from(item))).toList();
  }
}
