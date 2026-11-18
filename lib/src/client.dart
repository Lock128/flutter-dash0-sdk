import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'batcher.dart';
import 'client_info.dart';
import 'client_probe.dart' show probeViewport;
import 'debug.dart';
import 'ids.dart';
import 'ignore_rules.dart';
import 'instrumentation/errors.dart';
import 'instrumentation/http_overrides.dart';
import 'instrumentation/navigation.dart';
import 'instrumentation/profiling.dart';
import 'instrumentation/rage_clicks.dart';
import 'instrumentation/vitals.dart';
import 'metrics/instruments.dart';
import 'metrics/registry.dart';
import 'options.dart';
import 'otlp.dart';
import 'rate_limiter.dart';
import 'replay/recorder.dart';
import 'semantic_conventions.dart' as sc;
import 'semantic_conventions.dart' show Dash0Names, Dash0Severity;
import 'session.dart';
import 'span.dart';
import 'transport.dart';
import 'url_attributes.dart';
import 'vcs.dart';

/// Version reported as `telemetry.sdk.version`.
const dash0SdkVersion = '0.8.0';

/// Legacy scope name, reported with `Dash0Options.legacyAppNames`.
const dash0ScopeName = 'dash0-flutter-sdk';

/// The Dash0 SDK instance. Most apps use the static `Dash0` facade instead of
/// creating a client directly.
class Dash0Client with WidgetsBindingObserver {
  Dash0Client._(
    this.options,
    this._transport,
    this._session,
    this.ignoreRules,
    String sessionId, {
    int Function()? nowMillis,
    Dash0ClientInfo? clientInfo,
    ViewportProbe? Function()? viewportProbe,
    Map<String, String> buildEnvironment = const {},
  })  : _buildEnvironment = buildEnvironment,
        _sessionId = sessionId,
        _clock = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
        _sampled = isSessionSampledIn(sessionId, options.sessionSamplingRate),
        clientInfo = clientInfo ??
            detectClientInfo(collectUserAgent: options.collectUserAgent),
        appInstanceId = generateUniqueId(appInstanceIdBytes),
        pageLoadId = generateUniqueId(pageLoadIdBytes),
        tabId = generateUniqueId(tabIdBytes),
        _viewportProbe = viewportProbe ?? probeViewport {
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
    bool installUiInstrumentation = true,
    int Function()? nowMillis,
    Dash0ClientInfo? clientInfo,
    ViewportProbe? Function()? viewportProbe,
    Map<String, String> buildEnvironment = dash0BuildEnvironment,
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
      storageNamespace: options.storageNamespace,
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
      nowMillis: nowMillis,
      clientInfo: clientInfo,
      viewportProbe: viewportProbe,
      buildEnvironment: buildEnvironment,
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
    if (installUiInstrumentation) {
      if (options.isEnabled(Dash0Instrumentation.vitals)) {
        client.vitals = VitalsInstrumentation(client)..install();
      }
      if (options.isEnabled(Dash0Instrumentation.rageClicks)) {
        client._rageClicks = RageClickInstrumentation(client)..install();
      }
      if (options.isEnabled(Dash0Instrumentation.sessionReplay) &&
          options.replay.enabled) {
        client.replay = ReplayRecorder(client)..install();
      }
      if (options.isExplicitlyEnabled(Dash0Instrumentation.profiling)) {
        client._longTasks = LongTaskMonitor(client)..install();
        if (options.profiling.runtimeSampleInterval != null) {
          client._runtime = RuntimeSampler(client)..install();
        }
      }
    }
    dash0Debug('Initialized', 'session=$sessionId sampled=${client._sampled}');
    client._debugUserAgent();
    return client;
  }

  final Dash0Options options;

  /// Names shared with dash0-sdk-web, or the legacy `app.*` names.
  Dash0Names get names =>
      options.legacyAppNames ? Dash0Names.legacy : Dash0Names.web;
  final IgnoreRules ignoreRules;
  final Map<String, String> _buildEnvironment;

