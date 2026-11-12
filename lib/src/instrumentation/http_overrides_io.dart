import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../client.dart';
import '../debug.dart';
import 'http_common.dart';

/// Instruments every `dart:io` [HttpClient], which covers `package:http`'s
/// `IOClient`, Dio's default adapter, `NetworkImage` and most plugins.
///
/// Install it once after `Dash0.init`, either with
/// `Dash0Instrumentation.httpOverrides` in
/// `Dash0Options.enabledInstrumentations` or `Dash0.installHttpOverrides()`.
/// Another [HttpOverrides] that was active before is kept and called.
///
/// Requests made through `Dash0HttpClient` are not instrumented twice.
class Dash0HttpOverrides extends HttpOverrides {
  /// Creates overrides that instrument clients of [client]. Clients are
  /// created by [previous], which defaults to [HttpOverrides.current].
  Dash0HttpOverrides(this._dash0, {HttpOverrides? previous})
      : _previous = previous ?? HttpOverrides.current;

  final Dash0Client _dash0;
  final HttpOverrides? _previous;
  bool _active = true;

  static Dash0HttpOverrides? _installed;

  /// Whether HTTP overrides can work on this platform.
  static bool get isSupported => true;

  /// Makes [client] instrument all `dart:io` HTTP clients created from now
  /// on. Returns false if already installed.
  static bool install(Dash0Client client) {
    if (_installed != null) return false;
    final overrides = Dash0HttpOverrides(client);
    _installed = overrides;
    HttpOverrides.global = overrides;
    return true;
  }

  /// Removes the overrides installed by [install] and restores the previous
  /// ones. Clients created earlier stop recording.
  static void uninstall() {
    final installed = _installed;
    if (installed == null) return;
    _installed = null;
    installed._active = false;
    if (identical(HttpOverrides.current, installed)) {
      HttpOverrides.global = installed._previous;
    }
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner =
        _previous?.createHttpClient(context) ?? super.createHttpClient(context);
    return _Dash0HttpClient(this, inner);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    return _previous?.findProxyFromEnvironment(url, environment) ??
        super.findProxyFromEnvironment(url, environment);
  }

  bool _shouldInstrument(Uri url) {
    if (!_active || isHttpHandledByDash0()) return false;
    return HttpCall.shouldInstrument(_dash0, url.toString());
  }
}

Uri _uriFor(String host, int port, String path) {
  String? fragment;
  String? query;
  var rest = path;
  final hash = rest.indexOf('#');
  if (hash >= 0) {
    fragment = rest.substring(hash + 1);
    rest = rest.substring(0, hash);
  }
  final question = rest.indexOf('?');
  if (question >= 0) {
    query = rest.substring(question + 1);
    rest = rest.substring(0, question);
  }
  return Uri(
    scheme: 'http',
    host: host,
    port: port,
    path: rest,
    query: query,
    fragment: fragment,
  );
}

class _Dash0HttpClient implements HttpClient {
  _Dash0HttpClient(this._overrides, this._inner);

  final Dash0HttpOverrides _overrides;
  final HttpClient _inner;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    HttpCall? call;
    try {
      if (_overrides._shouldInstrument(url)) {
        call = HttpCall.start(_overrides._dash0, method, url.toString());
      }
    } catch (e) {
      dash0Debug('Failed to start HTTP span', e);
    }
    final HttpClientRequest request;
    try {
      request = await _inner.openUrl(method, url);
    } catch (e, st) {
      call?.finish(error: e, stackTrace: st);
      rethrow;
    }
    if (call == null) return request;
    try {
      for (final e in call.propagationHeaders(url.toString()).entries) {
        request.headers.set(e.key, e.value);
      }
    } catch (e) {
      dash0Debug('Failed to add trace headers', e);
    }
    return _Dash0HttpClientRequest(request, call);
  }

  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      openUrl(method, _uriFor(host, port, path));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;

  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              callback) =>
      _inner.badCertificateCallback = callback;

  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// How long a request may stay open without `close()` being called before
/// its span is ended as abandoned.
Duration dash0AbandonedRequestTimeout = const Duration(minutes: 2);

class _Dash0HttpClientRequest implements HttpClientRequest {
  _Dash0HttpClientRequest(this._inner, this._call) {
    _abandonTimer = Timer(dash0AbandonedRequestTimeout, () {
      _call.finish(error: TimeoutException('HTTP request was never closed'));
    });
  }

  final HttpClientRequest _inner;
  final HttpCall _call;
  Timer? _abandonTimer;

  @override
  Future<HttpClientResponse> close() async {
    _abandonTimer?.cancel();
    try {
      final response = await _inner.close();
      try {
        _call.captureHeaders(_flatten(_inner.headers), request: true);
        _call.setResponse(
          response.statusCode,
          contentLength: response.contentLength,
          reason: response.reasonPhrase,
        );
        _call.captureHeaders(_flatten(response.headers), request: false);
      } catch (e) {
        dash0Debug('Failed to record HTTP response', e);
      }
      return _Dash0HttpClientResponse(response, _call);
    } catch (e, st) {
      _call.finish(error: e, stackTrace: st);
      rethrow;
    }
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _abandonTimer?.cancel();
    _call.finish(
      error: exception ?? StateError('Request aborted'),
      stackTrace: stackTrace,
    );
    _inner.abort(exception, stackTrace);
  }

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  Future<HttpClientResponse> get done => _inner.done;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  String get method => _inner.method;

  @override
  Uri get uri => _inner.uri;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) =>
      _inner.addStream(stream);

  @override
  Future<dynamic> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
}

Map<String, String> _flatten(HttpHeaders headers) {
  final result = <String, String>{};
  headers.forEach((name, values) => result[name] = values.join(', '));
  return result;
}

class _Dash0HttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _Dash0HttpClientResponse(this._inner, this._call);

  final HttpClientResponse _inner;
  final HttpCall _call;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = _inner
        .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleError: (error, stackTrace, sink) {
            _call.finish(error: error, stackTrace: stackTrace);
            sink.addError(error, stackTrace);
          },
          handleDone: (sink) {
            _call.finish();
            sink.close();
          },
        ))
        .listen(
          onData,
          onError: onError,
          onDone: onDone,
          cancelOnError: cancelOnError,
        );
    return _EndSpanOnCancel(subscription, _call);
  }

  @override
  X509Certificate? get certificate => _inner.certificate;

  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  int get contentLength => _inner.contentLength;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  Future<Socket> detachSocket() => _inner.detachSocket();

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  bool get isRedirect => _inner.isRedirect;

  @override
  bool get persistentConnection => _inner.persistentConnection;

  @override
  String get reasonPhrase => _inner.reasonPhrase;

  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followLoops]) =>
      _inner.redirect(method, url, followLoops);

  @override
  List<RedirectInfo> get redirects => _inner.redirects;

  @override
  int get statusCode => _inner.statusCode;
}

/// Ends the span when the consumer cancels the response early (image
/// decoders, `Stream.first`, timeouts), where no done event is delivered.
class _EndSpanOnCancel implements StreamSubscription<List<int>> {
  _EndSpanOnCancel(this._inner, this._call);

  final StreamSubscription<List<int>> _inner;
  final HttpCall _call;

  @override
  Future<void> cancel() {
    _call.finish();
    return _inner.cancel();
  }

  @override
  void onData(void Function(List<int> data)? handleData) =>
      _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
}
