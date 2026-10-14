import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The independently configured Ubuntu Personal Intelligence endpoint.
///
/// [ownerMappingId] is only a routing assertion required by the Ubuntu
/// service. The server pins it to the bearer token and remains the authority
/// for owner identity.
class PrivacyIntelligenceCredentials {
  PrivacyIntelligenceCredentials({
    required String baseUrl,
    required String ownerMappingId,
    required String bearerToken,
  })  : baseUri = _requireBaseUri(baseUrl),
        ownerMappingId = _requireOwnerMappingId(ownerMappingId),
        bearerToken = _requireBearerToken(bearerToken);

  final Uri baseUri;
  final String ownerMappingId;
  final String bearerToken;

  String get baseUrl => baseUri.toString();

  @override
  String toString() =>
      'PrivacyIntelligenceCredentials(baseUrl: <redacted>, ownerMappingId: <redacted>, bearerToken: <redacted>)';
}

abstract interface class PrivacyIntelligenceCredentialSource {
  Future<PrivacyIntelligenceCredentials?> read();
}

/// Stores the Personal Intelligence configuration separately from capture/STT
/// credentials. All three values live in the platform secure store; in
/// particular, the bearer token is never placed in SharedPreferences.
class PrivacyIntelligenceCredentialStore implements PrivacyIntelligenceCredentialSource {
  PrivacyIntelligenceCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
              ),
            );

  static const baseUrlKey = 'omi_privacy_intelligence_base_url';
  static const ownerMappingIdKey = 'omi_privacy_intelligence_owner_mapping_id';
  static const bearerTokenKey = 'omi_privacy_intelligence_bearer_token';

  final FlutterSecureStorage _storage;

  Future<void> write({
    required String baseUrl,
    required String ownerMappingId,
    required String bearerToken,
  }) async {
    final credentials = PrivacyIntelligenceCredentials(
      baseUrl: baseUrl,
      ownerMappingId: ownerMappingId,
      bearerToken: bearerToken,
    );
    // Remove the old bearer before changing routing configuration, then write
    // the new bearer last. Any interrupted update is therefore fail-closed
    // instead of combining a new URL/owner pair with an old token.
    await _storage.delete(key: bearerTokenKey);
    await _storage.write(key: baseUrlKey, value: credentials.baseUrl);
    await _storage.write(key: ownerMappingIdKey, value: credentials.ownerMappingId);
    await _storage.write(key: bearerTokenKey, value: credentials.bearerToken);
  }

  @override
  Future<PrivacyIntelligenceCredentials?> read() async {
    final values = await Future.wait<String?>([
      _storage.read(key: baseUrlKey),
      _storage.read(key: ownerMappingIdKey),
      _storage.read(key: bearerTokenKey),
    ]);
    if (values.every((value) => value == null || value.isEmpty)) return null;
    if (values.any((value) => value == null || value.isEmpty)) {
      throw const PrivacyIntelligenceConfigurationException('incomplete_credentials');
    }
    return PrivacyIntelligenceCredentials(
      baseUrl: values[0]!,
      ownerMappingId: values[1]!,
      bearerToken: values[2]!,
    );
  }

  Future<void> clear() async {
    await Future.wait<void>([
      _storage.delete(key: baseUrlKey),
      _storage.delete(key: ownerMappingIdKey),
      _storage.delete(key: bearerTokenKey),
    ]);
  }
}

class PrivacyIntelligenceConfigurationException implements Exception {
  const PrivacyIntelligenceConfigurationException(this.code);

  final String code;

  @override
  String toString() => 'PrivacyIntelligenceConfigurationException($code)';
}

Uri? validatePrivacyIntelligenceBaseUrl(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty || value.contains(RegExp(r'[\x00-\x1f\x7f]'))) return null;
  final parsed = Uri.tryParse(value);
  if (parsed == null || parsed.host.isEmpty || parsed.userInfo.isNotEmpty || parsed.hasQuery || parsed.hasFragment) {
    return null;
  }
  final loopback = parsed.host == '127.0.0.1' || parsed.host == 'localhost' || parsed.host == '::1';
  if (parsed.scheme != 'https' && !(parsed.scheme == 'http' && loopback)) return null;
  final normalizedPath = parsed.path == '/' ? '' : parsed.path.replaceFirst(RegExp(r'/+$'), '');
  return parsed.replace(path: normalizedPath);
}

Uri _requireBaseUri(String raw) {
  final uri = validatePrivacyIntelligenceBaseUrl(raw);
  if (uri == null) throw const PrivacyIntelligenceConfigurationException('invalid_base_url');
  return uri;
}

String _requireOwnerMappingId(String raw) {
  final value = raw.trim();
  if (!RegExp(r'^[A-Za-z0-9._:@-]{1,200}$').hasMatch(value)) {
    throw const PrivacyIntelligenceConfigurationException('invalid_owner_mapping_id');
  }
  return value;
}

String _requireBearerToken(String raw) {
  final value = raw.trim();
  if (!RegExp(r'^[A-Za-z0-9._~-]{24,256}$').hasMatch(value)) {
    throw const PrivacyIntelligenceConfigurationException('invalid_bearer_token');
  }
  return value;
}
