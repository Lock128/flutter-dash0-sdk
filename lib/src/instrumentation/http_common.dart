import 'dart:async';

import '../client.dart';
import '../ignore_rules.dart';
import '../options.dart';
import '../propagation.dart';
import '../semantic_conventions.dart' as sc;
import '../span.dart';
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

const Object _handledKey = #dash0HttpHandled;

/// True while running inside [runMarkedAsHandled]. Requests made there are
/// already instrumented by `Dash0HttpClient`, so `Dash0HttpOverrides` skips
/// them to avoid duplicate spans.
bool isHttpHandledByDash0() => Zone.current[_handledKey] == true;

/// Runs [body] with the marker read by [isHttpHandledByDash0] set.
R runMarkedAsHandled<R>(R Function() body) =>
    runZoned(body, zoneValues: {_handledKey: true});

/// An HTTP client span in progress together with its timer.
class HttpCall {
  HttpCall._(this.client, this.span, this.method, this.uri, this._watch);

  final Dash0Client client;
  final Dash0Span span;

  /// Normalized method.
  final String method;
  final Uri? uri;
  final Stopwatch _watch;
  bool _finished = false;

  /// Whether requests to [url] are recorded.
  static bool shouldInstrument(Dash0Client client, String url) =>
      client.isEnabled &&
      client.options.isEnabled(Dash0Instrumentation.http) &&
      !client.ignoreRules.isUrlIgnored(url);

  /// Starts the client span for a request.
  static HttpCall start(Dash0Client client, String originalMethod, String url) {
    final upper = originalMethod.toUpperCase();
    final method = _knownMethods.contains(upper) ? upper : _methodOther;
    final span = client.startSpan(
      'HTTP $method',
      kind: sc.spanKindClient,
      attributes: {
        ...urlAttributes(url, client.options.urlScrubber),
        sc.httpRequestMethod: method,
        if (method == _methodOther || originalMethod != upper)
          sc.httpRequestMethodOriginal: originalMethod,
      },
    );
    return HttpCall._(
        client, span, method, Uri.tryParse(url), Stopwatch()..start());
  }

  /// Trace context headers to add to the request, empty if no propagator
  /// matches.
  Map<String, String> propagationHeaders(String url) {
    final types = determinePropagatorTypes(client.options.propagators, url);
    if (types.isEmpty) return const {};
    return traceContextHeaders(types, span.traceId, span.spanId);
  }

  /// Captures headers matching `Dash0Options.headersToCapture`.
  void captureHeaders(Map<String, String> headers, {required bool request}) {
    final patterns = client.options.headersToCapture;
    if (patterns.isEmpty) return;
    final prefix = request ? sc.httpRequestHeader : sc.httpResponseHeader;
    headers.forEach((name, value) {
      if (matchesAny(patterns, name)) {
        span.setAttribute('$prefix.${name.toLowerCase()}', value);
      }
    });
  }

  /// Records status, size and error state of a response. Does not end the
  /// span.
  void setResponse(int statusCode, {int? contentLength, String? reason}) {
    span.setAttribute(sc.httpResponseStatusCode, statusCode);
    if (contentLength != null && contentLength >= 0) {
      span.setAttribute(sc.httpResponseBodySize, contentLength);
    }
    if (statusCode >= 400) {
      span.setAttribute(sc.errorType, statusCode.toString());
      span.setStatus(sc.spanStatusError, reason);
    }
  }

  /// Ends the span and records the duration metric. Only the first call has
  /// an effect. Pass [error] if the request failed.
  void finish({Object? error, StackTrace? stackTrace}) {
    if (_finished) return;
    _finished = true;
    try {
      if (error != null) {
        span.setAttribute(sc.errorType, error.runtimeType.toString());
        span.recordException(error, stackTrace);
        span.setStatus(sc.spanStatusError, _scrubMessage(error.toString()));
      }
      span.end();
      _watch.stop();
      final status = span.attributes[sc.httpResponseStatusCode];
      final errorType = span.attributes[sc.errorType];
      client.recordHttpClientDuration(
        _watch.elapsedMicroseconds / Duration.microsecondsPerSecond,
        {
          sc.httpRequestMethod: method,
          if (uri != null && uri!.host.isNotEmpty) sc.serverAddress: uri!.host,
          if (uri != null && uri!.hasPort) sc.serverPort: uri!.port,
          if (status != null) sc.httpResponseStatusCode: status,
          if (errorType != null) sc.errorType: errorType,
        },
      );
    } catch (_) {
      // Telemetry must never throw into the app.
    }
  }

  String _scrubMessage(String message) {
    return message.replaceAllMapped(
        RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://[^\s()]+'),
        (m) => scrubUrl(m[0]!, client.options.urlScrubber));
  }
}
