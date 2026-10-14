/// Client-side privacy capture settings. Protocol values come from
/// `deploy/PRIVACY_PROTOCOL.md`. Timeouts are local fail-closed limits, not
/// server fields.
class PrivacyCaptureConfig {
  const PrivacyCaptureConfig({
    this.ackTimeout = const Duration(seconds: 8),
    this.finalizationTimeout = const Duration(seconds: 55),
    this.policyRevision = 1,
    this.protocolVersion = 1,
    this.policyViolationCloseCode = 1008,
    this.loopbackPort = 8766,
    this.livePath = '/live',
  });

  final Duration ackTimeout;
  final Duration finalizationTimeout;
  final int policyRevision;
  final int protocolVersion;
  final int policyViolationCloseCode;
  final int loopbackPort;
  final String livePath;

  static const allowedPurposes = <String>{'personal_memory', 'self_voice_enrollment'};
  static const allowedConsentBases = <String>{'self_only', 'participants_consented'};
  static const defaultPurpose = 'personal_memory';
  static const defaultConsentBasis = 'self_only';
  static const quickGestureConsentBasis = 'self_only_quick_gesture';
  static const phoneManualCaptureOrigin = 'phone_manual_capture';
  static const pendantQuickCaptureOrigin = 'pendant_quick_capture';
  static const ackType = 'StartCaptureAck';
  static const startType = 'StartCapture';
  static const closeType = 'CloseStream';
  static const finalizingType = 'CaptureFinalizing';
  static const transcriptType = 'TranscriptResult';
  static const completeType = 'CaptureComplete';
  static const completeOutcomes = <String>{
    'transcribed',
    'no_speech',
    'processing_failed',
    'timeout',
    'delivery_failed',
  };
  static const stagingLiveUrl = 'wss://home-server.tailf58dfc.ts.net:8443/live';
  static const socketPingInterval = Duration(seconds: 20);
  static const successfulOutcomes = <String>{'transcribed', 'no_speech'};
  static const startCaptureFields = <String>[
    'type',
    'version',
    'capture_id',
    'purpose',
    'consent_basis',
    'policy_revision',
    'client_timestamp',
  ];
}

Uri? validatePrivacyLiveUrl(String? raw, {PrivacyCaptureConfig config = const PrivacyCaptureConfig()}) {
  if (raw == null || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.path != config.livePath) return null;
  final loopback = uri.host == '127.0.0.1' || uri.host == 'localhost';
  if (uri.scheme == 'ws' && !loopback) return null;
  if (uri.scheme != 'ws' && uri.scheme != 'wss') return null;
  if (uri.hasPort && uri.port == config.loopbackPort && !loopback) return null;
  return uri;
}
