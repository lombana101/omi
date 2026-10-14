import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:omi/services/privacy_capture/privacy_intelligence_config.dart';
import 'package:omi/services/privacy_capture/privacy_intelligence_models.dart';

class PrivacyIntelligenceTimeouts {
  const PrivacyIntelligenceTimeouts({
    this.credentialLookup = const Duration(seconds: 3),
    this.read = const Duration(seconds: 15),
    this.model = const Duration(seconds: 55),
    this.write = const Duration(seconds: 25),
  });

  final Duration credentialLookup;
  final Duration read;
  final Duration model;
  final Duration write;

  void validate() {
    if (credentialLookup <= Duration.zero ||
        read <= Duration.zero ||
        model <= Duration.zero ||
        write <= Duration.zero) {
      throw ArgumentError('privacy intelligence timeouts must be positive');
    }
  }
}

enum PrivacyIntelligenceFailureKind {
  notConfigured,
  credentialsUnavailable,
  timeout,
  transport,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  rateLimited,
  requestRejected,
  serviceUnavailable,
  invalidResponse,
}

/// A deliberately content-free client failure.
///
/// It never contains the endpoint, owner mapping, token, request body, server
/// body, or transport error text, so callers can safely show/log [toString].
class PrivacyIntelligenceClientException implements Exception {
  const PrivacyIntelligenceClientException({required this.kind, required this.operation, this.statusCode});

  final PrivacyIntelligenceFailureKind kind;
  final String operation;
  final int? statusCode;

  @override
  String toString() =>
      'PrivacyIntelligenceClientException(kind: ${kind.name}, operation: $operation${statusCode == null ? '' : ', statusCode: $statusCode'})';
}

class PrivacyIntelligenceClient {
  PrivacyIntelligenceClient({
    required PrivacyIntelligenceCredentialSource credentials,
    http.Client? httpClient,
    this.timeouts = const PrivacyIntelligenceTimeouts(),
    this.maxResponseBytes = 2 * 1024 * 1024,
  })  : _credentials = credentials,
        _http = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null {
    timeouts.validate();
    if (maxResponseBytes < 1024) throw ArgumentError.value(maxResponseBytes, 'maxResponseBytes');
  }

  final PrivacyIntelligenceCredentialSource _credentials;
  final http.Client _http;
  final bool _ownsHttpClient;
  final PrivacyIntelligenceTimeouts timeouts;
  final int maxResponseBytes;

  Future<PrivacyIntelligenceIntegrationStatus> integrationStatus() async {
    final json = await _objectRequest(
      operation: 'integration_status',
      method: 'GET',
      path: '/v1/integrations',
      timeout: timeouts.read,
    );
    return _decode('integration_status', () => PrivacyIntelligenceIntegrationStatus.fromJson(json));
  }

  Future<List<PrivacyIntelligenceCalendar>> calendars() async {
    final rows = await _listRequest(
      operation: 'calendars',
      method: 'GET',
      path: '/v1/timetree/calendars',
      timeout: timeouts.read,
    );
    return _decode(
      'calendars',
      () => List<PrivacyIntelligenceCalendar>.unmodifiable(rows.map(PrivacyIntelligenceCalendar.fromJson)),
    );
  }

  Future<List<PrivacyIntelligenceEvent>> events({PrivacyIntelligenceEventQuery? query}) async {
    final rows = await _listRequest(
      operation: 'events',
      method: 'GET',
      path: '/v1/timetree/events',
      query: (query ?? PrivacyIntelligenceEventQuery()).toQueryParameters(),
      timeout: timeouts.read,
    );
    return _decode(
      'events',
      () => List<PrivacyIntelligenceEvent>.unmodifiable(rows.map(PrivacyIntelligenceEvent.fromJson)),
    );
  }

  Future<PrivacyIntelligenceExtractionResponse> extract(PrivacyIntelligenceExtractionRequest request) async {
    final json = await _objectRequest(
      operation: 'extract',
      method: 'POST',
      path: '/v1/intelligence/extract',
      body: request.toJson(),
      timeout: timeouts.model,
    );
    return _decode('extract', () => PrivacyIntelligenceExtractionResponse.fromJson(json));
  }

  Future<PrivacyIntelligenceAssistantResponse> assistant(PrivacyIntelligenceAssistantRequest request) async {
    final json = await _objectRequest(
      operation: 'assistant',
      method: 'POST',
      path: '/v1/assistant',
      body: request.toJson(),
      timeout: timeouts.model,
    );
    return _decode('assistant', () => PrivacyIntelligenceAssistantResponse.fromJson(json));
  }

