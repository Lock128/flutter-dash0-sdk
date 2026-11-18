import 'package:flutter/widgets.dart';

import 'sanitize.dart';

/// OTLP endpoint receiving the telemetry.
class Dash0Endpoint {
  const Dash0Endpoint({
    required this.url,
    required this.authToken,
    this.dataset,
  });

  /// OTLP HTTP base URL excluding the `/v1/*` suffix.
  final String url;

  /// Sent as `Authorization: Bearer {authToken}`. Has the form `auth_abc123`.
  ///
  /// Note that tokens embedded in an app are readable by users. Use a token
  /// restricted to ingesting.
  final String authToken;

  /// Optional dataset, sent as the `Dash0-Dataset` header.
  final String? dataset;
}

/// Instrumentations that can be switched on or off individually.
enum Dash0Instrumentation {
  /// Page views produced by [Dash0NavigatorObserver] and `Dash0.trackScreen`.
  navigation,

  /// Uncaught Flutter and platform errors.
  error,

  /// Spans produced by `Dash0HttpClient`.
  http,

  /// App lifecycle events and flushing when the app goes to the background.
  lifecycle,

  /// Automatic metrics such as `http.client.request.duration`. The manual
  /// metrics API (`Dash0.counter` and friends) works regardless.
  metrics,

  /// Installs `Dash0HttpOverrides` during `Dash0.init`, which instruments all
  /// `dart:io` HTTP clients. Unlike the other values this is opt-in: it is
  /// only active when listed in `Dash0Options.enabledInstrumentations`.
  httpOverrides,

  /// Flutter equivalents of web vitals: app start, time to first frame,
  /// frame timings, jank and interaction latency, plus `app.vitals` events.
  /// Metrics are only recorded while [metrics] is enabled too.
  vitals,

  /// Detects rapid repeated taps and sends `app.rage_click` events.
  rageClicks,

  /// Records the event-based session replay stream. Nothing is recorded
  /// unless `Dash0Options.sessionReplaySamplingRate` is above 0 or
  /// `Dash0.startReplay` was called.
  sessionReplay,

  /// Long task and ANR detection plus the optional runtime sampler. Opt-in:
  /// only active when listed in `Dash0Options.enabledInstrumentations`.
  /// `Dash0.profile` works regardless.
  profiling,
}

/// How metric values are reported over time.
enum Dash0AggregationTemporality {
  /// Each export contains only what happened since the previous export.
  delta,

  /// Each export contains totals since the app started.
  cumulative,
}

/// Compression applied to request bodies.
enum Dash0Compression {
  /// Send uncompressed JSON.
  none,

  /// Send gzip compressed JSON with `Content-Encoding: gzip`. Falls back to
  /// uncompressed bodies on platforms without `dart:io` (web).
  gzip,
}

/// Header types a [Dash0Propagator] can send.
enum Dash0PropagatorType {
  /// W3C `traceparent` header.
  traceparent,

  /// AWS `X-Amzn-Trace-Id` header.
  xray,
}

/// Defines which trace context header is sent to URLs matching [match].
class Dash0Propagator {
  const Dash0Propagator({required this.type, required this.match});

  /// Shorthand for a W3C `traceparent` propagator.
  const Dash0Propagator.traceparent(List<RegExp> match)
      : this(type: Dash0PropagatorType.traceparent, match: match);

  final Dash0PropagatorType type;
  final List<RegExp> match;
}

/// Metadata for a page view.
class Dash0PageViewMeta {
  const Dash0PageViewMeta({this.title, this.attributes});

  /// Defaults to the screen name.
  final String? title;
  final Map<String, Object?>? attributes;
}

/// Scrubs a URL attribute before it is added to a signal. Replace sensitive
/// parts with `REDACTED` instead of dropping them.
typedef UrlScrubber = String Function(String url);

/// Thresholds of the vitals instrumentation.
class Dash0VitalsOptions {
  const Dash0VitalsOptions({
    this.slowFrameThreshold = const Duration(microseconds: 16700),
    this.frozenFrameThreshold = const Duration(milliseconds: 700),
  });

  /// Frames taking longer are counted in `app.frame.slow`.
  final Duration slowFrameThreshold;

  /// Frames taking longer are counted in `app.frame.frozen`.
  final Duration frozenFrameThreshold;

  void validate() {
    if (slowFrameThreshold <= Duration.zero) {
      throw ArgumentError.value(
          slowFrameThreshold, 'slowFrameThreshold', 'must be positive');
    }
    if (frozenFrameThreshold < slowFrameThreshold) {
      throw ArgumentError.value(frozenFrameThreshold, 'frozenFrameThreshold',
          'must not be below slowFrameThreshold');
    }
  }
}

