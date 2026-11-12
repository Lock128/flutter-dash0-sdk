import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'client.dart';
import 'instrumentation/http_client.dart';
import 'instrumentation/navigation.dart';
import 'options.dart';
import 'otlp.dart';
import 'semantic_conventions.dart' show Dash0Severity;
import 'session.dart';
import 'span.dart';
import 'transport.dart';

/// Static entry point of the SDK, equivalent to the functions exported by
/// `@dash0/sdk-web`.
///
/// All methods are safe to call before [init] or after [shutdown]; they do
/// nothing then.
class Dash0 {
  Dash0._();

  static Dash0Client? _client;
  static final Dash0NavigatorObserver _observer = Dash0NavigatorObserver();

  /// The active client, or null before [init].
  static Dash0Client? get client => _client;

  /// Whether [init] completed.
  static bool get isInitialized => _client != null;

  /// Initializes the SDK. Subsequent calls are ignored while a client is
  /// active. Throws an [ArgumentError] for invalid options.
  ///
  /// Call after `WidgetsFlutterBinding.ensureInitialized()`.
  static Future<Dash0Client> init(
    Dash0Options options, {
    Dash0Transport? transport,
    Dash0KeyValueStore? sessionStore,
  }) async {
    final existing = _client;
    if (existing != null) return existing;
    WidgetsFlutterBinding.ensureInitialized();
    final client = await Dash0Client.start(
      options,
      transport: transport,
      sessionStore: sessionStore,
    );
    _client = client;
    return client;
  }

  /// Observer to register with `MaterialApp.navigatorObservers` or
  /// `GoRouter(observers: ...)`. It can be created before [init]; it does
  /// nothing until the SDK is initialized.
  static NavigatorObserver get navigatorObserver => _observer;

  /// Returns a `package:http` client that creates spans. Without an
  /// initialized SDK the plain [inner] client (or a new one) is returned.
  static http.Client httpClient([http.Client? inner]) {
    final c = _client;
    if (c == null) return inner ?? http.Client();
    return Dash0HttpClient(c, inner);
  }

  /// Runs [body] in a guarded zone that reports uncaught errors.
  static R? runGuarded<R>(R Function() body) {
    return runZonedGuarded(body, (error, stack) {
      reportError(error, stackTrace: stack);
    });
  }

  /// Sends a page view for [screenName]. Use for navigation that is not
  /// observed by the navigator observer.
  static void trackScreen(String screenName, {Attributes? attributes}) {
    final c = _client;
    if (c == null) return;
    trackScreenView(c, screenName, attributes: attributes);
  }

  /// Sends a custom event. See [Dash0Client.sendEvent].
  static void sendEvent(
    String name, {
    String? title,
    DateTime? timestamp,
    Object? data,
    Attributes? attributes,
    Dash0Severity? severity,
  }) {
    _client?.sendEvent(
      name,
      title: title,
      timestamp: timestamp,
      data: data,
      attributes: attributes,
      severity: severity,
    );
  }

  /// Reports a handled error.
  static void reportError(
    Object error, {
    StackTrace? stackTrace,
    Attributes? attributes,
  }) {
    _client?.reportError(error, stackTrace: stackTrace, attributes: attributes);
  }

  /// Starts a span. Returns null before [init].
  static Dash0Span? startSpan(
    String name, {
    Dash0Span? parent,
    Attributes? attributes,
  }) {
    return _client?.startSpan(name, parent: parent, attributes: attributes);
  }

  /// Runs [body] in a span. Without a client [body] is run unchanged.
  static Future<T> trace<T>(
    String name,
    FutureOr<T> Function(Dash0Span? span) body, {
    Attributes? attributes,
  }) {
    final c = _client;
    if (c == null) return Future.sync(() => body(null));
    return c.trace<T>(name, body, attributes: attributes);
  }

  static void addSignalAttribute(String name, Object? value) =>
      _client?.addSignalAttribute(name, value);

  static void removeSignalAttribute(String name) =>
      _client?.removeSignalAttribute(name);

  /// Associates user information with all following signals.
  static void identify(
    String? id, {
    String? name,
    String? fullName,
    String? email,
    String? hash,
    List<String>? roles,
  }) {
    _client?.identify(
      id,
      name: name,
      fullName: fullName,
      email: email,
      hash: hash,
      roles: roles,
    );
  }

  /// The current session id, or null before [init].
  static String? get sessionId => _client?.sessionId;

  /// Ends the current session and starts a new one.
  static Future<void> terminateSession() async => _client?.terminateSession();

  /// Enables or disables recording at runtime.
  static set enabled(bool value) => _client?.enabled = value;

  /// Sends everything that is queued.
  static Future<void> flush() async => _client?.flush();

  /// Flushes and stops the SDK, restoring error handlers. [init] can be
  /// called again afterwards.
  static Future<void> shutdown() async {
    final c = _client;
    _client = null;
    await c?.shutdown();
  }
}
