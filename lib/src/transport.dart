import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'debug.dart';
import 'options.dart';

/// Sends OTLP/JSON payloads to the configured endpoints.
abstract class Dash0Transport {
  /// Sends [body] to [path] (`/v1/traces` or `/v1/logs`). Must not throw.
  Future<void> send(String path, Map<String, Object?> body);

  void close();
}

/// Default transport: POSTs JSON with a bearer token to all endpoints in
/// parallel. Failures are logged and dropped, there are no retries.
class HttpDash0Transport implements Dash0Transport {
  HttpDash0Transport(
    this.endpoints, {
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final List<Dash0Endpoint> endpoints;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  /// Builds the request URL for [endpoint] and [path].
  static Uri buildUri(Dash0Endpoint endpoint, String path) {
    final base = endpoint.url.endsWith('/')
        ? endpoint.url.substring(0, endpoint.url.length - 1)
        : endpoint.url;
    return Uri.parse('$base$path');
  }

  /// Request headers for [endpoint].
  static Map<String, String> buildHeaders(Dash0Endpoint endpoint) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${endpoint.authToken}',
        if (endpoint.dataset != null && endpoint.dataset!.isNotEmpty)
          'Dash0-Dataset': endpoint.dataset!,
      };

  @override
  Future<void> send(String path, Map<String, Object?> body) async {
    dash0Debug('Transmitting telemetry to $path', body);
    final String payload;
    try {
      payload = jsonEncode(body);
    } catch (e) {
      dash0Warn('Unable to encode telemetry for $path:', e);
      return;
    }
    await Future.wait(endpoints.map((endpoint) async {
      final uri = buildUri(endpoint, path);
      try {
        final response = await _client
            .post(uri, headers: buildHeaders(endpoint), body: payload)
            .timeout(timeout);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          dash0Warn('Failed to send telemetry to $uri: ${response.statusCode}');
        }
      } catch (e) {
        dash0Warn('Error sending telemetry to $uri:', e);
      }
    }));
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
