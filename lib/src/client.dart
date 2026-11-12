import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'batcher.dart';
import 'debug.dart';
import 'ids.dart';
import 'ignore_rules.dart';
import 'instrumentation/errors.dart';
import 'instrumentation/http_overrides.dart';
import 'metrics/instruments.dart';
import 'metrics/registry.dart';
import 'options.dart';
import 'otlp.dart';
import 'rate_limiter.dart';
import 'semantic_conventions.dart' as sc;
import 'semantic_conventions.dart' show Dash0Severity;
import 'session.dart';
import 'span.dart';
import 'transport.dart';

/// Version reported as `telemetry.sdk.version`.
const dash0SdkVersion = '0.1.0';

/// Scope name reported for all telemetry.
const dash0ScopeName = 'dash0-flutter-sdk';

/// The Dash0 SDK instance. Most apps use the static `Dash0` facade instead of
/// creating a client directly.
class Dash0Client with WidgetsBindingObserver {
  Dash0Client._(
    this.options,
    this._transport,
    this._session,
    this.ignoreRules,
    String sessionId,
  )   : _sessionId = sessionId,
        _sampled = isSessionSampledIn(sessionId, options.sessionSamplingRate),
        appInstanceId = generateUniqueId(appInstanceIdBytes) {
    _logBatcher = Batcher<Map<String, Object?>>(
      _sendLogs,
      maxQueueSize: options.batchSize,
      scheduleDelay: options.batchDelay,
    );
    _spanBatcher = Batcher<Map<String, Object?>>(
      _sendSpans,
      maxQueueSize: options.batchSize,
      scheduleDelay: options.batchDelay,
    );
    _signalAttributes.addAll(options.additionalSignalAttributes);
  }

  /// Creates and starts a client.
  ///
  /// [transport] and [sessionStore] can be replaced, which is mostly useful
  /// for tests. [observeLifecycle] registers a [WidgetsBindingObserver];
  /// [installErrorHandlers] hooks `FlutterError.onError` and
  /// `PlatformDispatcher.onError`.
  static Future<Dash0Client> start(
    Dash0Options options, {
    Dash0Transport? transport,
    Dash0KeyValueStore? sessionStore,
    bool observeLifecycle = true,
    bool installErrorHandlers = true,
    bool installHttpOverrides = true,
    int Function()? nowMillis,
  }) async {
    options.validate();
    setDash0Debug(options.debug);

    var ephemeral = false;
    var store = sessionStore;
    if (store == null) {
      try {
        store = SharedPreferencesStore();
      } catch (_) {
        store = MemoryStore();
        ephemeral = true;
      }
    }
    final sessions = SessionManager(
      store: store,
      inactivityTimeout: options.sessionInactivityTimeout,
      terminationTimeout: options.sessionTerminationTimeout,
      nowMillis: nowMillis,
      ephemeral: ephemeral,
    );
    String sessionId;
    try {
      sessionId = await sessions.start();
    } catch (_) {
      sessionId = generateSessionId(ephemeral: true);
    }

    final client = Dash0Client._(
      options,
      transport ??
          HttpDash0Transport(
            options.allEndpoints,
            compression: options.compression,
          ),
      sessions,
      IgnoreRules(
        ignoreUrls: options.ignoreUrls,
        ignoreErrorMessages: options.ignoreErrorMessages,
        endpoints: options.allEndpoints,
      ),
      sessionId,
    );
    if (observeLifecycle && options.isEnabled(Dash0Instrumentation.lifecycle)) {
      WidgetsBinding.instance.addObserver(client);
      client._observingLifecycle = true;
    }
    if (installErrorHandlers && options.isEnabled(Dash0Instrumentation.error)) {
      client._errors.install();
    }
    if (installHttpOverrides &&
        options.isExplicitlyEnabled(Dash0Instrumentation.httpOverrides)) {
      client.installHttpOverrides();
    }
    dash0Debug('Initialized', 'session=$sessionId sampled=${client._sampled}');
    return client;
  }

  final Dash0Options options;
  final IgnoreRules ignoreRules;

  /// Random id of this app launch, the equivalent of the browser tab id.
  final String appInstanceId;