  /// Client type (web desktop, web mobile, ios, android, ...) of this run.
  final Dash0ClientInfo clientInfo;

  /// Random id of this app launch, the equivalent of the browser tab id.
  final String appInstanceId;

  /// Random id of this page load (web only), `page.load.id`.
  final String pageLoadId;

  /// Random id of this browser tab (web only), `browser.tab.id`. A Flutter
  /// web app runs once per tab, so it is generated once per client.
  final String tabId;

  final ViewportProbe? Function() _viewportProbe;

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
  RageClickInstrumentation? _rageClicks;
  LongTaskMonitor? _longTasks;
  RuntimeSampler? _runtime;
  Timer? _metricTimer;
  Dash0Histogram? _httpDuration;
  Dash0Histogram? _graphQLDuration;
  final Set<String> _graphQLNames = {};
  bool _httpOverridesInstalled = false;
  bool _observingLifecycle = false;
  late bool _enabled = options.enabled;
  bool _sampled;
  bool _shutdown = false;
  String _sessionId;

  /// Name of the screen currently shown, set by the navigation
  /// instrumentation and added to all signals.
  String? currentScreen;

  final int Function() _clock;

  /// Wall clock time in milliseconds at which [currentScreen] was shown.
  /// Used for `app.screen.previous.duration_ms`.
  int? screenShownAtMillis;

  /// Milliseconds the app spent in the background since [screenShownAtMillis].
  int screenBackgroundMillis = 0;
  int? _backgroundSinceMillis;

  /// Marks [currentScreen] as shown now and resets the background time.
  void markScreenShown(int now) {
    screenShownAtMillis = now;
    screenBackgroundMillis = 0;
    if (_backgroundSinceMillis != null) _backgroundSinceMillis = now;
  }

  /// Time the current screen was visible in the foreground since it was
  /// shown, or null if unknown.
  int? screenVisibleMillis(int now) {
    final shownAt = screenShownAtMillis;
    if (shownAt == null || now < shownAt) return null;
    final since = _backgroundSinceMillis;
    final background = screenBackgroundMillis +
        (since == null ? 0 : (now - since).clamp(0, now));
    final visible = now - shownAt - background;
    return visible < 0 ? 0 : visible;
  }

  /// Current time of the client's clock in milliseconds since the epoch.
  int nowMillisSinceEpoch() => _clock();

  /// The latest page view requested while the client was disabled. It is sent
  /// when the client is enabled. See [trackScreenView].
  PendingScreenView? pendingScreenView;

  /// The vitals instrumentation, null when disabled. Public for
  /// instrumentations.
  VitalsInstrumentation? vitals;

  /// The session replay recorder, null when disabled. Public for
  /// instrumentations.
  ReplayRecorder? replay;

  String get sessionId => _sessionId;

  /// Whether the current session is sampled in.
  bool get isSessionSampled => _sampled;

  /// Whether signals are currently recorded.
  bool get isEnabled => _enabled && !_shutdown;

  /// Enables or disables recording at runtime, for example from a feature
  /// flag. Disabled clients drop signals instead of queueing them.
  set enabled(bool value) {
    final wasEnabled = _enabled;
    _enabled = value;
    if (!value) {
      unawaited(flush());
    } else if (!wasEnabled) {
      _sendPendingScreenView();
    }
  }

  void _sendPendingScreenView() {
    final pending = pendingScreenView;
    if (pending == null || _shutdown) return;
    pendingScreenView = null;
    try {
      trackScreenView(
        this,
        pending.screenName,
        changeState: pending.changeState,
        attributes: pending.attributes,
      );
    } catch (_) {
      // Telemetry must never throw into the app.
    }
  }

  /// The resource sent with metrics.
  Map<String, Object?> get resource => {
        'attributes': encodeAttributes(buildResourceAttributes()),
      };

