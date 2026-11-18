import 'dart:async';

import '../client.dart';
import '../ignore_rules.dart';
import '../options.dart';
import '../propagation.dart';
import '../semantic_conventions.dart' as sc;
import '../span.dart';
import '../url_attributes.dart';
import 'graphql.dart';

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
  Dash0GraphQLOperation? _operation;

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
  Map<String, String> propagationHeaders(String url, {String? pageOrigin}) {
    final types = determinePropagatorTypes(
      client.options.propagators,
      url,
      pageOrigin: pageOrigin ?? currentPageOrigin,
    );
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

  /// Names the span after a GraphQL operation and adds its attributes. Only
  /// the name and type are recorded, never the query or variables.
  void setGraphQLOperation(Dash0GraphQLOperation operation) {
    if (_finished) return;
    _operation = operation;
    final name = operation.name;
    if (name != null) {
      span.setAttribute(sc.graphQLOperationName, name);
      span.updateName('HTTP $method $name');
    }
    span.setAttribute(sc.graphQLOperationType, operation.type);
  }

  /// Marks the span as failed because a response with a successful HTTP
  /// status contained GraphQL errors. The error messages are not recorded.
  void setGraphQLErrors(Dash0GraphQLErrors errors) {
    if (_finished) return;
    span.setAttribute(sc.errorType, errors.type);
    span.setStatus(
      sc.spanStatusError,
      'GraphQL response contained ${errors.count} error(s): ${errors.type}',
    );
  }

  /// Ends the span and records the duration metric. Only the first call has
  /// an effect. Pass [error] if the request failed.
  void finish({Object? error, StackTrace? stackTrace}) {
    if (_finished) return;
    _finished = true;
    try {
      if (error != null && _isAbort(error)) {
        // Cancelled by the app, not a failure, like aborted fetches in the
        // web SDK.
        span.setAttribute(sc.webRequestCancelled, true);
      } else if (error != null) {
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
      final op = _operation;
      if (op != null) {
        client.recordGraphQLDuration(
          _watch.elapsedMicroseconds / Duration.microsecondsPerSecond,
          {
            if (op.name != null) sc.graphQLOperationName: op.name,
            sc.graphQLOperationType: op.type,
            if (errorType != null) sc.errorType: errorType,
            if (uri != null && uri!.host.isNotEmpty)
              sc.serverAddress: uri!.host,
          },
        );
      }
    } catch (_) {
      // Telemetry must never throw into the app.
    }
  }

  /// `RequestAbortedException` of package:http 1.5 and later, matched by name
  /// to keep compatibility with older versions.
  static bool _isAbort(Object error) =>
      error.runtimeType.toString() == 'RequestAbortedException';

  String _scrubMessage(String message) {
    return message.replaceAllMapped(
        RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://[^\s()]+'),
        (m) => scrubUrl(m[0]!, client.options.urlScrubber));
  }
}

/// A client span for a request made with an HTTP stack that the SDK cannot
/// instrument itself, for example the client of the AWS Amplify plugins.
///
/// Create it with `Dash0.startHttpRequest`, add [propagationHeaders] to the
/// request, report the response with [setResponse] and always call [finish],
/// also when the request failed. Mirrors the fetch instrumentation of
/// dash0-sdk-web. None of the methods throw.
class Dash0HttpSpan {
  Dash0HttpSpan._(this._call, this._url);

  final HttpCall _call;
  final String _url;

  /// Starts a span, or returns null if the SDK is disabled, HTTP
  /// instrumentation is off or [url] is ignored.
  static Dash0HttpSpan? start(Dash0Client? client, String method, String url) {
    try {
      if (client == null || !HttpCall.shouldInstrument(client, url)) {
        return null;
      }
      return Dash0HttpSpan._(HttpCall.start(client, method, url), url);
    } catch (_) {
      return null;
    }
  }

  /// The span, for custom attributes.
  Dash0Span get span => _call.span;

  /// Trace context headers to add to the request. Empty if no propagator
  /// matches the URL.
  Map<String, String> propagationHeaders() {
    try {
      return _call.propagationHeaders(_url);
    } catch (_) {
      return const {};
    }
  }

  /// Captures headers matching `Dash0Options.headersToCapture`.
  void captureHeaders(Map<String, String> headers, {required bool request}) {
    try {
      _call.captureHeaders(headers, request: request);
    } catch (_) {
      // Telemetry must never throw into the app.
    }
  }

  /// Records the response. Status codes of 400 and above set the span status
  /// to error.
  void setResponse(int statusCode, {int? contentLength, String? reason}) {
    try {
      _call.setResponse(statusCode,
          contentLength: contentLength, reason: reason);
    } catch (_) {
      // Telemetry must never throw into the app.
    }
  }

  /// Names the span after a GraphQL operation, see
  /// [Dash0GraphQL.inspectRequestBody]. Call before [finish].
  void setGraphQLOperation(Dash0GraphQLOperation? operation) {
    try {
      if (operation != null) _call.setGraphQLOperation(operation);
    } catch (_) {
      // Telemetry must never throw into the app.
    }
  }

  /// Marks the span as failed when a successful HTTP response contained
  /// GraphQL errors, see [Dash0GraphQL.inspectResponse]. Call before
  /// [finish].
  void setGraphQLErrors(Dash0GraphQLErrors? errors) {
    try {
      if (errors != null) _call.setGraphQLErrors(errors);
    } catch (_) {
      // Telemetry must never throw into the app.
    }
  }

  /// Ends the span. Only the first call has an effect. Pass [error] if the
  /// request failed without a response.
  void finish({Object? error, StackTrace? stackTrace}) =>
      _call.finish(error: error, stackTrace: stackTrace);
}
