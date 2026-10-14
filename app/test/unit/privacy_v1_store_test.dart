import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/privacy_capture/privacy_action_config.dart';
import 'package:omi/services/privacy_capture/privacy_capture_feature.dart';
import 'package:omi/services/privacy_capture/privacy_capture_config.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_quick_capture.dart';
import 'package:omi/services/privacy_capture/privacy_redaction.dart';
import 'package:omi/services/privacy_capture/privacy_standalone.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';
import 'package:omi/services/privacy_capture/privacy_suggestion.dart';

void main() {
  test('stock build cannot initialize privacy capture', () async {
    expect(privacyCaptureEnabled, isFalse);
    await PrivacyCaptureHost.ensureReady();
    expect(PrivacyCaptureHost.captureInitialized, isFalse);
    expect(selectPrivacyAppRoot(privacyMode: privacyCaptureEnabled, signedIn: true), PrivacyAppRoot.signedIn);
  });

  test('suggestion boundaries stay explicit and labeled', () {
    const service = ActionSuggestionService();
    expect(service.extract('The weather is nice today.'), isEmpty);
    expect(service.extract('He will send the notes later.'), isEmpty);
    expect(service.extract('Will I remember this?'), isEmpty);
    expect(service.extract("I'll"), isEmpty);
    final hit = service.extract("I will send the draft tomorrow. Remind me to buy milk.");
    expect(hit, hasLength(2));
    expect(hit.first.text.toLowerCase(), contains('send the draft'));
    expect(service.version, PrivacyActionConfig.extractorVersion);
  });

  test('logs and diagnostics omit credentials and transcript text', () async {
    const transcript = 'local only private utterance';
    const bearer = 'secret-token-value';
    expect(
      privacyLogContainsSensitive(line: 'state=off', transcript: transcript, bearer: bearer),
      isFalse,
    );
    expect(
      privacyLogContainsSensitive(line: 'saw $transcript', transcript: transcript, bearer: bearer),
      isTrue,
    );
    expect(privacyDiagnosticKindAllowed('transcript:$transcript'), isFalse);
    final dir = await Directory.systemTemp.createTemp('privacy-redact');
    final store = await PrivacyStore.open(dir);
    await store.openSession(
      captureId: '11111111-1111-4111-8111-111111111111',
      purpose: 'personal_memory',
      ownerPurpose: 'remember a commitment',
      consentBasis: 'self_only',
      protocolVersion: 1,
      policyRevision: 1,
      at: DateTime.utc(2026, 10, 10),
    );
    final exported = await store.exportDiagnostics();
    expect(exported.contains(transcript), isFalse);
    expect(exported.contains(bearer), isFalse);
    expect(exported.contains('remember a commitment'), isFalse);
  });

  test('retention, restart, tasks, and deletion stay local and honest', () async {
    final dir = await Directory.systemTemp.createTemp('privacy-store');
    final store = await PrivacyStore.open(dir);
    expect(await store.readRetention(), isNull);
    await store.setRetention(PrivacyRetentionChoice.hours24);
    const captureId = '11111111-1111-4111-8111-111111111111';
    final opened = await store.openSession(
      captureId: captureId,
      purpose: 'personal_memory',
      ownerPurpose: 'draft the note',
      consentBasis: 'self_only',
      protocolVersion: 1,
      policyRevision: 1,
      at: DateTime.utc(2026, 10, 10, 12),
    );
    expect(opened.ok, isTrue);
    expect(await store.upsertChunk(captureId: captureId, sequence: 1, machineText: 'I will send the draft tomorrow'),
        isTrue);
    expect(await store.upsertChunk(captureId: captureId, sequence: 1, machineText: 'I will send the draft tomorrow'),
        isTrue);
    expect(await store.upsertChunk(captureId: captureId, sequence: 1, machineText: 'different'), isFalse);
    final corrected = await store.correctChunk(captureId: captureId, sequence: 1, correction: 'Send the draft');
    expect(corrected.ok, isTrue);
    expect(corrected.value!.machineText, 'I will send the draft tomorrow');
    expect(corrected.value!.correction, 'Send the draft');
    await store.addNote(sessionId: opened.value!.localId, text: 'owner note');
    await store.markTerminal(
        captureId: captureId, outcome: 'transcribed', incomplete: false, at: DateTime.utc(2026, 10, 10, 12, 5));
    final added =
        await store.refreshSuggestions(service: const ActionSuggestionService(), sessionId: opened.value!.localId);
    expect(added, 1);
    final pending = await store.pendingCandidates();
    expect(pending.single.origin, 'heuristic_suggestion');
    final accepted = await store.acceptCandidate(pending.single.candidateId, editedTitle: 'Send the draft');
    expect(accepted.ok, isTrue);
    expect(accepted.value!.excerpt!.length, lessThanOrEqualTo(PrivacyActionConfig.excerptMaxChars));
    expect(await store.pendingCandidates(), isEmpty);
    final manual = await store.createTask(title: 'Buy milk');
    final project = await store.createProject('Home');
    await store.updateTask(manual.value!.taskId,
        projectId: project.value!.projectId, dueAt: DateTime.utc(2026, 10, 10, 15));
    await store.renameProject(project.value!.projectId, 'House');
    await store.archiveProject(project.value!.projectId);
    await store.setTaskStatus(manual.value!.taskId, completed: true, at: DateTime.utc(2026, 10, 10, 16));
    await store.setTaskStatus(manual.value!.taskId, completed: false);
    final today =
        (await store.tasks()).where((task) => privacyTaskDueToday(task.dueAt, DateTime.utc(2026, 10, 10, 18))).toList();
    expect(today, isNotEmpty);

    final preview = await store.previewSession(opened.value!.localId);
    expect(preview.chunkCount, 1);
    expect(preview.acceptedTaskCount, 1);
    expect(preview.remoteDeletion, PrivacyActionConfig.remoteDeletionStatus);
    final kept = await store.deleteSession(opened.value!.localId, deleteAcceptedTasks: false);
    expect(kept.ok, isTrue);
    expect(kept.value!.localResult, 'deleted_from_this_phone');
    expect(kept.value!.remoteResult, 'remote_deletion_unavailable');
    final remaining = await store.tasks();
    expect(remaining.any((task) => task.title == 'Send the draft' && task.excerpt == null), isTrue);
    expect(await store.chunks(opened.value!.localId), isEmpty);

    final reopened = await PrivacyStore.open(dir);
    final active = await reopened.openSession(
      captureId: '22222222-2222-4222-8222-222222222222',
      purpose: 'personal_memory',
      ownerPurpose: 'still recording',
      consentBasis: 'self_only',
      protocolVersion: 1,
      policyRevision: 1,
      at: DateTime.utc(2026, 10, 10, 18),
    );
    await reopened.markRecording(active.value!.captureId);
    final restarted = await PrivacyStore.open(dir);
    await restarted.recoverLaunch(DateTime.utc(2026, 10, 10, 19));
    final sessions = await restarted.sessions();
    expect(sessions.single.outcome, 'interrupted');
    expect(sessions.single.incomplete, isTrue);
    expect(sessions.single.outcome, isNot('recording'));

    await restarted.setRetention(PrivacyRetentionChoice.sessionOnly);
    final fleeting = await restarted.openSession(
      captureId: '33333333-3333-4333-8333-333333333333',
      purpose: 'personal_memory',
      ownerPurpose: 'session only',
      consentBasis: 'self_only',
      protocolVersion: 1,
      policyRevision: 1,
      at: DateTime.utc(2026, 10, 10, 20),
    );
    await restarted.markTerminal(
      captureId: fleeting.value!.captureId,
      outcome: 'transcribed',
      incomplete: false,
      at: DateTime.utc(2026, 10, 10, 20, 1),
    );
    final nextLaunch = await PrivacyStore.open(dir);
    await nextLaunch.recoverLaunch(DateTime.utc(2026, 10, 11));
    expect((await nextLaunch.sessions()).any((item) => item.captureId == fleeting.value!.captureId), isFalse);

    await nextLaunch.setRetention(PrivacyRetentionChoice.hours24);
    final expiring = await nextLaunch.openSession(
      captureId: '44444444-4444-4444-8444-444444444444',
      purpose: 'personal_memory',
      ownerPurpose: 'day',
      consentBasis: 'self_only',
      protocolVersion: 1,
      policyRevision: 1,
      at: DateTime.utc(2026, 10, 11),
    );
    await nextLaunch.markTerminal(
      captureId: expiring.value!.captureId,
      outcome: 'transcribed',
      incomplete: false,
      at: DateTime.utc(2026, 10, 11),
    );
    await nextLaunch.expireDue(DateTime.utc(2026, 10, 12, 1));
    expect((await nextLaunch.sessions()).any((item) => item.captureId == expiring.value!.captureId), isFalse);

    final dismissed = await nextLaunch.openSession(
      captureId: '55555555-5555-4555-8555-555555555555',
      purpose: 'personal_memory',
      ownerPurpose: 'dismiss',
      consentBasis: 'self_only',
      protocolVersion: 1,
      policyRevision: 1,
      at: DateTime.utc(2026, 10, 12),
    );
    await nextLaunch.upsertChunk(
        captureId: dismissed.value!.captureId, sequence: 1, machineText: 'Remind me to file taxes');
    await nextLaunch.refreshSuggestions(
        service: const ActionSuggestionService(), sessionId: dismissed.value!.localId, at: DateTime.utc(2026, 10, 12));
    final candidate = (await nextLaunch.pendingCandidates()).single;
    await nextLaunch.dismissCandidate(candidate.candidateId);
    expect(await nextLaunch.pendingCandidates(), isEmpty);
    await nextLaunch.refreshSuggestions(service: const ActionSuggestionService(), sessionId: dismissed.value!.localId);
    expect(await nextLaunch.pendingCandidates(), isEmpty);

    final cleared = await nextLaunch.clearLocal();
    expect(cleared.value!.remoteResult, contains('unavailable'));
    expect(await nextLaunch.sessions(), isEmpty);
    expect(jsonEncode(cleared.value!.toJson()).contains('Bearer'), isFalse);
  });

  test('quick-session provenance and fixed retention persist across restart', () async {
    final dir = await Directory.systemTemp.createTemp('privacy-quick-provenance');
    final store = await PrivacyStore.open(dir);
    await store.setRetention(PrivacyRetentionChoice.untilDeleted);
    final assertedAt = DateTime.utc(2026, 10, 10, 12, 0, 1);

    final opened = await store.openSession(
      captureId: '77777777-7777-4777-8777-777777777777',
      purpose: PrivacyCaptureConfig.defaultPurpose,
      ownerPurpose: QuickSelfCapturePurpose.taskCapture.provenanceValue,
      consentBasis: PrivacyCaptureConfig.quickGestureConsentBasis,
      wireConsentBasis: PrivacyCaptureConfig.defaultConsentBasis,
      consentAssertedAt: assertedAt,
      configuredPurpose: QuickSelfCapturePurpose.taskCapture.provenanceValue,
      captureOrigin: PrivacyCaptureConfig.pendantQuickCaptureOrigin,
      retentionChoice: PrivacyRetentionChoice.days7,
      protocolVersion: 1,
      policyRevision: 1,
      at: DateTime.utc(2026, 10, 10, 12, 0, 2),
    );
    expect(opened.ok, isTrue);
    await store.markTerminal(
      captureId: opened.value!.captureId,
      outcome: 'no_speech',
      incomplete: false,
      at: DateTime.utc(2026, 10, 10, 12, 1),
    );

    final reopened = await PrivacyStore.open(dir);
    final session = (await reopened.sessions()).single;
    expect(session.purpose, PrivacyCaptureConfig.defaultPurpose);
    expect(session.consentBasis, PrivacyCaptureConfig.quickGestureConsentBasis);
    expect(session.wireConsentBasis, PrivacyCaptureConfig.defaultConsentBasis);
    expect(session.consentAssertedAt, assertedAt);
    expect(session.configuredPurpose, 'task_capture');
    expect(session.captureOrigin, PrivacyCaptureConfig.pendantQuickCaptureOrigin);
    expect(session.retentionChoice, PrivacyRetentionChoice.days7.name);
    expect(session.expiresAt, DateTime.utc(2026, 10, 17, 12, 1));

    final raw = await File('${dir.path}/store.json').readAsString();
    expect(raw, contains('"consent_basis":"self_only_quick_gesture"'));
    expect(raw, contains('"wire_consent_basis":"self_only"'));
    expect(raw, contains('"capture_origin":"pendant_quick_capture"'));
  });

  test('cold-launch ID collisions mint a different task ID', () async {
    final dir = await Directory.systemTemp.createTemp('privacy-task-id-restart');
    const repeatedId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

    final firstLaunch = await PrivacyStore.open(dir, newId: () => repeatedId);
    final first = await firstLaunch.createTask(title: 'First task');
    expect(first.ok, isTrue);
    expect(first.value!.taskId, repeatedId);

    // Simulate a fresh process whose ID source starts from the same value.
    final secondLaunch = await PrivacyStore.open(dir, newId: () => repeatedId);
    final second = await secondLaunch.createTask(title: 'Second task');
    expect(second.ok, isTrue);
    expect(second.value!.taskId, isNot(repeatedId));

    final tasks = await secondLaunch.tasks();
    expect(tasks.map((task) => task.taskId).toSet(), hasLength(2));
    expect(tasks.map((task) => task.title), containsAll(<String>['First task', 'Second task']));
  });

  test('opening a legacy store repairs and persists duplicate task IDs', () async {
    final dir = await Directory.systemTemp.createTemp('privacy-task-id-repair');
    final file = File('${dir.path}/store.json');
    final store = await PrivacyStore.open(dir);
    final first = await store.createTask(title: 'Keep first identity');
    await store.createTask(title: 'Repair second identity');

    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final taskRows = json['tasks'] as List<dynamic>;
    (taskRows[1] as Map<String, dynamic>)['task_id'] = first.value!.taskId;
    await file.writeAsString(jsonEncode(json), flush: true);

    const repairedId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final repaired = await PrivacyStore.open(dir, newId: () => repairedId);
    final tasks = await repaired.tasks();
    expect(tasks, hasLength(2));
    expect(tasks[0].title, 'Keep first identity');
    expect(tasks[0].taskId, first.value!.taskId);
    expect(tasks[1].title, 'Repair second identity');
    expect(tasks[1].taskId, repairedId);
    expect(tasks.map((task) => task.taskId).toSet(), hasLength(2));

    final persisted = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final persistedRows = persisted['tasks'] as List<dynamic>;
    expect(
      persistedRows.map((row) => (row as Map<String, dynamic>)['task_id']).toSet(),
      hasLength(2),
    );
  });

  test('task completion changes only the task with the requested ID', () async {
    final dir = await Directory.systemTemp.createTemp('privacy-task-exact-completion');
    final ids = <String>[
      'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    ];
    final store = await PrivacyStore.open(dir, newId: () => ids.removeAt(0));
    final first = await store.createTask(title: 'Leave open');
    final second = await store.createTask(title: 'Complete this');
    final completedAt = DateTime.utc(2026, 10, 11, 15, 30);

    final result = await store.setTaskStatus(
      second.value!.taskId,
      completed: true,
      at: completedAt,
    );
    expect(result.ok, isTrue);
    expect(result.value!.taskId, second.value!.taskId);

    final tasksById = <String, PrivacyTaskRecord>{
      for (final task in await store.tasks()) task.taskId: task,
    };
    expect(tasksById[first.value!.taskId]!.status, 'open');
    expect(tasksById[first.value!.taskId]!.completedAt, isNull);
    expect(tasksById[second.value!.taskId]!.status, 'completed');
    expect(tasksById[second.value!.taskId]!.completedAt, completedAt);
  });

  test('protection failure and a bad replacement do not destroy the last valid store', () async {
    final dir = await Directory.systemTemp.createTemp('privacy-protect');
    final file = File('${dir.path}/store.json');
    final store = await PrivacyStore.open(dir);
    await store.createTask(title: 'Keep me');
    final before = await file.readAsBytes();

    await expectLater(
      PrivacyStore.open(dir, protect: (path) async {
        if (path.endsWith('.tmp') || path.endsWith('store.json')) throw StateError('protect');
      }),
      throwsA(isA<PrivacyStoreUnavailable>()),
    );
    expect(await file.readAsBytes(), before);
    final reopened = await PrivacyStore.open(dir);
    expect((await reopened.tasks()).any((task) => task.title == 'Keep me'), isTrue);

    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString('{"schema_version":1,"sessions":[]}');
    final kept = await PrivacyStore.open(dir);
    expect(await tmp.exists(), isFalse);
    expect((await kept.tasks()).any((task) => task.title == 'Keep me'), isTrue);

    await file.writeAsString('{"schema_version":99}');
    final corrupt = await file.readAsBytes();
    await expectLater(PrivacyStore.open(dir), throwsA(isA<PrivacyStoreUnavailable>()));
    expect(await file.readAsBytes(), corrupt);

    final broken = await Directory.systemTemp.createTemp('privacy-broken');
    final brokenFile = File('${broken.path}/store.json');
    await brokenFile.writeAsString('{');
    final brokenBytes = await brokenFile.readAsBytes();
    await expectLater(PrivacyStore.open(broken), throwsA(isA<PrivacyStoreUnavailable>()));
    expect(await brokenFile.readAsBytes(), brokenBytes);
  });

  test('task edits, selected project, and source removal stay explicit', () async {
    final dir = await Directory.systemTemp.createTemp('privacy-edit');
    final store = await PrivacyStore.open(dir);
    final task = await store.createTask(title: 'Draft', note: 'first');
    final edited = await store.updateTask(task.value!.taskId, title: 'Revised draft', note: 'second');
    expect(edited.value!.title, 'Revised draft');
    expect(edited.value!.note, 'second');
    final due = DateTime.utc(2026, 11, 2, 15, 45);
    await store.updateTask(task.value!.taskId, dueAt: due);
    expect((await store.tasks()).single.dueAt, due);
    await store.updateTask(task.value!.taskId, clearDue: true);
    expect((await store.tasks()).single.dueAt, isNull);
    final home = await store.createProject('Home');
    final work = await store.createProject('Work');
    await store.updateTask(task.value!.taskId, projectId: work.value!.projectId);
    expect((await store.tasks()).single.projectId, isNot(home.value!.projectId));
    await store.renameProject(work.value!.projectId, 'Office');
    await store.archiveProject(work.value!.projectId);
    expect((await store.projects()).singleWhere((item) => item.projectId == work.value!.projectId).archived, isTrue);
    await store.updateTask(task.value!.taskId, clearProject: true);
    expect((await store.tasks()).single.projectId, isNull);

    const captureId = '66666666-6666-4666-8666-666666666666';
    final session = await store.openSession(
      captureId: captureId,
      purpose: 'personal_memory',
      ownerPurpose: 'chunk',
      consentBasis: 'self_only',
      protocolVersion: 1,
      policyRevision: 1,
      at: DateTime.utc(2026, 10, 10),
    );
    await store.upsertChunk(captureId: captureId, sequence: 1, machineText: 'I will file the form');
    await store.refreshSuggestions(service: const ActionSuggestionService(), sessionId: session.value!.localId);
    final candidate = (await store.pendingCandidates()).single;
    final accepted = await store.acceptCandidate(candidate.candidateId, editedTitle: 'File the form');
    expect(accepted.value!.excerpt, isNotEmpty);
    await store.deleteSession(session.value!.localId, deleteAcceptedTasks: false);
    final keptTask = (await store.tasks()).singleWhere((item) => item.taskId == accepted.value!.taskId);
    expect(keptTask.title, 'File the form');
    expect(keptTask.excerpt, isNull);
    expect(keptTask.sourceSessionId, isNull);
  });
}
