/// Attribute keys, event names and enumerations used by the SDK.
///
/// Mirrors `semantic-conventions.ts` of dash0-sdk-web. Flutter specific
/// signals use the `app.` prefix. The names shared with the web SDK are
/// resolved at runtime through [Dash0Names].
library;

// Resource attributes
const serviceName = 'service.name';
const serviceNamespace = 'service.namespace';
const serviceVersion = 'service.version';
const deploymentEnvironmentName = 'deployment.environment.name';
const deploymentName = 'deployment.name';
const deploymentId = 'deployment.id';
const telemetrySdkName = 'telemetry.sdk.name';
const telemetrySdkLanguage = 'telemetry.sdk.language';
const telemetrySdkVersion = 'telemetry.sdk.version';
const osType = 'os.type';
const osName = 'os.name';
const appClientType = 'app.client.type';
const appRuntime = 'app.runtime';
const browserMobile = 'browser.mobile';
const browserPlatform = 'browser.platform';
const browserBrands = 'browser.brands';
const userAgentOriginal = 'user_agent.original';

// Misc signal attributes
const eventName = 'event.name';
const eventTitle = 'dash0.app.event.title';
const eventId = 'dash0.app.event.id';
const _legacyEventTitle = eventTitle;
const _legacyEventId = eventId;
const webEventTitle = 'dash0.web.event.title';
const webEventId = 'dash0.web.event.id';
const sessionId = 'session.id';
const appInstanceId = 'app.instance.id';
const appScreenName = 'app.screen.name';
const appLocale = 'app.locale';
const appLifecycleState = 'app.lifecycle.state';
const errorComponentStack = 'exception.component_stack';

// User attributes
const userId = 'user.id';
const userName = 'user.name';
const userFullName = 'user.full_name';
const userEmail = 'user.email';
const userHash = 'user.hash';
const userRoles = 'user.roles';

// Exception attributes
const exceptionMessage = 'exception.message';
const exceptionType = 'exception.type';
const exceptionStacktrace = 'exception.stacktrace';
const errorType = 'error.type';

// Page URL attributes (dash0-sdk-web attributes/url.ts with a `page` prefix)
const pageUrlFull = 'page.url.full';
const pageUrlScheme = 'page.url.scheme';
const pageUrlDomain = 'page.url.domain';
const pageUrlPath = 'page.url.path';

// URL attributes
const urlDomain = 'url.domain';
const urlFragment = 'url.fragment';
const urlFull = 'url.full';
const urlPath = 'url.path';
const urlQuery = 'url.query';
const urlScheme = 'url.scheme';

// HTTP attributes
const httpRequestMethod = 'http.request.method';
const httpRequestMethodOriginal = 'http.request.method_original';
const httpRequestHeader = 'http.request.header';
const httpResponseStatusCode = 'http.response.status_code';
const httpResponseHeader = 'http.response.header';
const httpResponseBodySize = 'http.response.body.size';
const serverAddress = 'server.address';
const serverPort = 'server.port';

// Metric names
const metricHttpClientRequestDuration = 'http.client.request.duration';

// Vitals metrics
const metricAppStartDuration = 'app.start.duration';
const metricScreenTtff = 'app.screen.ttff';
const metricInteractionLatency = 'app.interaction.latency';
const metricFrameBuildDuration = 'app.frame.build.duration';
const metricFrameRasterDuration = 'app.frame.raster.duration';
const metricFrameSlow = 'app.frame.slow';
const metricFrameFrozen = 'app.frame.frozen';

// app.vitals event attributes
const vitalsTtffMs = 'app.vitals.ttff_ms';
const vitalsFramesTotal = 'app.vitals.frames_total';
const vitalsFramesSlow = 'app.vitals.frames_slow';
const vitalsFramesFrozen = 'app.vitals.frames_frozen';
const vitalsInteractions = 'app.vitals.interactions';
const vitalsInteractionP98Ms = 'app.vitals.interaction_p98_ms';
const vitalsTrigger = 'app.vitals.trigger';

