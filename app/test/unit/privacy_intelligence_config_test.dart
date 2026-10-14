import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/privacy_capture/privacy_intelligence_config.dart';

const _token = '0123456789abcdefghijklmnop';
String _repeat(String value, int count) => List<String>.filled(count, value).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stores intelligence configuration separately in secure storage', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'omi_privacy_ws_url': 'wss://capture.example/live',
      'omi_privacy_bearer': 'capture-token',
    });
    const secure = FlutterSecureStorage();
    final store = PrivacyIntelligenceCredentialStore(storage: secure);

    await store.write(
      baseUrl: 'https://ubuntu.tailnet.ts.net/personal-intelligence/',
      ownerMappingId: 'owner_01',
      bearerToken: _token,
    );

    final credentials = await store.read();
    expect(credentials, isNotNull);
    expect(credentials!.baseUrl, 'https://ubuntu.tailnet.ts.net/personal-intelligence');
    expect(credentials.ownerMappingId, 'owner_01');
    expect(credentials.bearerToken, _token);
    expect(await secure.read(key: PrivacyIntelligenceCredentialStore.bearerTokenKey), _token);
    expect(await secure.read(key: 'omi_privacy_bearer'), 'capture-token');

    await store.clear();
    expect(await store.read(), isNull);
    expect(await secure.read(key: 'omi_privacy_bearer'), 'capture-token');
  });

  test('partial secure configuration fails closed', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      PrivacyIntelligenceCredentialStore.baseUrlKey: 'https://ubuntu.tailnet.ts.net',
      PrivacyIntelligenceCredentialStore.ownerMappingIdKey: 'owner_01',
    });
    final store = PrivacyIntelligenceCredentialStore(storage: const FlutterSecureStorage());

    await expectLater(
      store.read(),
      throwsA(
        isA<PrivacyIntelligenceConfigurationException>()
            .having((error) => error.code, 'code', 'incomplete_credentials'),
      ),
    );
  });

  test('base URL requires TLS except on loopback and excludes URL credentials', () {
    expect(validatePrivacyIntelligenceBaseUrl('https://ubuntu.tailnet.ts.net:8443/api/'),
        Uri.parse('https://ubuntu.tailnet.ts.net:8443/api'));
    expect(validatePrivacyIntelligenceBaseUrl('http://127.0.0.1:8792'), Uri.parse('http://127.0.0.1:8792'));
    expect(validatePrivacyIntelligenceBaseUrl('http://localhost:8792'), Uri.parse('http://localhost:8792'));
    expect(validatePrivacyIntelligenceBaseUrl('http://ubuntu.tailnet.ts.net:8792'), isNull);
    expect(validatePrivacyIntelligenceBaseUrl('https://token@ubuntu.tailnet.ts.net'), isNull);
    expect(validatePrivacyIntelligenceBaseUrl('https://ubuntu.tailnet.ts.net?token=secret'), isNull);
  });

  test('credentials reject unsafe headers and redact their representation', () {
    expect(
      () => PrivacyIntelligenceCredentials(
        baseUrl: 'https://ubuntu.tailnet.ts.net',
        ownerMappingId: 'owner\r\nInjected: value',
        bearerToken: _token,
      ),
      throwsA(isA<PrivacyIntelligenceConfigurationException>()),
    );
    expect(
      () => PrivacyIntelligenceCredentials(
        baseUrl: 'https://ubuntu.tailnet.ts.net',
        ownerMappingId: 'owner+alias',
        bearerToken: _token,
      ),
      throwsA(isA<PrivacyIntelligenceConfigurationException>()),
    );
    for (final token in <String>[
      'too-short',
      _repeat('a', 23),
      _repeat('a', 257),
      '0123456789abcdefghijklmn+p',
      '0123456789abcdefghijklmn/p',
    ]) {
      expect(
        () => PrivacyIntelligenceCredentials(
          baseUrl: 'https://ubuntu.tailnet.ts.net',
          ownerMappingId: 'owner_01',
          bearerToken: token,
        ),
        throwsA(isA<PrivacyIntelligenceConfigurationException>()),
      );
    }
    expect(
      PrivacyIntelligenceCredentials(
        baseUrl: 'https://ubuntu.tailnet.ts.net',
        ownerMappingId: '${_repeat('a', 199)}@',
        bearerToken: _repeat('a', 24),
      ).ownerMappingId.length,
      200,
    );
    expect(
      PrivacyIntelligenceCredentials(
        baseUrl: 'https://ubuntu.tailnet.ts.net',
        ownerMappingId: 'owner_01',
        bearerToken: _repeat('z', 256),
      ).bearerToken.length,
      256,
    );
    expect(
      () => PrivacyIntelligenceCredentials(
        baseUrl: 'https://ubuntu.tailnet.ts.net',
        ownerMappingId: _repeat('a', 201),
        bearerToken: _token,
      ),
      throwsA(isA<PrivacyIntelligenceConfigurationException>()),
    );
    final credentials = PrivacyIntelligenceCredentials(
      baseUrl: 'https://private-host.example',
      ownerMappingId: 'private-owner',
      bearerToken: _token,
    );
    expect(credentials.toString(), isNot(contains('private-host')));
    expect(credentials.toString(), isNot(contains('private-owner')));
    expect(credentials.toString(), isNot(contains(_token)));
  });
}