  final Dash0Transport _transport;
  final SessionManager _session;
  final RateLimiter _rateLimiter = RateLimiter(
    maxCallsPerTenMinutes: 4096,
    maxCallsPerTenSeconds: 128,
  );
  final Attributes _signalAttributes = {};
  late final Batcher<Map<String, Object?>> _logBatcher;
  late final Batcher<Map<String, Object?>> _spanBatcher;
  late final ErrorInstrumentation _errors = ErrorInstrumentation(this);
  late final MetricsRegistry _metrics = MetricsRegistry(
    accepts: _accepts,
    temporality: options.metricTemporality,
    onInstrumentCreated: _ensureMetricTimer,
  );
  Timer? _metricTimer;
  Dash0Histogram? _httpDuration;
  bool _httpOverridesInstalled = false;
  bool _observingLifecycle = false;
  late bool _enabled = options.enabled;
  bool _sampled;
  bool _shutdown = false;
  String _sessionId;

  /// Name of the screen currently shown, set by the navigation
  /// instrumentation and added to all signals.
  String? currentScreen;

  String get sessionId => _sessionId;

  /// Whether the current session is sampled in.
  bool get isSessionSampled => _sampled;

  /// Whether signals are currently recorded.
  bool get isEnabled => _enabled && !_shutdown;

  /// Enables or disables recording at runtime, for example from a feature
  /// flag. Disabled clients drop signals instead of queueing them.
  set enabled(bool value) {
    _enabled = value;
    if (!value) unawaited(flush());
  }

  /// The resource sent with all telemetry.
  Map<String, Object?> get resource => {
        'attributes': encodeAttributes(buildResourceAttributes()),
      };

  /// Resource attributes. Overridable keys from options are applied last.
  Attributes buildResourceAttributes() {
    final o = options;
    final locale = _safeLocale();
    return {
      sc.serviceName: o.effectiveServiceName,
      sc.serviceNamespace: o.serviceNamespace,
      sc.serviceVersion: o.serviceVersion,
      sc.deploymentEnvironmentName: o.environment,
      sc.deploymentName: o.deploymentName,
      sc.deploymentId: o.deploymentId,
      sc.telemetrySdkName: dash0ScopeName,
      sc.telemetrySdkLanguage: 'dart',
      sc.telemetrySdkVersion: dash0SdkVersion,
      sc.osType: kIsWeb ? 'web' : defaultTargetPlatform.name,
      sc.appLocale: locale,
      ...o.resourceAttributes,
    };
  }