/// Settings of the rage click detection.
class Dash0RageClickOptions {
  const Dash0RageClickOptions({
    this.tapCount = 3,
    this.radius = 40,
    this.window = const Duration(seconds: 1),
    this.enableDeadTaps = false,
  });

  /// Number of taps that make a rage click.
  final int tapCount;

  /// Maximum distance in logical pixels between the taps.
  final double radius;

  /// All taps must happen within this time.
  final Duration window;

  /// Also send `app.dead_tap` for taps that hit nothing tappable. This is a
  /// heuristic and off by default.
  final bool enableDeadTaps;

  void validate() {
    if (tapCount < 2) {
      throw ArgumentError.value(tapCount, 'tapCount', 'must be at least 2');
    }
    if (radius <= 0) {
      throw ArgumentError.value(radius, 'radius', 'must be positive');
    }
    if (window <= Duration.zero) {
      throw ArgumentError.value(window, 'window', 'must be positive');
    }
  }
}

/// Settings of the session replay.
class Dash0ReplayOptions {
  const Dash0ReplayOptions({
    this.enabled = true,
    this.screenshotInterval,
    this.screenshotScale = 0.5,
    this.maxChunkEvents = 50,
    this.flushInterval = const Duration(seconds: 5),
    this.maskAllText = true,
    this.maxSessionDuration = const Duration(minutes: 30),
    this.maxChunks = 200,
  });

  /// Set to false to never install the recorder.
  final bool enabled;

  /// Interval of screenshots of the `Dash0ReplayBoundary`. Null (default)
  /// disables screenshots.
  final Duration? screenshotInterval;

  /// Pixel ratio of screenshots relative to logical pixels, for example 0.5
  /// halves the width and height.
  final double screenshotScale;

  /// A chunk is sent as soon as it holds this many events.
  final int maxChunkEvents;

  /// Maximum time events wait in a chunk.
  final Duration flushInterval;

  /// Blank all text (`Text` and text fields) in screenshots, not only the
  /// subtrees wrapped in `Dash0Mask`.
  final bool maskAllText;

  /// Recording stops this long after the first event of a session.
  final Duration maxSessionDuration;

  /// Maximum number of chunks per session.
  final int maxChunks;

  void validate() {
    if (screenshotInterval != null &&
        screenshotInterval! < const Duration(seconds: 1)) {
      throw ArgumentError.value(
          screenshotInterval, 'screenshotInterval', 'must be at least 1s');
    }
    if (screenshotScale <= 0 || screenshotScale > 2) {
      throw ArgumentError.value(
          screenshotScale, 'screenshotScale', 'must be in (0, 2]');
    }
    if (maxChunkEvents < 1) {
      throw ArgumentError.value(
          maxChunkEvents, 'maxChunkEvents', 'must be at least 1');
    }
    if (flushInterval <= Duration.zero) {
      throw ArgumentError.value(
          flushInterval, 'flushInterval', 'must be positive');
    }
    if (maxChunks < 1) {
      throw ArgumentError.value(maxChunks, 'maxChunks', 'must be at least 1');
    }
  }
}

/// Settings of the profiling instrumentation.
class Dash0ProfilingOptions {
  const Dash0ProfilingOptions({
    this.longTaskThreshold = const Duration(milliseconds: 250),
    this.anrThreshold = const Duration(seconds: 5),
    this.heartbeatInterval = const Duration(milliseconds: 100),
    this.useWatchdogIsolate = true,
    this.runtimeSampleInterval,
  });

  /// Main isolate stalls longer than this are reported as `app.long_task`.
  final Duration longTaskThreshold;

  /// Stalls longer than this are flagged as ANR.
  final Duration anrThreshold;

  /// Period of the main isolate heartbeat.
  final Duration heartbeatInterval;

  /// Also run a watchdog isolate that observes the heartbeat. Ignored on web.
  final bool useWatchdogIsolate;

  /// Interval of the runtime sampler (memory, image cache, frame totals).
  /// Null (default) disables it.
  final Duration? runtimeSampleInterval;

  void validate() {
    if (longTaskThreshold <= Duration.zero) {
      throw ArgumentError.value(
          longTaskThreshold, 'longTaskThreshold', 'must be positive');
    }
    if (anrThreshold < longTaskThreshold) {
      throw ArgumentError.value(
          anrThreshold, 'anrThreshold', 'must not be below longTaskThreshold');
    }
    if (heartbeatInterval <= Duration.zero) {
      throw ArgumentError.value(
          heartbeatInterval, 'heartbeatInterval', 'must be positive');
    }
    if (runtimeSampleInterval != null &&
        runtimeSampleInterval! < const Duration(seconds: 1)) {
      throw ArgumentError.value(
          runtimeSampleInterval, 'runtimeSampleInterval', 'at least 1 second');
    }
  }
}

