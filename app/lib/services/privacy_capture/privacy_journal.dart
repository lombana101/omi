import 'dart:io';

import 'package:flutter/services.dart';

import 'package:omi/services/privacy_capture/privacy_capture_config.dart';
import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';
import 'package:omi/services/privacy_capture/privacy_models.dart';
import 'package:omi/services/privacy_capture/privacy_store.dart';

class PrivacyStoreJournal implements PrivacyCaptureJournal {
  PrivacyStoreJournal(this.store, {this.uncertain = false});

  final PrivacyStore store;
  final bool uncertain;

  @override
  Future<void> onAuthorizing({
    required String captureId,
    required String purpose,
    required String ownerPurpose,
    required String consentBasis,
    required String wireConsentBasis,
    required DateTime consentAssertedAt,
    String? configuredPurpose,
    required String captureOrigin,
    PrivacyRetentionChoice? retentionChoice,
    required DateTime at,
    required int protocolVersion,
    required int policyRevision,
  }) async {
    final result = await store.openSession(
      captureId: captureId,
      purpose: purpose,
      ownerPurpose: ownerPurpose,
      consentBasis: consentBasis,
      wireConsentBasis: wireConsentBasis,
      consentAssertedAt: consentAssertedAt,
      configuredPurpose: configuredPurpose,
      captureOrigin: captureOrigin,
      retentionChoice: retentionChoice,
      protocolVersion: protocolVersion,
      policyRevision: policyRevision,
      at: at,
    );
    if (!result.ok) throw StateError('session_open_failed');
  }

  @override
  Future<void> onRecording(String captureId) => store.markRecording(captureId);

  @override
  Future<bool> onTranscript(PrivacyTranscript transcript) {
    return store.upsertChunk(
      captureId: transcript.captureId,
      sequence: transcript.sequence,
      machineText: transcript.text,
      startSeconds: transcript.startSeconds,
      endSeconds: transcript.endSeconds,
      uncertain: uncertain,
    );
  }

  @override
  Future<void> onTerminal({
    required String captureId,
    required String outcome,
    required bool incomplete,
    required DateTime at,
  }) {
    return store.markTerminal(
      captureId: captureId,
      outcome: outcome,
      incomplete: incomplete || !PrivacyCaptureConfig.successfulOutcomes.contains(outcome),
      at: at,
      failureClass: incomplete ? outcome : null,
    );
  }
}

class PrivacyFileProtection {
  static const channel = MethodChannel('com.omi.privacy_capture/files');

  static Future<void> protect(String path) async {
    if (!Platform.isIOS) throw const PrivacyStoreUnavailable();
    final ok = await channel.invokeMethod<bool>('protect', <String, String>{'path': path});
    if (ok != true) throw const PrivacyStoreUnavailable();
  }
}