  /// Creates a server-side preview only. This never writes to TimeTree.
  /// The caller must render the returned exact preview and obtain explicit
  /// confirmation before invoking [confirmCalendarOperation].
  Future<PrivacyIntelligenceCalendarOperationPreview> prepareCalendarOperation(
    PrivacyIntelligenceCalendarOperationRequest request,
  ) async {
    final json = await _objectRequest(
      operation: 'prepare_calendar_operation',
      method: 'POST',
      path: '/v1/timetree/operations/prepare',
      body: request.toJson(),
      timeout: timeouts.write,
    );
    return _decode(
      'prepare_calendar_operation',
      () => PrivacyIntelligenceCalendarOperationPreview.fromJson(json),
    );
  }

  /// Sends exactly one confirmation request. Transport failures and timeouts
  /// are not retried because the provider outcome may be uncertain.
  Future<PrivacyIntelligenceCalendarOperationOutcome> confirmCalendarOperation(String operationId) async {
    _validateOperationId(operationId);
    final json = await _objectRequest(
      operation: 'confirm_calendar_operation',
      method: 'POST',
      path: '/v1/timetree/operations/confirm',
      body: <String, Object?>{'operation_id': operationId},
      timeout: timeouts.write,
    );
    return _decode(
      'confirm_calendar_operation',
      () => PrivacyIntelligenceCalendarOperationOutcome.fromJson(json),
    );
  }

  /// Reconciles a pending or uncertain confirmation without issuing a write.
  Future<PrivacyIntelligenceCalendarOperationOutcome> calendarOperationStatus(String operationId) async {
    _validateOperationId(operationId);
    final json = await _objectRequest(
      operation: 'calendar_operation_status',
      method: 'GET',
      path: '/v1/timetree/operations/$operationId',
      timeout: timeouts.read,
    );
    return _decode(
      'calendar_operation_status',
      () => PrivacyIntelligenceCalendarOperationOutcome.fromJson(json),
    );
  }

  void close() {
    if (_ownsHttpClient) _http.close();
  }

  Future<Map<String, Object?>> _objectRequest({
    required String operation,
    required String method,
    required String path,
    required Duration timeout,
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final decoded = await _request(
      operation: operation,
      method: method,
      path: path,
      query: query,
      body: body,
      timeout: timeout,
    );
    if (decoded is! Map) {
      throw PrivacyIntelligenceClientException(
        kind: PrivacyIntelligenceFailureKind.invalidResponse,
        operation: operation,
      );
    }
    try {
      return _stringObjectMap(decoded);
    } catch (_) {
      throw PrivacyIntelligenceClientException(
        kind: PrivacyIntelligenceFailureKind.invalidResponse,
        operation: operation,
      );
    }
  }

  Future<List<Map<String, Object?>>> _listRequest({
    required String operation,
    required String method,
    required String path,
    required Duration timeout,
    Map<String, String>? query,
  }) async {
    final decoded = await _request(
      operation: operation,
      method: method,
      path: path,
      query: query,
      timeout: timeout,
    );
    if (decoded is! List) {
      throw PrivacyIntelligenceClientException(
        kind: PrivacyIntelligenceFailureKind.invalidResponse,
        operation: operation,
      );
    }
    try {
      return decoded.map((row) {
        if (row is! Map) throw const FormatException('invalid row');
        return _stringObjectMap(row);
      }).toList(growable: false);
    } catch (_) {
      throw PrivacyIntelligenceClientException(
        kind: PrivacyIntelligenceFailureKind.invalidResponse,
        operation: operation,
      );
    }
  }

  Future<Object?> _request({
    required String operation,
    required String method,
    required String path,
    required Duration timeout,
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final credentials = await _readCredentials(operation);
    final request = http.Request(method, _endpoint(credentials.baseUri, path, query));
    // Never forward private owner credentials through an HTTP redirect. A
    // moved endpoint must be saved explicitly as new configuration.
    request.followRedirects = false;
    request.headers.addAll(<String, String>{
      'Accept': 'application/json',
      'Authorization': 'Bearer ${credentials.bearerToken}',
      'X-PIS-Owner-Uid': credentials.ownerMappingId,
      if (body != null) 'Content-Type': 'application/json',
    });
    if (body != null) request.bodyBytes = utf8.encode(jsonEncode(body));

    try {
      final response = await _sendOnce(request, operation).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PrivacyIntelligenceClientException(
          kind: _failureKindForStatus(response.statusCode),
          operation: operation,
          statusCode: response.statusCode,
        );
      }
      try {
        return jsonDecode(response.body);
      } catch (_) {
        throw PrivacyIntelligenceClientException(
          kind: PrivacyIntelligenceFailureKind.invalidResponse,
          operation: operation,
          statusCode: response.statusCode,
        );
      }
    } on TimeoutException {
      throw PrivacyIntelligenceClientException(kind: PrivacyIntelligenceFailureKind.timeout, operation: operation);
    } on PrivacyIntelligenceClientException {
      rethrow;
    } catch (_) {
      // Discard transport exception text: it may contain a private URL.
      throw PrivacyIntelligenceClientException(kind: PrivacyIntelligenceFailureKind.transport, operation: operation);
    }
  }

  Future<_PrivacyIntelligenceRawResponse> _sendOnce(http.Request request, String operation) async {
    final streamed = await _http.send(request);
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in streamed.stream) {
      length += chunk.length;
      if (length > maxResponseBytes) {
        throw PrivacyIntelligenceClientException(
          kind: PrivacyIntelligenceFailureKind.invalidResponse,
          operation: operation,
          statusCode: streamed.statusCode,
        );
      }
      bytes.add(chunk);
    }
    String body;
    try {
      body = utf8.decode(bytes.takeBytes());
    } catch (_) {
      throw PrivacyIntelligenceClientException(
        kind: PrivacyIntelligenceFailureKind.invalidResponse,
        operation: operation,
        statusCode: streamed.statusCode,
      );
    }
    return _PrivacyIntelligenceRawResponse(streamed.statusCode, body);
  }