/// Options for `Dash0.init`.
class Dash0Options {
  const Dash0Options({
    required this.serviceName,
    this.endpoint,
    this.endpoints = const [],
    this.serviceNamespace,
    this.serviceVersion,
    this.environment,
    this.deploymentName,
    this.deploymentId,
    this.resourceAttributes = const {},
    this.additionalSignalAttributes = const {},
    this.rejectSuspiciousServiceName = true,
    this.enabledInstrumentations,
    this.sessionSamplingRate = 100,
    this.sessionInactivityTimeout = const Duration(hours: 3),
    this.sessionTerminationTimeout = const Duration(hours: 6),
    this.propagators = const [],
    this.ignoreUrls = const [],
    this.ignoreErrorMessages = const [],
    this.headersToCapture = const [],
    this.urlScrubber,
    this.legacyAppNames = false,
    this.screenNameResolver,
    this.nameUnnamedRoutes = true,
    this.trackPopupRoutes = false,
    this.generatePageViewMetadata,
    this.batchSize = 15,
    this.batchDelay = const Duration(seconds: 1),
    this.collectUserAgent = true,
    this.debug = false,
    this.enabled = true,
    this.metricExportInterval = const Duration(seconds: 30),
    this.metricTemporality = Dash0AggregationTemporality.delta,
    this.compression = Dash0Compression.gzip,
    this.vitals = const Dash0VitalsOptions(),
    this.rageClicks = const Dash0RageClickOptions(),
    this.sessionReplaySamplingRate = 0,
    this.replay = const Dash0ReplayOptions(),
    this.profiling = const Dash0ProfilingOptions(),
  });

  /// Value of `service.name`.
  final String serviceName;

  /// Primary OTLP endpoint. At least one of [endpoint] or [endpoints] is
  /// required.
  final Dash0Endpoint? endpoint;

  /// Additional endpoints. Telemetry is sent to all endpoints.
  final List<Dash0Endpoint> endpoints;

  final String? serviceNamespace;
  final String? serviceVersion;

  /// Value of `deployment.environment.name`.
  final String? environment;
  final String? deploymentName;
  final String? deploymentId;

  /// Extra resource attributes, e.g. `app.version` or `device.model.name`.
  final Map<String, Object?> resourceAttributes;

  /// Attributes added to every signal.
  final Map<String, Object?> additionalSignalAttributes;

  /// When true (default), a [serviceName] containing characters commonly used
  /// in injection payloads is replaced by `unknown_service:flutter`.
  final bool rejectSuspiciousServiceName;

  /// Instrumentations to enable. Null enables all of them.
  final Set<Dash0Instrumentation>? enabledInstrumentations;

  /// Percentage (0 to 100) of sessions that record and send telemetry. The
  /// decision is deterministic per session id.
  final num sessionSamplingRate;

  /// Maximum time between two app starts or resumes before the session
  /// expires. Capped at 24 hours.
  final Duration sessionInactivityTimeout;

  /// Maximum session lifetime. Capped at 24 hours.
  final Duration sessionTerminationTimeout;

  /// Trace context propagation rules for outgoing HTTP requests. Without
  /// rules no trace headers are sent.
  final List<Dash0Propagator> propagators;

  /// Requests to matching URLs are not instrumented.
  final List<RegExp> ignoreUrls;

  /// Errors with a matching message are not reported.
  final List<RegExp> ignoreErrorMessages;

  /// Request and response headers matching any expression are captured as
  /// span attributes.
  final List<RegExp> headersToCapture;

  /// Applied to every URL before it is added to a signal. Credentials in URLs
  /// are always redacted before this is invoked.
  final UrlScrubber? urlScrubber;

  /// Uses the `app.*` names of SDK versions before 0.3.0 (`app.page_view`,
  /// `app.error`, `app.rage_click`, `dash0.app.event.*`, scope
  /// `dash0-flutter-sdk`) instead of the names of dash0-sdk-web
  /// (`browser.page_view`, `browser.error`, `browser.rage_click`,
  /// `dash0.web.event.*`, scope `dash0-web-sdk`).
  final bool legacyAppNames;

  /// Maps a route to a screen name. Falls back to `route.settings.name`.
  final String? Function(Route<dynamic> route)? screenNameResolver;