  /// The resource sent with logs and spans. Like [resource], plus
  /// `user_agent.original` with `Dash0Options.userAgentOnResource`.
  Map<String, Object?> get signalResource {
    final ua = clientInfo.userAgent;
    if (!options.userAgentOnResource ||
        !options.collectUserAgent ||
        !clientInfo.isWeb ||
        ua == null) {
      return resource;
    }
    return {
      'attributes': encodeAttributes({
        ...buildResourceAttributes(),
        sc.userAgentOriginal: ua,
      }),
    };
  }

  /// The user agent for native apps, or null.
  String? get _syntheticUserAgent {
    if (!options.syntheticUserAgent || clientInfo.isWeb) return null;
    final attrs = options.resourceAttributes;
    String? str(String key) {
      final v = attrs[key];
      return v == null ? null : '$v';
    }

    return buildSyntheticUserAgent(
      service: options.effectiveServiceName,
      serviceVersion: options.serviceVersion,
      osName: clientInfo.osName,
      osVersion: str('os.version'),
      device: str('device.model.identifier') ?? str('device.model.name'),
    );
  }

  void _debugUserAgent() {
    try {
      if (!options.debug) return;
      final attached = options.collectUserAgent &&
          (clientInfo.userAgent != null || _syntheticUserAgent != null);
      dash0Debug(
        'Client',
        'type=${clientInfo.type.value} '
            'user_agent.original=${attached ? 'attached' : 'not attached'}'
            '${attached ? ' length=${(clientInfo.userAgent ?? _syntheticUserAgent)!.length}' : ''}',
      );
    } catch (_) {
      // Telemetry must never throw into the app.
    }
  }

