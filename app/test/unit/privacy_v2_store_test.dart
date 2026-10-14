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
    expect((await store.pendingCandidates()).single.sourceRef, 'manual:one');
    expect((await store.pendingCandidates()).single.proposedTimeText, 'next Friday');

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
}
