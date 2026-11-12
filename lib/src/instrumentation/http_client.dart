import 'package:http/http.dart' as http;

import '../client.dart';
import '../debug.dart';
import '../ignore_rules.dart';
import '../options.dart';
import '../propagation.dart';
import '../semantic_conventions.dart' as sc;
import '../url_attributes.dart';

const _knownMethods = {
  'GET',
  'HEAD',
  'POST',
  'PUT',
  'DELETE',
  'CONNECT',
  'OPTIONS',
  'TRACE',
  'PATCH',
};
const _methodOther = '_OTHER';

/// A `package:http` client that creates a client span for every request,
/// mirroring the fetch instrumentation of dash0-sdk-web.
///
/// Span attributes follow the OpenTelemetry HTTP semantic conventions. Trace
/// context headers are added for URLs matched by
/// `Dash0Options.propagators`.
///
/// ```dart
/// final client = Dash0HttpClient(Dash0.client!);
/// await client.get(Uri.parse('https://api.example.com/items'));
/// ```
class Dash0HttpClient extends http.BaseClient {
  Dash0HttpClient(this._dash0, [http.Client? inner])
      : _inner = inner ?? http.Client();

  final Dash0Client _dash0;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    if (!_dash0.options.isEnabled(Dash0Instrumentation.http) ||
        _dash0.ignoreRules.isUrlIgnored(url)) {
      dash0Debug('Not creating span for request, URL ignored or disabled', url);
      return _inner.send(request);
    }

    final originalMethod = request.method;
    final upper = originalMethod.toUpperCase();
    final method = _knownMethods.contains(upper) ? upper : _methodOther;

    final span = _dash0.startSpan(
      'HTTP $method',
      kind: sc.spanKindClient,
      attributes: {
        ...urlAttributes(url, _dash0.options.urlScrubber),
        sc.httpRequestMethod: method,
        if (method == _methodOther || originalMethod != upper)
          sc.httpRequestMethodOriginal: originalMethod,
      },
    );

    try {
      final types = determinePropagatorTypes(_dash0.options.propagators, url);
      if (types.isNotEmpty) {
        request.headers
            .addAll(traceContextHeaders(types, span.traceId, span.spanId));
      }
      _captureHeaders(request.headers, sc.httpRequestHeader, span.setAttribute);
    } catch (e) {
      dash0Debug('Failed to prepare request instrumentation', e);
    }

    try {
      final response = await _inner.send(request);
      span.setAttribute(sc.httpResponseStatusCode, response.statusCode);
      final length = response.contentLength;
      if (length != null) span.setAttribute(sc.httpResponseBodySize, length);
      _captureHeaders(
          response.headers, sc.httpResponseHeader, span.setAttribute);
      if (response.statusCode >= 400) {
        span.setAttribute(sc.errorType, response.statusCode.toString());
        span.setStatus(sc.spanStatusError, response.reasonPhrase);
      }
      span.end();
      return response;
    } catch (e, st) {
      final scrubbedMessage = _scrubMessage(e.toString());
      span.setAttribute(sc.errorType, e.runtimeType.toString());
      span.recordException(e, st);
      span.setStatus(sc.spanStatusError, scrubbedMessage);
      span.end();
      rethrow;
    }
  }

  String _scrubMessage(String message) {
    return message.replaceAllMapped(
        RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://[^\s()]+'),
        (m) => scrubUrl(m[0]!, _dash0.options.urlScrubber));
  }

  void _captureHeaders(
    Map<String, String> headers,
    String prefix,
    void Function(String key, Object? value) set,
  ) {
    final patterns = _dash0.options.headersToCapture;
    if (patterns.isEmpty) return;
    headers.forEach((name, value) {
      if (matchesAny(patterns, name)) {
        set('$prefix.${name.toLowerCase()}', value);
      }
    });
  }

  @override
  void close() => _inner.close();
}