  /// Resource attributes. Overridable keys from options are applied last.
  Attributes buildResourceAttributes() {
    final o = options;
    final locale = _safeLocale();
    return {
      sc.serviceName: o.effectiveServiceName,
      sc.serviceNamespace: o.serviceNamespace,
      sc.serviceVersion: o.serviceVersion,
      sc.deploymentEnvironmentName:
          o.environment ?? buildEnv(_buildEnvironment, 'DASH0_ENVIRONMENT'),
      sc.deploymentName: o.deploymentName ??
          buildEnv(_buildEnvironment, 'DASH0_DEPLOYMENT_NAME'),
      sc.deploymentId:
          o.deploymentId ?? buildEnv(_buildEnvironment, 'DASH0_DEPLOYMENT_ID'),
      ...resolveVcsAttributes(o, _buildEnvironment),
      sc.telemetrySdkName: names.sdkName,
      sc.telemetrySdkLanguage: 'dart',
      sc.telemetrySdkVersion: dash0SdkVersion,
      sc.osType: kIsWeb ? 'web' : defaultTargetPlatform.name,
      ...clientInfo.resourceAttributes(),
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
        ...clientInfo.signalAttributes(
          includeUserAgent: options.collectUserAgent,
          syntheticUserAgent: _syntheticUserAgent,
        ),
        if (clientInfo.isWeb) ..._webAttributes(),
        if (currentScreen != null) sc.appScreenName: currentScreen,
        ...pageUrlAttributes(),
      };

  /// Attributes dash0-sdk-web adds to every signal. Web only.
  Attributes _webAttributes() {
    ViewportProbe? viewport;
    try {
      viewport = _viewportProbe();
    } catch (_) {
      viewport = null;
    }
    return {
      sc.pageLoadId: pageLoadId,
      sc.browserTabId: tabId,
      if (viewport?.width != null) sc.browserWindowWidth: viewport!.width,
      if (viewport?.height != null) sc.browserWindowHeight: viewport!.height,
      if (viewport?.connectionType != null &&
          viewport!.connectionType!.isNotEmpty)
        sc.networkConnectionSubtype: viewport.connectionType,
    };
  }

  /// `page.url.*` attributes for the current screen, as `app://<screen>`.
  Attributes pageUrlAttributes() {
    final screen = currentScreen;
    if (screen == null) return const {};
    try {
      final name = screen.replaceFirst(RegExp(r'^/+'), '');
      final full = scrubUrl('$_pageScheme://$name', options.urlScrubber);
      final rest = full.startsWith('$_pageScheme://')
          ? full.substring(_pageScheme.length + 3)
          : name;
      return {
        sc.pageUrlFull: full,
        sc.pageUrlScheme: _pageScheme,
        sc.pageUrlDomain: options.effectiveServiceName,
        sc.pageUrlPath: '/${rest.replaceFirst(RegExp(r'^/+'), '')}',
      };
    } catch (e) {
      dash0Debug('Building page.url attributes failed', e);
      return const {};
    }
  }

  /// Scheme of the `page.url.*` attributes.
  static const _pageScheme = 'app';

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
    bool rateLimited = true,
  }) {
    final attrs = <String, Object?>{
      ...commonAttributes(),
      sc.eventName: name,
      if (title != null) names.eventTitle: title,
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
    }, rateLimited: rateLimited);
  }

  /// Reports an error as a `browser.error` event (`app.error` with legacy names).
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
        names.eventId: spanId,
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

  /// Most distinct GraphQL operation names used as metric attribute. Further
  /// names are recorded as `_OTHER`.
  static const maxGraphQLOperationNames = 100;

  /// Records `graphql.client.operation.duration` unless the metrics
  /// instrumentation is off. Public for instrumentations.
  void recordGraphQLDuration(double seconds, Attributes attributes) {
    if (!options.isEnabled(Dash0Instrumentation.metrics)) return;
    final attrs = {...attributes};
    final name = attrs[sc.graphQLOperationName];
    if (name is String &&
        !_graphQLNames.contains(name) &&
        !(_graphQLNames.length < maxGraphQLOperationNames &&
            _graphQLNames.add(name))) {
      attrs[sc.graphQLOperationName] = '_OTHER';
    }
    (_graphQLDuration ??= _metrics.histogram(
      sc.metricGraphQLClientOperationDuration,
      unit: 's',
      description: 'Duration of GraphQL client operations.',
    ))
        .record(seconds, attributes: attrs);
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
  // Profiling and replay

  /// Runs [body] in a span named [name] with frame jank counts, RSS and
  /// timing attributes. See `Dash0.profile`.
  Future<T> profile<T>(
    String name,
    FutureOr<T> Function(Dash0Span span) body, {
    Attributes? attributes,
  }) =>
      runProfiled<T>(this, name, body, attributes: attributes);

  /// Records the session replay regardless of
  /// `Dash0Options.sessionReplaySamplingRate`.
  void startReplay() => replay?.start();

  /// Stops recording the session replay and sends what was recorded.
  void stopReplay() => replay?.stop();

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
  ///
  /// [rateLimited] false skips the shared rate limiter. Only the replay uses
  /// it, with its own cap.
  void sendLog(Map<String, Object?> log, {bool rateLimited = true}) {
    if (!_accepts()) return;
    if (rateLimited && _rateLimiter.isExcessiveUsage()) {
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
          'resource': signalResource,
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
          'resource': signalResource,
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

  Map<String, Object?> get _scope => {
        'name': names.sdkName,
        'version': dash0SdkVersion,
      };

  /// Sends everything that is queued now. The returned future completes when
  /// the requests finished.
  Future<void> flush() async {
    replay?.flush();
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
    replay?.flush();
    exportMetrics();
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
    final nowMs = _clock();
    if (background) {
      _backgroundSinceMillis ??= nowMs;
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundSinceMillis;
      if (since != null && nowMs >= since) {
        screenBackgroundMillis += nowMs - since;
      }
      _backgroundSinceMillis = null;
    }
    if (background) vitals?.flushScreen('background');
    if (background) _longTasks?.pause();
    if (state == AppLifecycleState.resumed) _longTasks?.resume();
    _logBatcher.immediate = background;
    _spanBatcher.immediate = background;
    replay?.onLifecycle(state, background: background);
    // The periodic timer does not run once suspended and delta data of the
    // unsent interval would be lost.
    if (background) exportMetrics();
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
    replay?.uninstall();
    _longTasks?.uninstall();
    _runtime?.uninstall();
    vitals?.uninstall();
    _rageClicks?.uninstall();
    _errors.uninstall();
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _transport.close();
  }
}
