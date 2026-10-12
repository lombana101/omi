/// Diagnostics may record only these kinds. Free text, tokens, and transcripts are rejected.
const privacyDiagnosticKinds = <String>{
  'state',
  'socket_close',
  'ack_timeout',
  'malformed',
  'mismatch',
  'codec',
  'interrupted',
  'completed',
  'probe',
  'retention_set',
  'deleted',
  'store_open',
  'terminal_persist_failed',
  'background_stop',
};

bool privacyDiagnosticKindAllowed(String kind) {
  if (!privacyDiagnosticKinds.contains(kind)) return false;
  if (kind.contains(' ')) return false;
  return true;
}

/// True when a log line would leak a credential or transcript. Callers must drop it.
bool privacyLogContainsSensitive({required String line, String? transcript, String? bearer}) {
  if (transcript != null && transcript.isNotEmpty && line.contains(transcript)) return true;
  if (bearer != null && bearer.isNotEmpty && line.contains(bearer)) return true;
  final lower = line.toLowerCase();
  if (lower.contains('bearer ') && lower.contains('secret')) return true;
  return false;
}