  static String? _safeLocale() {
    try {
      return PlatformDispatcher.instance.locale.toLanguageTag();
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Signal attributes and identity

  void addSignalAttribute(String name, Object? value) {
    if (value == null) {
      _signalAttributes.remove(name);
    } else {
      _signalAttributes[name] = value;
    }
  }

  void removeSignalAttribute(String name) => _signalAttributes.remove(name);

  /// Associates user information with all following signals. Calling it
  /// replaces previous user information. Call `identify(null)` to clear.
  void identify(
    String? id, {
    String? name,
    String? fullName,
    String? email,
    String? hash,
    List<String>? roles,
  }) {
    addSignalAttribute(sc.userId, id);
    addSignalAttribute(sc.userName, name);
    addSignalAttribute(sc.userFullName, fullName);
    addSignalAttribute(sc.userEmail, email);
    addSignalAttribute(sc.userHash, hash);
    addSignalAttribute(sc.userRoles, roles);
  }

  /// Attributes added to every signal at the time it is recorded.
  Attributes commonAttributes() => {
        sc.sessionId: _sessionId,
        sc.appInstanceId: appInstanceId,
        if (currentScreen != null) sc.appScreenName: currentScreen,
      };

  // ---------------------------------------------------------------------
  // Events and logs

  /// Sends a custom event as a log record. Names reserved by the SDK are
  /// rejected.
  void sendEvent(
    String name, {
    String? title,
    DateTime? timestamp,
    Object? data,
    Attributes? attributes,
    Dash0Severity? severity,
  }) {
    if (sc.EventNames.all.contains(name)) {
      dash0Warn('Unable to send custom event $name: reserved event name.');
      return;
    }
    emitEvent(
      name,
      title: title,
      timestamp: timestamp,
      data: data,
      attributes: attributes,
      severity: severity,
    );
  }

  /// Like [sendEvent] but allows reserved names. Used by instrumentations.
  void emitEvent(
    String name, {
    String? title,
    DateTime? timestamp,
    Object? data,
    Attributes? attributes,
    Dash0Severity? severity,
    String? traceId,
    String? spanId,
  }) {
    final attrs = <String, Object?>{
      ...commonAttributes(),
      sc.eventName: name,
      if (title != null) sc.eventTitle: title,
      ...attributes ?? const {},
    };
    sendLog(<String, Object?>{
      'timeUnixNano':
          (timestamp != null ? toNanos(timestamp) : nowNanos()).toString(),
      'attributes': encodeAttributes({..._signalAttributes, ...attrs}),
      if (data != null) 'body': toAnyValue(data),
      if (severity != null) 'severityText': severity.text,
      if (severity != null) 'severityNumber': severity.number,
      if (traceId != null) 'traceId': traceId,
      if (spanId != null) 'spanId': spanId,
    });
  }

  /// Reports an error as an `app.error` event.
  void reportError(
    Object error, {
    StackTrace? stackTrace,
    Attributes? attributes,
    String? componentStack,
  }) {
    _errors.report(
      error,
      stackTrace: stackTrace,
      attributes: attributes,
      componentStack: componentStack,
    );
  }

  // ---------------------------------------------------------------------
  // Spans

  /// Starts a span. Without [parent] the span becomes a child of the current
  /// span (see [trace]) or starts a new trace.
  Dash0Span startSpan(
    String name, {
    Dash0Span? parent,
    Attributes? attributes,
    int kind = sc.spanKindInternal,
    DateTime? startTime,
  }) {
    final p = parent ?? Dash0Span.current;
    final traceId = p?.traceId ?? generateTraceId(_sessionId);
    final spanId = generateSpanId(traceId);
    return Dash0Span.internal(
      name: name,
      traceId: traceId,
      spanId: spanId,
      parentSpanId: p?.spanId,
      kind: kind,
      attributes: {
        ...commonAttributes(),
        sc.eventId: spanId,
        ...attributes ?? const {},
      },
      startTimeUnixNano: startTime != null ? toNanos(startTime) : null,
      onEnd: (span) => sendSpan(span.toJson()),
    );
  }

  /// Runs [body] inside a new span. The span is current for the duration, so
  /// HTTP requests made by [body] become children. Errors are recorded and
  /// rethrown.
  Future<T> trace<T>(
    String name,
    FutureOr<T> Function(Dash0Span span) body, {
    Attributes? attributes,
  }) async {
    final span = startSpan(name, attributes: attributes);
    try {
      return await span.runAsCurrent(() => body(span));
    } catch (e, st) {
      span.recordException(e, st);
      rethrow;
    } finally {
      span.end();
    }
  }

  // ---------------------------------------------------------------------
  // Metrics

  /// A monotonic sum, for example the number of requests. Calling this again
  /// with the same name returns the same instrument.
  Dash0Counter counter(String name, {String? unit, String? description}) =>
      _metrics.counter(name, unit: unit, description: description);

  /// A sum that can also decrease, for example open connections.
  Dash0UpDownCounter upDownCounter(String name,
          {String? unit, String? description}) =>
      _metrics.upDownCounter(name, unit: unit, description: description);

  /// A distribution of values with explicit bucket [boundaries].
  Dash0Histogram histogram(
    String name, {
    String? unit,
    String? description,
    List<double>? boundaries,
  }) =>
      _metrics.histogram(name,
          unit: unit, description: description, boundaries: boundaries);

  /// The latest value of something, for example free memory.
  Dash0Gauge gauge(String name, {String? unit, String? description}) =>
      _metrics.gauge(name, unit: unit, description: description);

  /// Records `http.client.request.duration` unless the metrics
  /// instrumentation is off. Public for instrumentations.
  void recordHttpClientDuration(double seconds, Attributes attributes) {
    if (!options.isEnabled(Dash0Instrumentation.metrics)) return;
    (_httpDuration ??= _metrics.histogram(
      sc.metricHttpClientRequestDuration,
      unit: 's',
      description: 'Duration of HTTP client requests.',
    ))
        .record(seconds, attributes: attributes);
  }

  void _ensureMetricTimer() {
    if (_metricTimer != null || _shutdown) return;
    _metricTimer = Timer.periodic(options.metricExportInterval, (_) {
      exportMetrics();
    });
  }

  /// Sends the aggregated metrics now. With delta temporality the
  /// aggregation starts over.
  void exportMetrics() {
    final metrics = _metrics.collect();
    if (metrics.isEmpty) return;
    if (_rateLimiter.isExcessiveUsage()) {
      dash0Debug('Transport rate limit. Will not send metrics.');
      return;
    }
    _dispatch('/v1/metrics', {
      'resourceMetrics': [
        {
          'resource': resource,
          'scopeMetrics': [
            {
              'scope': _scope,
              'metrics': metrics,
            },
          ],
        },
      ],
    });
  }

  // ---------------------------------------------------------------------
  // HTTP capture

  /// Instruments all `dart:io` HTTP clients, see `Dash0HttpOverrides`. Does
  /// nothing on web.
  void installHttpOverrides() {
    if (_httpOverridesInstalled || !Dash0HttpOverrides.isSupported) return;
    _httpOverridesInstalled = Dash0HttpOverrides.install(this);
  }

  /// Removes the overrides installed by [installHttpOverrides].
  void uninstallHttpOverrides() {
    if (!_httpOverridesInstalled) return;
    _httpOverridesInstalled = false;
    Dash0HttpOverrides.uninstall();
  }

  // ---------------------------------------------------------------------
  // Transport

  /// Queues a log record. Public for instrumentations.
  void sendLog(Map<String, Object?> log) {
    if (!_accepts()) return;
    if (_rateLimiter.isExcessiveUsage()) {
      dash0Debug('Transport rate limit. Will not send item.', log);
      return;
    }
    _logBatcher.send(log);
  }

  /// Queues an ended span (OTLP JSON). Public for instrumentations.
  void sendSpan(Map<String, Object?> span) {
    if (!_accepts()) return;
    if (_rateLimiter.isExcessiveUsage()) {
      dash0Debug('Transport rate limit. Will not send item.', span);
      return;
    }
    _spanBatcher.send(span);
  }

  bool _accepts() => _enabled && !_shutdown && _sampled;

  final Set<Future<void>> _inFlight = {};

  void _dispatch(String path, Map<String, Object?> body) {
    late final Future<void> future;
    future = _transport.send(path, body).catchError((Object e) {
      dash0Debug('Failed to transmit telemetry', e);
    }).whenComplete(() => _inFlight.remove(future));
    _inFlight.add(future);
  }

  void _sendLogs(List<Map<String, Object?>> logs) {
    _dispatch('/v1/logs', {
      'resourceLogs': [
        {
          'resource': resource,
          'scopeLogs': [
            {
              'scope': _scope,
              'logRecords': logs,
            },
          ],
        },
      ],
    });
  }

  void _sendSpans(List<Map<String, Object?>> spans) {
    _dispatch('/v1/traces', {
      'resourceSpans': [
        {
          'resource': resource,
          'scopeSpans': [
            {
              'scope': _scope,
              'spans': spans,
            },
          ],
        },
      ],
    });
  }

  static const Map<String, Object?> _scope = {
    'name': dash0ScopeName,
    'version': dash0SdkVersion,
  };

  /// Sends everything that is queued now. The returned future completes when
  /// the requests finished.
  Future<void> flush() async {
    _logBatcher.flush();
    _spanBatcher.flush();
    exportMetrics();
    await Future.wait(_inFlight.toList());
  }

  // ---------------------------------------------------------------------
  // Session and lifecycle

  /// Ends the current session and starts a new one with a fresh sampling
  /// decision.
  Future<void> terminateSession() async {
    _sessionId = await _session.terminate();
    _sampled = isSessionSampledIn(_sessionId, options.sessionSamplingRate);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    handleLifecycleState(state);
  }

  /// Handles an app lifecycle change. Exposed for tests.
  Future<void> handleLifecycleState(AppLifecycleState state) async {
    final background = state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden;
    if (state == AppLifecycleState.resumed) {
      final rotated = await _session.touch();
      if (rotated) {
        _sessionId = _session.sessionId;
        _sampled = isSessionSampledIn(_sessionId, options.sessionSamplingRate);
      }
    }
    _logBatcher.immediate = background;
    _spanBatcher.immediate = background;
    if (!options.isEnabled(Dash0Instrumentation.lifecycle)) return;
    emitEvent(
      sc.EventNames.lifecycle,
      attributes: {sc.appLifecycleState: state.name},
    );
    if (background) unawaited(flush());
  }

  /// Flushes, removes all hooks and stops the client.
  Future<void> shutdown() async {
    if (_shutdown) return;
    await flush();
    _shutdown = true;
    _metricTimer?.cancel();
    _metricTimer = null;
    uninstallHttpOverrides();
    _errors.uninstall();
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _transport.close();
  }
}