// Profiling
const metricLongTaskDuration = 'app.long_task.duration';
const metricRuntimeRss = 'process.runtime.dart.memory.rss';
const metricImageCacheSize = 'app.image_cache.size';
const metricImageCacheCount = 'app.image_cache.count';
const metricImageCacheLive = 'app.image_cache.live_count';
const metricRuntimeFrames = 'app.runtime.frames';
const metricRuntimeFramesSlow = 'app.runtime.frames.slow';
const metricRuntimeFramesFrozen = 'app.runtime.frames.frozen';
const longTaskDurationMs = 'app.long_task.duration_ms';
const longTaskAnr = 'app.long_task.anr';
const longTaskSource = 'app.long_task.source';

// Rage click and dead tap event attributes
const clickX = 'app.click.x';
const clickY = 'app.click.y';
const clickCount = 'app.click.count';
const clickTarget = 'app.click.target';

/// Event names reserved for the SDK. Custom events may not use them.
class EventNames {
  EventNames._();

  // Legacy names, used with `Dash0Options.legacyAppNames`.
  static const pageView = 'app.page_view';
  static const error = 'app.error';
  static const rageClick = 'app.rage_click';

  // Names used by dash0-sdk-web, the default.
  static const webPageView = 'browser.page_view';
  static const webError = 'browser.error';
  static const webRageClick = 'browser.rage_click';
  static const webVital = 'browser.web_vital';

  static const lifecycle = 'app.lifecycle';

  static const vitals = 'app.vitals';
  static const deadTap = 'app.dead_tap';
  static const sessionReplay = 'app.session_replay';
  static const longTask = 'app.long_task';

  static const all = <String>{
    pageView,
    error,
    webPageView,
    webError,
    webRageClick,
    webVital,
    lifecycle,
    vitals,
    rageClick,
    deadTap,
    sessionReplay,
    longTask,
  };
}

/// Names that differ between the web compatible and the legacy `app.*`
/// naming. See `Dash0Options.legacyAppNames`.
class Dash0Names {
  const Dash0Names._({
    required this.sdkName,
    required this.pageView,
    required this.error,
    required this.rageClick,
    required this.eventTitle,
    required this.eventId,
  });

  /// Scope name and `telemetry.sdk.name`.
  final String sdkName;
  final String pageView;
  final String error;
  final String rageClick;
  final String eventTitle;
  final String eventId;

  /// Names of dash0-sdk-web (default).
  static const web = Dash0Names._(
    sdkName: 'dash0-web-sdk',
    pageView: EventNames.webPageView,
    error: EventNames.webError,
    rageClick: EventNames.webRageClick,
    eventTitle: webEventTitle,
    eventId: webEventId,
  );

  /// Names of SDK versions before 0.3.0.
  static const legacy = Dash0Names._(
    sdkName: 'dash0-flutter-sdk',
    pageView: EventNames.pageView,
    error: EventNames.error,
    rageClick: EventNames.rageClick,
    eventTitle: _legacyEventTitle,
    eventId: _legacyEventId,
  );
}

const spanEventNameException = 'exception';

/// Log severities (OTLP severity numbers).
enum Dash0Severity {
  trace(1, 'TRACE'),
  debug(5, 'DEBUG'),
  info(9, 'INFO'),
  warn(13, 'WARN'),
  error(17, 'ERROR'),
  fatal(21, 'FATAL');

  const Dash0Severity(this.number, this.text);
  final int number;
  final String text;
}

// Page view event attributes
const pageViewType = 'type';
const pageViewChangeState = 'change_state';
const pageViewReferrer = 'app.screen.referrer';

/// Milliseconds the previous screen was visible.
const pageViewPreviousDuration = 'app.screen.previous.duration_ms';
const pageViewTypeInitial = 0;
const pageViewTypeVirtual = 1;

/// Span status codes.
const spanStatusUnset = 0;
const spanStatusOk = 1;
const spanStatusError = 2;

/// Span kinds.
const spanKindInternal = 1;
const spanKindClient = 3;
