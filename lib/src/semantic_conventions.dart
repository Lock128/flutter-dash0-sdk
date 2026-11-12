/// Attribute keys, event names and enumerations used by the SDK.
///
/// Mirrors `semantic-conventions.ts` of dash0-sdk-web. Event names use the
/// `app.` prefix instead of `browser.`.
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

// Misc signal attributes
const eventName = 'event.name';
const eventTitle = 'dash0.app.event.title';
const eventId = 'dash0.app.event.id';
const requestCancelled = 'dash0.app.request.cancelled';
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

// Rage click and dead tap event attributes
const clickX = 'app.click.x';
const clickY = 'app.click.y';
const clickCount = 'app.click.count';
const clickTarget = 'app.click.target';

/// Event names reserved for the SDK. Custom events may not use them.
class EventNames {
  EventNames._();

  static const pageView = 'app.page_view';
  static const error = 'app.error';
  static const lifecycle = 'app.lifecycle';

  static const vitals = 'app.vitals';
  static const rageClick = 'app.rage_click';
  static const deadTap = 'app.dead_tap';

  static const all = <String>{
    pageView,
    error,
    lifecycle,
    vitals,
    rageClick,
    deadTap,
  };
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
const pageViewTypeInitial = 0;
const pageViewTypeVirtual = 1;

/// Span status codes.
const spanStatusUnset = 0;
const spanStatusOk = 1;
const spanStatusError = 2;

/// Span kinds.
const spanKindInternal = 1;
const spanKindClient = 3;
