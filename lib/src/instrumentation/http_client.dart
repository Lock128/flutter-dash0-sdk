import 'package:http/http.dart' as http;

import '../client.dart';
import '../debug.dart';
import 'http_common.dart';

/// A `package:http` client that creates a client span for every request,
/// mirroring the fetch instrumentation of dash0-sdk-web.
///
/// Span attributes follow the OpenTelemetry HTTP semantic conventions. Trace
/// context headers are added for URLs matched by
/// `Dash0Options.propagators`. Every request also records the
/// `http.client.request.duration` metric.
///
/// Requests made through this client are not instrumented a second time by
/// `Dash0HttpOverrides`.
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
    if (!HttpCall.shouldInstrument(_dash0, url)) {
      dash0Debug('Not creating span for request, URL ignored or disabled', url);
      return runMarkedAsHandled(() => _inner.send(request));
    }

    final call = HttpCall.start(_dash0, request.method, url);
    try {
      request.headers.addAll(call.propagationHeaders(url));
      call.captureHeaders(request.headers, request: true);
    } catch (e) {
      dash0Debug('Failed to prepare request instrumentation', e);
    }

    try {
      final response = await runMarkedAsHandled(() => _inner.send(request));
      call.setResponse(
        response.statusCode,
        contentLength: response.contentLength,
        reason: response.reasonPhrase,
      );
      call.captureHeaders(response.headers, request: false);
      call.finish();
      return response;
    } catch (e, st) {
      call.finish(error: e, stackTrace: st);
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}
