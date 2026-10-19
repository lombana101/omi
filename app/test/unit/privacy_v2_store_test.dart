import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/privacy_capture/privacy_action_config.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';

void main() {
  test('v1 data migrates additively and new ids remain unique across reopen', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-v1-migration');
    final file = File('${directory.path}/store.json');
    await file.writeAsString(jsonEncode(<String, Object?>{
      'schema_version': 1,
      'retention': 'untilDeleted',
      'retention_is_owner_choice': true,
      'sessions': <Object?>[],
      'chunks': <Object?>[],
      'notes': <Object?>[],
      'candidates': <Object?>[],
      'tasks': <Object?>[
        <String, Object?>{
          'task_id': 'legacy-task',
          'title': 'Preserve me',
          'status': 'open',
          'creation_origin': 'manual',
          'created_at': '2026-10-12T10:00:00.000Z',
          'updated_at': '2026-10-12T10:00:00.000Z',
        },
      ],
      'projects': <Object?>[],
      'receipts': <Object?>[],
      'diagnostics': <Object?>[],
    }));

    final first = await PrivacyStore.open(directory, now: () => DateTime.utc(2026, 10, 13));
    expect((await first.tasks()).single.title, 'Preserve me');
    final firstNew = await first.createTask(title: 'First new task');
    final reopened = await PrivacyStore.open(directory, now: () => DateTime.utc(2026, 10, 13, 1));
    final secondNew = await reopened.createTask(title: 'Second new task');

    expect(firstNew.value!.taskId, isNot(secondNew.value!.taskId));
    expect(RegExp(r'^[a-f0-9-]{36}$').hasMatch(firstNew.value!.taskId), isTrue);
    final saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(saved['schema_version'], PrivacyActionConfig.schemaVersion);
    expect((await reopened.tasks()).any((task) => task.taskId == 'legacy-task'), isTrue);
  });

  test('manual Today and habit history persist without becoming remote state', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-plan');
    final now = DateTime(2026, 10, 13, 9);
    final store = await PrivacyStore.open(directory, now: () => now);
    final task = await store.createTask(title: 'Priority', at: now);
    await store.setTaskToday(task.value!.taskId, selected: true, at: now);
    final habit = await store.createHabit('Stretch', at: now);
    await store.setHabitCompleted(habit.value!.habitId, day: now, completed: true);

    final reopened = await PrivacyStore.open(directory, now: () => now.add(const Duration(minutes: 1)));
    expect(privacyTaskSelectedToday((await reopened.tasks()).single, now), isTrue);
    expect((await reopened.habits()).single.title, 'Stretch');
    expect((await reopened.habitCompletions(habitId: habit.value!.habitId, now: now)), hasLength(1));

    await reopened.setTaskToday(task.value!.taskId, selected: false, at: now);
    await reopened.setHabitCompleted(habit.value!.habitId, day: now, completed: false);
    expect(privacyTaskSelectedToday((await reopened.tasks()).single, now), isFalse);
    expect(await reopened.habitCompletions(habitId: habit.value!.habitId, now: now), isEmpty);
  });

  test('structured suggestions dedupe, retain provenance, and remain review only', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-intelligence-suggestions');
    final store = await PrivacyStore.open(directory);
    final first = await store.addIntelligenceCandidate(
      sourceRef: 'manual:one',
      suggestedType: 'task',
      title: 'Prepare slides',
      excerpt: 'I will prepare slides',
      uncertainty: 0.2,
      proposedTimeText: 'next Friday',
    );
    final duplicate = await store.addIntelligenceCandidate(
      sourceRef: 'manual:one',
      suggestedType: 'task',
      title: '  PREPARE   SLIDES ',
      excerpt: 'I will prepare slides',
      uncertainty: 0.2,
      proposedTimeText: 'next friday',
    );
    expect(first.value!.candidateId, duplicate.value!.candidateId);
    expect((await store.tasks()), isEmpty);
    final pending = (await store.pendingCandidates()).single;
    expect(pending.sourceRef, 'manual:one');
    expect(pending.proposedTimeText, 'next Friday');
    expect(pending.extractionKind, 'structured_personal_action');
    expect(pending.extractionVersion, 'ollama-structured-v1');
    expect(pending.origin, 'intelligence_suggestion');

    final accepted = await store.acceptCandidate(first.value!.candidateId);
    expect(accepted.ok, isTrue);
    expect((await store.tasks()).single.title, 'Prepare slides');
    expect(await store.pendingCandidates(), isEmpty);

    final calendar = await store.addIntelligenceCandidate(
      sourceRef: 'manual:two',
      suggestedType: 'calendar_event',
      title: 'Focus block',
      excerpt: 'Schedule a focus block',
      uncertainty: 0.1,
      proposedStartAt: DateTime.utc(2026, 10, 14, 14),
      proposedEndAt: DateTime.utc(2026, 10, 14, 16),
      timezone: 'America/Toronto',
    );
    expect((await store.tasks()), hasLength(1));
    expect((await store.acceptCandidate(calendar.value!.candidateId)).ok, isFalse);
    expect((await store.tasks()), hasLength(1));
  });

  test('candidate acceptance preserves due time and exact project references', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-candidate-acceptance');
    final store = await PrivacyStore.open(directory);
    final memoria = await store.createProject('Memoria');
    await store.createProject('Memo');
    final atlas = await store.createProject('Project Atlas');
    final commitmentDue = DateTime.utc(2026, 10, 18, 16);
    final intentionDue = DateTime.utc(2026, 10, 19, 9);

    final commitment = await store.addIntelligenceCandidate(
      sourceRef: 'manual:commitment',
      suggestedType: 'commitment',
      title: 'Finish the MEMORIA release notes',
      excerpt: 'I will finish the release notes',
      uncertainty: 0.1,
      proposedStartAt: commitmentDue,
    );
    final acceptedCommitment = await store.acceptCandidate(commitment.value!.candidateId);
    expect(acceptedCommitment.value!.dueAt, commitmentDue);
    expect(acceptedCommitment.value!.projectId, memoria.value!.projectId);

    final intention = await store.addIntelligenceCandidate(
      sourceRef: 'manual:intention',
      suggestedType: 'intention',
      title: 'Send the launch brief',
      description: 'Next step for PROJECT ATLAS.',
      excerpt: 'I intend to send the launch brief',
      uncertainty: 0.1,
      proposedStartAt: intentionDue,
    );
    final acceptedIntention = await store.acceptCandidate(intention.value!.candidateId);
    expect(acceptedIntention.value!.dueAt, intentionDue);
    expect(acceptedIntention.value!.projectId, atlas.value!.projectId);
  });

  test('ambiguous project names do not create automatic task associations', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-project-ambiguity');
    final store = await PrivacyStore.open(directory);
    final memoria = await store.createProject('Memoria');
    await store.createProject('Memo');

    final candidate = await store.addIntelligenceCandidate(
      sourceRef: 'manual:ambiguous-project',
      suggestedType: 'commitment',
      title: 'Finish the MEMORIA release notes',
      excerpt: 'Finish the release notes',
      uncertainty: 0.1,
    );

    final accepted = await store.acceptCandidate(candidate.value!.candidateId);

    expect(accepted.ok, isTrue);
    expect(accepted.value!.projectId, memoria.value!.projectId);
    final ambiguous = await store.addIntelligenceCandidate(
      sourceRef: 'manual:ambiguous-project-2',
      suggestedType: 'commitment',
      title: 'Finish the release notes',
      description: 'This refers to Memo or Memoria depending on context.',
      excerpt: 'Finish the release notes',
      uncertainty: 0.1,
    );

    final acceptedAmbiguous = await store.acceptCandidate(ambiguous.value!.candidateId);

    expect(acceptedAmbiguous.ok, isTrue);
    expect(acceptedAmbiguous.value!.projectId, isNull);
  });

  test('custom intelligence provenance is stored verbatim', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-candidate-provenance');
    final store = await PrivacyStore.open(directory);

    final result = await store.addIntelligenceCandidate(
      sourceRef: 'proactive:deadline-risk',
      suggestedType: 'task',
      title: 'Replan the deadline',
      excerpt: 'The deadline is at risk',
      uncertainty: 0.25,
      extractionKind: 'deterministic_deadline_risk',
      extractionVersion: 'deadline-risk-v1',
      origin: 'proactive_intelligence',
    );

    expect(result.value!.extractionKind, 'deterministic_deadline_risk');
    expect(result.value!.extractionVersion, 'deadline-risk-v1');
    expect(result.value!.origin, 'proactive_intelligence');
  });

  test('whole-store preview and clear include sessionless candidates and tombstones', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-clear-sessionless');
    final store = await PrivacyStore.open(directory);
    await store.createTask(title: 'Manual task');
    await store.addIntelligenceCandidate(
      sourceRef: 'manual:pending',
      suggestedType: 'task',
      title: 'Pending manual suggestion',
      excerpt: 'Pending suggestion',
      uncertainty: 0.2,
    );
    final proactive = await store.addIntelligenceCandidate(
      sourceRef: 'proactive:dismissed',
      suggestedType: 'task',
      title: 'Dismissed proactive suggestion',
      excerpt: 'Dismissed suggestion',
      uncertainty: 0.2,
      origin: 'proactive_intelligence',
    );
    await store.dismissCandidate(proactive.value!.candidateId);

    final preview = await store.previewAll();
    expect(preview.pendingCandidateCount, 2);
    expect(preview.acceptedTaskCount, 1);

    final cleared = await store.clearLocal(at: DateTime.utc(2026, 10, 15));
    expect(cleared.value!.candidatesDeleted, 2);
    expect(cleared.value!.tasksDeleted, 1);
    expect(await store.pendingCandidates(), isEmpty);
    expect(await store.tasks(), isEmpty);

    final saved = jsonDecode(await File('${directory.path}/store.json').readAsString()) as Map<String, dynamic>;
    expect(saved['candidates'], isEmpty);
    expect(saved['tasks'], isEmpty);
  });

  test('legacy plaintext tombstones migrate to hashes and still suppress suggestions', () async {
    final directory = await Directory.systemTemp.createTemp('privacy-fingerprint-migration');
    final file = File('${directory.path}/store.json');
    final store = await PrivacyStore.open(directory);
    final candidate = await store.addIntelligenceCandidate(
      sourceRef: 'proactive:rent',
      suggestedType: 'task',
      title: 'Pay the rent',
      excerpt: 'Rent is due',
      uncertainty: 0.1,
      proposedTimeText: 'tomorrow',
    );
    await store.dismissCandidate(candidate.value!.candidateId);

    const legacyFingerprint = 'proactive:rent|task|pay the rent|tomorrow';
    final legacyStore = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final legacyCandidate = (legacyStore['candidates'] as List<dynamic>).single as Map<String, dynamic>;
    legacyCandidate['fingerprint'] = legacyFingerprint;
    await file.writeAsString(jsonEncode(legacyStore));

    final reopened = await PrivacyStore.open(directory);
    final migratedStore = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final migratedCandidate = (migratedStore['candidates'] as List<dynamic>).single as Map<String, dynamic>;
    final migratedFingerprint = migratedCandidate['fingerprint'] as String;
    expect(migratedFingerprint, matches(RegExp(r'^sha256:[0-9a-f]{64}$')));
    expect(migratedFingerprint, isNot(contains('pay the rent')));

    final duplicate = await reopened.addIntelligenceCandidate(
      sourceRef: 'proactive:rent',
      suggestedType: 'task',
      title: 'Pay the rent',
      excerpt: 'Rent is due',
      uncertainty: 0.1,
      proposedTimeText: 'tomorrow',
    );
    expect(duplicate.value!.candidateId, candidate.value!.candidateId);
    expect(duplicate.value!.tombstone, isTrue);
    expect(await reopened.pendingCandidates(), isEmpty);
  });
}