  Future<PrivacyIntelligenceCredentials> _readCredentials(String operation) async {
    try {
      final credentials = await _credentials.read().timeout(timeouts.credentialLookup);
      if (credentials == null) {
        throw PrivacyIntelligenceClientException(
          kind: PrivacyIntelligenceFailureKind.notConfigured,
          operation: operation,
        );
      }
      return credentials;
    } on TimeoutException {
      throw PrivacyIntelligenceClientException(
        kind: PrivacyIntelligenceFailureKind.credentialsUnavailable,
        operation: operation,
      );
    } on PrivacyIntelligenceClientException {
      rethrow;
    } catch (_) {
      throw PrivacyIntelligenceClientException(
        kind: PrivacyIntelligenceFailureKind.credentialsUnavailable,
        operation: operation,
      );
    }
  }

  T _decode<T>(String operation, T Function() decode) {
    try {
      return decode();
    } catch (_) {
      throw PrivacyIntelligenceClientException(
        kind: PrivacyIntelligenceFailureKind.invalidResponse,
        operation: operation,
      );
    }
  }
}

class _PrivacyIntelligenceRawResponse {
  const _PrivacyIntelligenceRawResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

Uri _endpoint(Uri base, String path, Map<String, String>? query) {
  final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
  final suffix = path.startsWith('/') ? path : '/$path';
  return base.replace(
    path: '$prefix$suffix',
    queryParameters: query == null || query.isEmpty ? null : query,
  );
}

Map<String, Object?> _stringObjectMap(Map<dynamic, dynamic> map) {
  if (map.keys.any((key) => key is! String)) throw const FormatException('invalid object');
  return map.map((key, value) => MapEntry(key as String, value));
}

PrivacyIntelligenceFailureKind _failureKindForStatus(int statusCode) {
  return switch (statusCode) {
    400 || 422 => PrivacyIntelligenceFailureKind.requestRejected,
    401 => PrivacyIntelligenceFailureKind.unauthorized,
    403 => PrivacyIntelligenceFailureKind.forbidden,
    404 => PrivacyIntelligenceFailureKind.notFound,
    409 => PrivacyIntelligenceFailureKind.conflict,
    429 => PrivacyIntelligenceFailureKind.rateLimited,
    >= 500 => PrivacyIntelligenceFailureKind.serviceUnavailable,
    _ => PrivacyIntelligenceFailureKind.requestRejected,
  };
}

void _validateOperationId(String value) {
  if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) {
    throw ArgumentError.value('<redacted>', 'operationId', 'invalid format');
  }
}
