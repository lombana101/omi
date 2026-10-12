/// Owner-only experiment limits. These are not settled project retention policy.
class PrivacyActionConfig {
  const PrivacyActionConfig._();

  static const schemaVersion = 1;
  static const excerptMaxChars = 160;
  static const candidateTtl = Duration(hours: 48);
  static const diagnosticCap = 40;
  static const extractorVersion = 'deterministic-v1';
  static const extractorKind = 'deterministic_commitment';
  static const retentionNote = 'Owner-only experiment choice. Not settled project policy.';
  static const hours24 = Duration(hours: 24);
  static const days7 = Duration(days: 7);
  static const remoteDeletionStatus = 'remote_deletion_unavailable';
  static const localDeletionStatus = 'deleted_from_this_phone';
}
