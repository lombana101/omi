import 'package:omi/services/privacy_capture/privacy_capture_config.dart';
import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';

enum PrivacyProbeResult { authenticated, authenticationFailed, networkFailed, notConfigured }

class PrivacyProbeOutcome {
  const PrivacyProbeOutcome(this.result);

  final PrivacyProbeResult result;

  String get label {
    switch (result) {
      case PrivacyProbeResult.authenticated:
        return 'Connected. Bearer accepted. No capture started.';
      case PrivacyProbeResult.authenticationFailed:
        return 'Authentication failed.';
      case PrivacyProbeResult.networkFailed:
        return 'Network failed.';
      case PrivacyProbeResult.notConfigured:
        return 'Save a token before testing.';
    }
  }
}

PrivacyProbeResult classifyProbeFailure(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('401') || text.contains('403') || text.contains('unauthorized') || text.contains('1008')) {
    return PrivacyProbeResult.authenticationFailed;
  }
  return PrivacyProbeResult.networkFailed;
}

/// Opens `/live` with the bearer header and closes before any StartCapture frame.
Future<PrivacyProbeOutcome> probePrivacyConnection({
  required PrivacyCredentialStore credentials,
  required Future<PrivacySocketSession> Function({required Uri url, required String authorizationHeader}) connect,
  PrivacyCaptureConfig config = const PrivacyCaptureConfig(),
}) async {
  final stored = await credentials.read();
  final token = stored?.bearerToken.trim() ?? '';
  final url = validatePrivacyLiveUrl(stored?.url, config: config);
  if (token.isEmpty || url == null) return const PrivacyProbeOutcome(PrivacyProbeResult.notConfigured);
  PrivacySocketSession? session;
  try {
    session = await connect(url: url, authorizationHeader: 'Bearer $token');
  } catch (error) {
    return PrivacyProbeOutcome(classifyProbeFailure(error));
  }
  await session.close();
  return const PrivacyProbeOutcome(PrivacyProbeResult.authenticated);
}