  /// Names routes without `RouteSettings.name` after the page widget they
  /// show (`/StatisticsScreen`), so that `Navigator.push(MaterialPageRoute(
  /// builder: ...))` is reported. [screenNameResolver] and route names take
  /// precedence.
  final bool nameUnnamedRoutes;

  /// Reports dialogs, bottom sheets and menus (`PopupRoute`s) as screens.
  /// Unnamed ones are named `/popup/<WidgetType>` (needs [nameUnnamedRoutes]).
  final bool trackPopupRoutes;

  /// Allows custom metadata for a page view. Return null for the default.
  final Dash0PageViewMeta? Function(String screenName)?
      generatePageViewMetadata;

  /// Number of queued signals that triggers an immediate transmission.
  final int batchSize;

  /// Maximum time a signal waits in the queue.
  final Duration batchDelay;

  /// Adds `user_agent.original` (the raw browser user agent, web only) to
  /// events, spans and logs, like dash0-sdk-web. Never added to metrics.
  /// `app.client.type` and the `browser.*` attributes are sent either way.
  final bool collectUserAgent;

  /// Print SDK diagnostics.
  final bool debug;

  /// Whether the client records signals right after start. Set to false to
  /// start disabled and switch on later with `Dash0.enabled = true`, without
  /// recording anything in between.
  final bool enabled;

  /// How often aggregated metrics are exported. Metrics are also exported on
  /// flush, when the app goes to the background and on shutdown.
  final Duration metricExportInterval;

  /// Aggregation temporality of sums and histograms.
  final Dash0AggregationTemporality metricTemporality;

  /// Compression of request bodies. Bodies below 1 KiB are never compressed.
  final Dash0Compression compression;

  /// Thresholds of the vitals instrumentation.
  final Dash0VitalsOptions vitals;

  /// Settings of the rage click detection.
  final Dash0RageClickOptions rageClicks;

  /// Percentage (0 to 100) of sessions that record a session replay. The
  /// decision is deterministic per session id and only applies to sessions
  /// that are sampled in by [sessionSamplingRate]. Default 0: no replay.
  final num sessionReplaySamplingRate;

  /// Settings of the session replay.
  final Dash0ReplayOptions replay;

  /// Settings of the profiling instrumentation.
  final Dash0ProfilingOptions profiling;

  /// All configured endpoints.
  List<Dash0Endpoint> get allEndpoints => [
        if (endpoint != null) endpoint!,
        ...endpoints,
      ];

  /// Whether [instrumentation] is enabled.
  bool isEnabled(Dash0Instrumentation instrumentation) =>
      enabledInstrumentations == null ||
      enabledInstrumentations!.contains(instrumentation);

  /// Whether [instrumentation] is listed in [enabledInstrumentations]. Used
  /// for opt-in instrumentations.
  bool isExplicitlyEnabled(Dash0Instrumentation instrumentation) =>
      enabledInstrumentations?.contains(instrumentation) ?? false;

  /// The service name after the suspicious value check.
  String get effectiveServiceName {
    if (rejectSuspiciousServiceName && !isSafeServiceName(serviceName)) {
      return 'unknown_service:flutter';
    }
    return serviceName;
  }

  /// Throws an [ArgumentError] if the options are invalid.
  void validate() {
    if (serviceName.trim().isEmpty) {
      throw ArgumentError.value(
          serviceName, 'serviceName', 'must not be empty');
    }
    if (sessionSamplingRate < 0 || sessionSamplingRate > 100) {
      throw ArgumentError.value(
        sessionSamplingRate,
        'sessionSamplingRate',
        'must be between 0 and 100',
      );
    }
    if (sessionReplaySamplingRate < 0 || sessionReplaySamplingRate > 100) {
      throw ArgumentError.value(
        sessionReplaySamplingRate,
        'sessionReplaySamplingRate',
        'must be between 0 and 100',
      );
    }
    final all = allEndpoints;
    if (all.isEmpty) {
      throw ArgumentError('At least one endpoint is required');
    }
    for (final e in all) {
      final uri = Uri.tryParse(e.url);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        throw ArgumentError.value(
            e.url, 'endpoint.url', 'must be an absolute URL');
      }
      if (e.authToken.isEmpty) {
        throw ArgumentError.value(
            e.authToken, 'endpoint.authToken', 'must not be empty');
      }
    }
    if (batchSize < 1) {
      throw ArgumentError.value(batchSize, 'batchSize', 'must be at least 1');
    }
    if (metricExportInterval < const Duration(seconds: 1)) {
      throw ArgumentError.value(
        metricExportInterval,
        'metricExportInterval',
        'must be at least 1 second',
      );
    }
    vitals.validate();
    rageClicks.validate();
    replay.validate();
    profiling.validate();
  }
}
