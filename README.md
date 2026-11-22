# Dash0 Flutter SDK

A Flutter SDK for [Dash0](https://www.dash0.com) real user monitoring, modeled on the
[dash0-sdk-web](https://github.com/dash0hq/dash0-sdk-web). It sends page views, HTTP client spans, errors, app
lifecycle events and custom events as OTLP/HTTP JSON directly to Dash0. It has no dependency on an OpenTelemetry Dart
package.

## Features

- `Dash0.init` with service and deployment metadata, resource attributes and signal attributes.
- Batched OTLP/HTTP JSON transport for `/v1/traces` and `/v1/logs` with `Authorization: Bearer` and optional
  `Dash0-Dataset` headers, rate limiting and flushing when the app goes to the background.
- Sessions that are persisted across app starts (inactivity and maximum age timeouts) with deterministic per-session
  sampling (`sessionSamplingRate`).
- Navigation: `Dash0NavigatorObserver` sends `browser.page_view` events. Works with `Navigator`, `MaterialApp` and
  `go_router`.
- HTTP: `Dash0HttpClient` wraps a `package:http` client, creates client spans with OpenTelemetry HTTP attributes and
  injects W3C `traceparent` (or AWS X-Ray) headers.
- Errors: `FlutterError.onError` and `PlatformDispatcher.onError` are captured and sent as `browser.error` events with
  sanitized stack traces. `Dash0.runGuarded` covers zones.
- App lifecycle events (`app.lifecycle`).
- Metrics, gzip compression, `dart:io` HTTP capture, web vitals equivalents, rage clicks, session replay and
  profiling (see the sections below).
- Console capture (opt-in), `Dash0.startView`, `Dash0.setParentTraceContext`, `vcs.*` resource attributes and
  build time deployment metadata through `--dart-define`.
- Public API: `sendEvent`, `startSpan`, `trace`, `reportError`, `identify`, `addSignalAttribute`,
  `removeSignalAttribute`, `terminateSession`, `flush`, `shutdown` and a runtime `enabled` switch.

## Supported platforms

iOS, Android, web, macOS, Windows and Linux.

## Installation

Install from [pub.dev](https://pub.dev/packages/dash0_flutter_sdk):

```yaml
dependencies:
  dash0_flutter_sdk: ^0.11.0
```

To track the latest unreleased code, use the git dependency instead:

```yaml
dependencies:
  dash0_flutter_sdk:
    git:
      url: https://github.com/Lock128/flutter-dash0-sdk.git
      ref: main
```

For local development use a path dependency (`path: ../flutter-dash0-sdk`).

## Usage

```dart
import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Dash0.init(
      Dash0Options(
        serviceName: 'my-app',
        serviceVersion: '1.4.0',
        environment: 'production',
        endpoint: const Dash0Endpoint(
          url: 'https://ingress.eu-west-1.aws.dash0.com',
          authToken: 'auth_xxx',
        ),
        sessionSamplingRate: 50,
        propagators: [
          Dash0Propagator.traceparent([RegExp(r'^https://api\.example\.com')]),
        ],
        ignoreUrls: [RegExp(r'/health$')],
      ),
    );
  } catch (e) {
    // Telemetry must never prevent the app from starting.
  }

  Dash0.runGuarded(() => runApp(const MyApp()));
}
```

### Navigation

```dart
MaterialApp(
  navigatorObservers: [Dash0.navigatorObserver],
  // ...
);

// go_router
GoRouter(observers: [Dash0.navigatorObserver], routes: [...]);
```

A route is named by, in this order: `screenNameResolver`, `RouteSettings.name` (go_router sets it from the route
`name`) and, for unnamed `MaterialPageRoute`/`PageRoute`s, the type of the page widget it shows (`/StatisticsScreen`,
`Dash0Options.nameUnnamedRoutes`, default `true`). The widget name is derived after the route was built, so it is
reported one frame after the push. In release web builds widget type names are minified, such as `minified:Ab`. Routes showing such a widget are not reported, so release web apps should use named routes (`RouteSettings.name`) or `screenNameResolver`. Query strings and fragments are removed from route names. Use
`generatePageViewMetadata` to change the title or add attributes, and `Dash0.trackScreen(name)` for manual page views.

Dialogs, bottom sheets and menus (`PopupRoute`s) are not reported unless `Dash0Options.trackPopupRoutes` is `true`.
Then named popups use their name and unnamed ones are reported as `/popup/<WidgetType>`. Popping returns to the
previous screen, which is reported again because the popup was the current screen. With `trackPopupRoutes` off the
previous screen is the same, so nothing is sent.

If the client is disabled (`Dash0Options(enabled: false)`, for example until a feature flag loads), page views are not
sent and the screen is not marked as seen. When `Dash0.enabled = true` is set, the latest screen is sent once as the
initial page view (`type` 0), so the first screen is not lost.

Every page view after the first has `app.screen.previous.duration_ms`, the time the previous screen was visible.
dash0-sdk-web sends all events (page views, `app.lifecycle`, `app.vitals`, `browser.web_vital`) as log records without
an end time, so they have no duration of their own. Dash0 derives a page view's duration from the following page view
(inferred, not verified), so a page view that is never followed by another has none.

#### Nested navigators and go_router

A `NavigatorObserver` can only be attached to one `Navigator`, and `Dash0.navigatorObserver` is a single shared
instance. Create one observer per navigator with `Dash0.createNavigatorObserver()`:

```dart
final router = GoRouter(
  observers: [Dash0.navigatorObserver],          // root navigator
  routes: [
    ShellRoute(
      observers: [Dash0.createNavigatorObserver()],   // the shell's navigator
      builder: (context, state, child) => Shell(child: child),
      routes: [GoRoute(path: '/home', name: 'home', builder: ...)],
    ),
    StatefulShellRoute.indexedStack(
      builder: ...,
      branches: [
        StatefulShellBranch(
          observers: [Dash0.createNavigatorObserver()],  // one per branch
          routes: [...],
        ),
      ],
    ),
  ],
);
```

The same applies to tab bars with their own `Navigator`s and to `Navigator` widgets nested in a screen.

### Tabs and other in screen views

A `TabBar` inside one route is one page view for the navigator observer. Wrap it with `Dash0TabObserver` to report each tab as its own page view, named `<parent>/<tab>`:

```dart
Dash0TabObserver(
  parent: '/admin',                       // the route's name
  tabs: const ['Overview', 'Failed Payments', 'Feature Flags'],
  controller: _tabController,
  index: () => _tabController.index,
  isChanging: () => _tabController.indexIsChanging,
  child: Column(children: [TabBar(...), Expanded(child: TabBarView(...))]),
)
// /admin (Overview), /admin/failed-payments, /admin/feature-flags
```

Names are lower-cased and non alphanumerics become `-`. Use fixed names, never ids or user data. The first tab is reported as the parent route (`/admin`) because the observer already sent that page view when the route was pushed. The widget takes closures instead of a `TabController`, so it works with any controller class, including `DefaultTabController.of(context)` and `material_ui`. Set `firstTabIsParent: false` to report `/admin/overview` as well. Changes are reported once they settle, so a tap is reported when the animation ends. Nothing is sent while the SDK is not initialized or disabled, and errors are never thrown into the UI.

For a `PageView` or a custom switcher call `trackSubScreen('/onboarding', 'platform-features')`.

### HTTP

```dart
final client = Dash0.httpClient();             // wraps a new http.Client
final client2 = Dash0.httpClient(myInnerClient); // wraps an existing one
await client.get(Uri.parse('https://api.example.com/items'));
```

Each request creates a span `HTTP GET` with `http.request.method`, `http.response.status_code`, `url.*` and
`error.type` for failures (status 400 and above, or exceptions). Requests to the telemetry endpoint and to URLs
matching `ignoreUrls` are not instrumented. Trace headers are only sent to URLs matched by `propagators`; there is no
same origin concept in an app, so no headers are sent by default. Requests made inside `Dash0.trace` become child spans
of it.

#### Capturing more HTTP traffic

| Path | Covers | Notes |
| --- | --- | --- |
| `Dash0.httpClient()` / `Dash0HttpClient` | Code that uses this `package:http` client | Works on all platforms including web. |
| `Dash0HttpOverrides` | Every `dart:io` `HttpClient`: `package:http` `IOClient`, Dio's default adapter, `NetworkImage`, most plugins | Mobile and desktop only. Opt-in. |
| Dio interceptor | Dio with a custom adapter, web | See below. |
| Amplify | Amplify API (REST and GraphQL) | See below. |

**HttpOverrides.** Add `Dash0Instrumentation.httpOverrides` to `enabledInstrumentations` (it is not part of the
default "all", because it changes global behavior) or call `Dash0.installHttpOverrides()` after `Dash0.init`:

```dart
await Dash0.init(Dash0Options(
  serviceName: 'my-app',
  endpoint: ...,
  enabledInstrumentations: {...Dash0Instrumentation.values},
));
```

An `HttpOverrides` that was installed earlier keeps working: the SDK wraps the clients it creates. Requests sent
through `Dash0HttpClient` are not recorded twice. The spans end when the response body is fully read, fails or is
cancelled by the consumer, or when a request is never closed for two minutes. A response that is opened but never
listened to does not produce a span. A redirect chain followed automatically by `dart:io` is one span, and
`response.redirect()` continuations are not instrumented. Install the overrides last: if the host app or a plugin
sets `HttpOverrides.global` afterwards, it replaces Dash0 without notice. On web `dart:io` is unavailable, install does nothing and
you should use `Dash0HttpClient` or the Dio interceptor.

**Dio.** Dio uses `dart:io` by default, so `HttpOverrides` already covers it. To instrument Dio on web or with a
custom adapter, add an interceptor (this package does not depend on Dio):

```dart
class Dash0DioInterceptor extends Interceptor {
  static const _key = 'dash0_span';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final span = Dash0.startSpan('HTTP ${options.method}', attributes: {
      'http.request.method': options.method,
      'url.full': options.uri.toString(),
    });
    if (span != null) {
      options.extra[_key] = span;
      options.headers['traceparent'] = formatTraceparent(span.traceId, span.spanId);
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final span = response.requestOptions.extra[_key] as Dash0Span?;
    span?.setAttribute('http.response.status_code', response.statusCode);
    span?.end();
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final span = err.requestOptions.extra[_key] as Dash0Span?;
    span?.setAttribute('http.response.status_code', err.response?.statusCode);
    span?.recordException(err, err.stackTrace);
    span?.end();
    handler.next(err);
  }
}
```

If you use both the interceptor and `HttpOverrides`, you get two spans per request; pick one. Only send
`traceparent` to hosts you trust (the SDK's `propagators` option is not applied by this snippet).

**Amplify.** `APIPluginOptions.baseHttpClient` (amplify_api_dart 0.5.x) takes an `AWSHttpClient` from `aws_common`,
not a `package:http` client, so `Dash0HttpClient` cannot be plugged in there. On mobile and desktop the default
`AWSHttpClient` is built on `dart:io`'s `HttpClient`, so `Dash0HttpOverrides` records Amplify API calls (HTTP/1.1
requests; requests that negotiate HTTP/2 through `package:http2` sockets are not seen). Amplify Auth and Storage
requests are covered the same way. On web use a custom `AWSHttpClient` wrapper or trace the calls with
`Dash0.trace`.

Every request recorded by `Dash0HttpClient` or `Dash0HttpOverrides` also records the histogram
`http.client.request.duration` (seconds) with `http.request.method`, `server.address`, `server.port`,
`http.response.status_code` and `error.type`. Switch it off by leaving `Dash0Instrumentation.metrics` out of
`enabledInstrumentations`.

#### HTTP stacks that are not instrumented

Clients that do not use `dart:io` through `HttpOverrides` or `package:http` (for example the AWS Amplify plugins, which
bring their own client) can create spans with `Dash0.startHttpRequest`. It returns `null` before init, while disabled,
when HTTP instrumentation is off or the URL matches `ignoreUrls`.

```dart
final span = Dash0.startHttpRequest('GET', url);
try {
  final response = await send(headers: {...?span?.propagationHeaders()});
  span?.captureHeaders(response.headers, request: false);
  span?.setResponse(response.statusCode, contentLength: response.contentLength);
} catch (e, st) {
  span?.finish(error: e, stackTrace: st);
  rethrow;
}
span?.finish();
```

The span matches the fetch instrumentation of dash0-sdk-web: name `HTTP <METHOD>`, kind client, `http.request.method`,
`url.*`, `http.response.status_code`, `error.type`, and error status for status codes of 400 and above and failures.

### GraphQL

GraphQL operations are named after the operation, not the endpoint. A span for `query GetX { ... }` is called
`HTTP POST GetX` and has `graphql.operation.name` and `graphql.operation.type` (`query`, `mutation` or
`subscription`), following the OpenTelemetry GraphQL conventions. Anonymous operations keep the name `HTTP POST` and
only get the type. The metric `graphql.client.operation.duration` (seconds) has the same two attributes, `server.address`
and `error.type` when the operation failed. At most 100 distinct operation names are used as metric attribute, further
names are recorded as `_OTHER`.

GraphQL servers answer errors with HTTP 200. When the response body has a non empty `errors` array, the span gets error
status and `error.type` (`errorType` of the first error, else `extensions.code`, else `GraphQLError`), and the
`http.client.request.duration` and GraphQL metrics carry the same `error.type`. Partial data with errors counts as an
error.

`Dash0HttpClient` names the operation of `http.Request` POST requests with a JSON body of up to 128 KiB. It cannot see
the response body, so errors in a 200 response are only detected with the helpers below. For HTTP stacks that are not
instrumented, such as AWS Amplify, inspect copies of the body streams (`split()` gives an independent copy that does not
consume the stream of the app):

```dart
final span = Dash0.startHttpRequest('POST', url);
final requestCopy = request.split(); // before sending
final response = await send(request);
span?.setGraphQLOperation(await Dash0GraphQL.inspectRequestBody(requestCopy));
span?.setResponse(response.statusCode);
final responseCopy = response.split(); // before the app reads the body
span?.setGraphQLErrors(await Dash0GraphQL.inspectResponse(
  responseCopy,
  headers: response.headers,
  statusCode: response.statusCode,
));
span?.finish();
```

`Dash0GraphQLOperation.tryParse(String body)` and `Dash0GraphQLErrors.tryParse(String body)` do the parsing for
bodies you already have. Amplify sends no `operationName`, so the name is read from the query document.

Privacy: the query text, variables and response data are never recorded, and neither are error messages, because
servers can echo user input in them. Only the operation name (valid GraphQL names up to 64 characters, others are
dropped), the operation type, the error type and the error count are used. Requests are only inspected for POST with a
JSON content type and a body up to 128 KiB. Responses are only read for 2xx with a JSON content type, up to 256 KiB and
for at most 2 seconds. Event streams are never read. Batched requests (JSON arrays) are not named.

### Verify signals in Dash0

- Logs: scope `dash0-web-sdk`, event names `browser.page_view`, `browser.web_vital`, `browser.error`,
  `browser.rage_click`, `app.vitals` and `app.lifecycle`.
- Traces: service `<name>`, spans `HTTP POST` (or `HTTP POST <OperationName>` for GraphQL) with `http.request.method`
  and `url.full` or `server.address`.
- Metrics: `http.client.request.duration`, `app.start.duration`, `app.frame.build.duration`,
  `app.frame.raster.duration`, `app.frame.slow`, `graphql.client.operation.duration` and your custom counters.

Page view, web vital and `app.vitals` log records show no duration. This is by design: the web SDK sends instantaneous
log records and Dash0 derives durations itself. `app.screen.previous.duration_ms` is a custom attribute.

### Metrics

```dart
final requests = Dash0.counter('app.requests', unit: '1', description: 'Handled requests');
final queue = Dash0.upDownCounter('app.queue.size');
final latency = Dash0.histogram('app.checkout.duration', unit: 's');
final battery = Dash0.gauge('device.battery.level', unit: '1');

requests.add(1, attributes: {'route': '/home'});
queue.add(-1);
latency.record(0.42);
battery.record(0.8);
```

Create instruments after `Dash0.init` and keep them; asking for the same name again returns the same instrument.
Values are aggregated in memory and sent to `/v1/metrics` every `metricExportInterval` (30 seconds), on `flush`,
when the app goes to the background and on shutdown. `metricTemporality` selects `delta` (default, each export
holds what happened since the last one, good for short lived apps) or `cumulative`. Histograms use explicit
buckets (default bounds suit durations in seconds, override with `boundaries:`) and report count, sum, min and max.
Each instrument tracks at most 2000 distinct attribute sets, further sets are dropped. Keep attributes low
cardinality. Metrics respect `enabled`, session sampling and the rate limit.

### Compression

Request bodies of 1 KiB or more are gzip compressed and sent with `Content-Encoding: gzip` for all signals
(`compression: Dash0Compression.gzip`, the default). Set `compression: Dash0Compression.none` to disable it. On
web, where `dart:io` is unavailable, bodies are always sent uncompressed (the browser controls the transfer). Make sure your collector accepts gzip, Dash0 does.

### Web vitals equivalents

Enabled by `Dash0Instrumentation.vitals` (on by default). Metrics additionally need `Dash0Instrumentation.metrics`.

| Web vital | Flutter equivalent |
| --- | --- |
| LCP | `app.start.duration` (SDK start to first frame, ms) and `app.screen.ttff` (screen change to first frame, ms) |
| INP | `app.interaction.latency` histogram (pointer up to next frame, ms), p98 per screen in `app.vitals` |
| CLS | not applicable, replaced by frame jank: `app.frame.slow` (over 16.7 ms) and `app.frame.frozen` (over 700 ms) counters |
| FID | not applicable |
| FPS | `app.frame.build.duration` and `app.frame.raster.duration` histograms |

An `app.vitals` event with `app.vitals.ttff_ms`, `frames_total`, `frames_slow`, `frames_frozen`, `interactions` and `interaction_p98_ms` is sent when the screen changes (needs the navigation instrumentation) and when the app goes to the background. Thresholds are configurable with `Dash0VitalsOptions`. Call `Dash0.client?.vitals?.markInteraction()` for custom gestures.

Limitations: there is no layout shift concept in Flutter. Frame timings come from `SchedulerBinding.addTimingsCallback`, which may report nothing on some web renderers, in which case the vitals stay empty. App start, time to first frame and interaction latency are measured with the SDK clock when the batched timing callback runs, so they can be higher than the real values by the batching delay. Frames seen while the SDK is disabled (for example while waiting for a feature flag) are not measured, and `app.start.duration` is not reported in that case; time to first frame then counts from the last unmeasured frame.

### Web Events compatibility

Since 0.3.0 the SDK emits the names that dash0-sdk-web uses, so that the data can show up next to website data in Dash0 Web Events. This is the default. Set `Dash0Options(legacyAppNames: true)` for the `app.*` names of 0.2.0 and earlier.

| Signal | Web SDK and default here | `legacyAppNames: true` |
| --- | --- | --- |
| Scope name, `telemetry.sdk.name` | `dash0-web-sdk` | `dash0-flutter-sdk` |
| Page view event | `browser.page_view` | `app.page_view` |
| Error event | `browser.error` | `app.error` |
| Rage click event | `browser.rage_click` | `app.rage_click` |
| Web vital event | `browser.web_vital` (`LCP`, `INP`) | not sent |
| Event title / id | `dash0.web.event.title`, `dash0.web.event.id` | `dash0.app.event.*` |
| Page URL | `page.url.full`, `.scheme`, `.domain`, `.path` | same |

`page.url.*` is added to every signal once a screen is known: `page.url.full` is `app://<screen>` (a leading `/` of the route name is dropped, so `/details` becomes `app://details`), `page.url.scheme` is `app`, `page.url.domain` is the service name and `page.url.path` is `/<screen>`. The full URL goes through `urlScrubber`. `app.screen.name` and `app.instance.id` are kept.

Flutter specific signals keep their `app.*` names in both modes: `app.vitals`, `app.lifecycle`, `app.dead_tap`, `app.long_task`, `app.session_replay` (not `browser.session_recording`, the payload differs), and all `app.*` metrics.

`browser.web_vital` log records have a body with `name`, `value` (ms) and `delta` (equal to `value`) and are sent together with `app.vitals` when a screen is left or the app goes to the background. They are Flutter approximations: `LCP` is the time to first frame of the screen and `INP` is the p98 interaction latency of the screen. `CLS` is not sent because Flutter has no equivalent.

Caveat: the Dash0 documentation does not state which fields classify data as a website. The `browser.*` names, the `dash0-web-sdk` scope and `page.url.*` are the best inference from dash0-sdk-web. Check the Web Events Explorer after deploying. If the events do not appear, ask Dash0 support how a third-party SDK can be recognized as a website. Data stays in the dataset of the environment you configure, so web and app data are separate unless you send them to the same one.

### Rage clicks

`Dash0Instrumentation.rageClicks` (on by default) sends `browser.rage_click` when `tapCount` (3) taps (pointer up within 18 px of the pointer down, so drags and scrolls do not count) land within `radius` (40 logical px) within `window` (1 s). Attributes: `app.screen.name`, `app.click.x`, `app.click.y` (rounded), `app.click.count` and `app.click.target` (render object type, never text). One burst sends one event. Set `Dash0RageClickOptions(enableDeadTaps: true)` to also send `app.dead_tap` for taps that hit nothing tappable (heuristic).

### Session replay

The web SDK records the DOM with rrweb. Flutter has no DOM, so the replay is an event stream by default:
taps, long presses, drags and scrolls (normalized `x`/`y` between 0 and 1, the render object type that was hit),
route changes, text field focus, blur and change markers, keyboard visibility, viewport and orientation changes
and app lifecycle changes. Screenshots are optional.

```dart
Dash0Options(
  // ...
  sessionReplaySamplingRate: 10, // percent of sessions, default 0 (off)
  replay: Dash0ReplayOptions(
    screenshotInterval: Duration(seconds: 10), // default null: no screenshots
    screenshotScale: 0.5,
  ),
)

runApp(Dash0ReplayBoundary(child: MyApp())); // only needed for screenshots
Dash0Mask(child: Image.asset('qr.png'));      // blanked in screenshots
```

Events are batched into chunks (50 events or 5 s, flushed when the app goes to the background and on session
change) and sent as `app.session_replay` log records. The body is a JSON string with `version`, `session_id`,
`sequence`, `start_ts`, `end_ts`, `viewport` and `events`; the record carries `app.replay.sequence` and
`app.replay.event_count`. The replay has its own sampling rate, deterministic per session id, and only applies to
sessions that `sessionSamplingRate` samples in. `Dash0.startReplay()` and `Dash0.stopReplay()` override the rate
for the current run. Replay records bypass the shared rate limiter and use their own caps
(`maxChunks` 200 per session, `maxSessionDuration` 30 minutes).

Privacy: text field values are never read, only markers (`obscured` tells password fields apart). Screenshots
blank every `Text` and text field (`maskAllText`, default true) and every `Dash0Mask` subtree before encoding;
only text and `Dash0Mask` subtrees are blanked. Images, avatars, user media, text painted with `CustomPaint` and platform views are
NOT detected, so wrap them in `Dash0Mask` or keep screenshots off (the default). Route names go into the stream, so
scrub identifiers from them (for example `/user/123`). Screenshots are PNG (Flutter has no JPEG encoder) and downscaled, but
still large: each is typically tens of KiB base64, so keep the interval high. Gzip compression helps a little.

### Profiling

Dart has no in-process sampling profiler API, so this is a set of cheap probes. Enable them with
`Dash0Instrumentation.profiling` in `enabledInstrumentations` (opt-in):

- Long tasks and ANRs: a heartbeat timer on the main isolate (100 ms) plus, where isolates exist, a watchdog
  isolate. A stall of at least `longTaskThreshold` (250 ms) sends an `app.long_task` event with
  `app.long_task.duration_ms`, `app.long_task.anr` (true from `anrThreshold`, 5 s), `app.long_task.source` and
  the current screen, plus the `app.long_task.duration` histogram. Monitoring pauses while the app is in the
  background.
- Runtime sampler: set `Dash0ProfilingOptions(runtimeSampleInterval: Duration(seconds: 10))` for gauges
  `process.runtime.dart.memory.rss`, `app.image_cache.size`, `app.image_cache.count`, `app.image_cache.live_count`
  and `app.runtime.frames`, `.slow` and `.frozen` (totals since start).
- `Dash0.profile(name, body)` wraps `body` in a span and adds `profile.duration_ms`, `profile.frames`,
  `profile.frames.slow`, `profile.frames.frozen`, `profile.rss.start`, `profile.rss.end` and `profile.rss.delta`.
  In debug mode it also adds `profile.stack.start` and `profile.stack.end` span events holding the stack of the caller at those two points. They are call site markers, not a sampled profile.
  It works without the profiling flag.

### Design decisions and platform limitations

| Feature | Android / iOS / desktop | Web |
| --- | --- | --- |
| Metrics, vitals, rage clicks | yes | yes (frame timings depend on the renderer) |
| gzip compression | yes | no, bodies are sent as is |
| Capture of all HTTP clients (`Dash0HttpOverrides`) | yes | no, use `Dash0HttpClient` |
| Replay events | yes | yes |
| Replay screenshots | yes | yes, where `RepaintBoundary.toImage` works |
| Long tasks (heartbeat) | yes | yes |
| Watchdog isolate | yes | no |
| RSS gauge and `profile.rss.*` | yes | no |

Known limits:

- No native CPU sampling or native thread stalls. A stall of the Dart main isolate is detected, but not its cause.
  Use DevTools or Dash0 traces to find out.
- The heartbeat cannot see a stall before it ends, so `app.long_task` is sent when the main isolate recovers. The
  watchdog reports ANRs that take longer than `anrThreshold` for the same reason with the duration seen so far.
- Replay is event-based, not pixel-based, so it cannot show what the user saw unless screenshots are enabled.
  Taps are recorded on the first matching pointer up, with the gesture ordered before its effects.
- The replay is lossy by design: chunks that cannot be sent are dropped, and recording stops at the caps.
- Wrapping a subtree in `Dash0Mask` only affects screenshots. Keep sensitive data out of route names and custom
  events yourself.

### Errors

`Dash0.init` hooks `FlutterError.onError` and `PlatformDispatcher.instance.onError` and still calls the handlers that
were installed before. Identical errors within one second are reported once and at most 100 errors are sent per app
run. Use `ignoreErrorMessages` to drop noisy errors and `Dash0.reportError(error, stackTrace: st)` for handled errors.
Stack traces are limited to 30 frames and URLs in them pass through `urlScrubber`. `exception.message` is cut to 300
characters and `exception.component_stack` to 2048, after URL scrubbing. `ignoreCrossOriginScriptErrors` and
`ignoreBrowserExtensionErrors` (both default `true`) drop `Script error.` and errors whose stack frames all belong to
browser extensions; they can only match on Flutter web.

### Console capture

Opt-in. List `Dash0Instrumentation.console` in `enabledInstrumentations` to send `browser.console` events
(`app.console` with `legacyAppNames`):

```dart
await Dash0.init(Dash0Options(
  serviceName: 'my-app',
  endpoint: endpoint,
  enabledInstrumentations: {
    Dash0Instrumentation.navigation,
    Dash0Instrumentation.error,
    Dash0Instrumentation.http,
    Dash0Instrumentation.lifecycle,
    Dash0Instrumentation.metrics,
    Dash0Instrumentation.console,
  },
  console: Dash0ConsoleOptions(ignoreMessages: ['noisy', RegExp(r'^token=')]),
));

Dash0.runGuarded(() => runApp(const MyApp())); // captures print in this zone
Dash0.log(Dash0ConsoleLevel.warn, 'Cache miss', error: e, stackTrace: st);
```

- Warning: everything printed through these sources is uploaded to Dash0 and only URLs are scrubbed. Do not print
  tokens or personal data, and add patterns such as `RegExp(r'token=|password')` to `ignoreMessages` to drop them.
- Sources: `debugPrint` (the original is still called), `print` inside `Dash0.runGuarded` and `Dash0.log`.
- Attributes: `dash0.web.console.method` (`log`, `info`, `warn`, `error`, `debug`, `trace`), the message as event body,
  `exception.*` when `Dash0.log` gets an `error`, `code.stacktrace` for `trace`. Severity: `trace` and `debug` are
  DEBUG, `log` and `info` INFO, `warn` WARN, `error` ERROR.
- Messages pass through the URL scrubber and are cut at `maxMessageLength` (4096) with the character `…`.
- Rate limits like the web SDK: beyond 5000 per 10 minutes or 200 per 10 seconds messages are dropped before they are
  formatted, beyond 1000 per 10 minutes or 50 per 10 seconds they are not sent. This budget is separate from the
  shared log budget.
- The SDK's own debug output is never captured. Nothing is sent for sampled out sessions or a disabled client.
- Anything else that calls `print` outside `Dash0.runGuarded` (including `Zone.root` prints) is not captured.

Verified from the web SDK source: event shape, attributes, severity mapping, limits. A guess: how the Dash0 UI shows
`browser.console` events.

### Page views, parent trace context and storage

- `Dash0.startView('Settings', url: '/settings', attributes: {...})` sends a virtual `browser.page_view` (type 1)
  without `change_state`, without changing the current screen and without `generatePageViewMetadata`. `url`
  overrides `page.url.*`: absolute http(s) and `app` URLs are used as is, anything else is a path on `app://`.
  Attributes are added last and can override. `Dash0.trackScreen` stays for compatibility.
- `Dash0.setParentTraceContext('00-<trace id>-<span id>-01')` makes spans without a parent (not started inside
  `Dash0.trace`) join that trace and use the span id as `parentSpanId`, for example to continue a trace started by a
  backend. `null` clears it, invalid values are ignored.
- `storageNamespace: 'docs'` stores the session under `docs:d0_session`, which separates several Flutter web apps on
  one origin.
- On Flutter web, requests to the page origin always get `traceparent` plus every configured propagator type.
  Aborted requests (`RequestAbortedException` of `package:http` 1.5) get `dash0.web.request.cancelled=true` and no
  error status.

### Build time metadata

`environment`, `deploymentName`, `deploymentId` and the `vcs` fields are read from `--dart-define` when the option is
null (set `disableVcsDetection: true` to skip `DASH0_VCS_*`):

```sh
flutter build web \
  --dart-define-from-file=otlp_config.json \
  --dart-define=DASH0_ENVIRONMENT=production \
  --dart-define=DASH0_DEPLOYMENT_NAME=web \
  --dart-define=DASH0_DEPLOYMENT_ID=$GITHUB_RUN_ID \
  --dart-define=DASH0_VCS_REPOSITORY_URL_FULL=https://github.com/me/app \
  --dart-define=DASH0_VCS_REF_HEAD_NAME=$GITHUB_REF_NAME \
  --dart-define=DASH0_VCS_REF_HEAD_REVISION=$GITHUB_SHA
```

Also supported: `DASH0_VCS_PROVIDER_NAME`, `DASH0_VCS_OWNER_NAME`, `DASH0_VCS_REPOSITORY_NAME`,
`DASH0_VCS_CHANGE_ID`. Provider, owner and repository name are derived from the repository URL when missing. They
become the resource attributes `vcs.provider.name`, `vcs.owner.name`, `vcs.repository.name`,
`vcs.repository.url.full`, `vcs.ref.head.name`, `vcs.ref.head.revision` and `vcs.change.id`. Verified from the web
SDK source; which Dash0 views read them is a guess.

### Custom events, spans and users

```dart
Dash0.sendEvent('checkout', title: 'Checkout completed', attributes: {'cart.size': 3});

await Dash0.trace('load-profile', (span) async {
  span?.setAttribute('user.tier', 'pro');
  // ...
});

Dash0.identify('user-1', email: 'a@example.com', roles: ['admin']);
Dash0.identify(null); // on logout
Dash0.addSignalAttribute('tenant', 'acme');
```

Event names starting with the SDK's own names (`browser.page_view`, `browser.error`, `browser.rage_click`, `browser.web_vital`, `app.lifecycle` and the other `app.*` SDK events) are rejected.

### Enable, disable and shutdown

```dart
Dash0.enabled = false; // drop all signals, e.g. controlled by a feature flag
Dash0.enabled = true;
await Dash0.flush();
await Dash0.shutdown(); // flush, restore error handlers, allow init again
```

## Configuration

| Option | Default | Description |
| --- | --- | --- |
| `serviceName` | required | `service.name`. Suspicious values (quotes, brackets, control characters) fall back to `unknown_service:flutter` unless `rejectSuspiciousServiceName` is false. |
| `endpoint` / `endpoints` | required | `Dash0Endpoint(url, authToken, dataset)`. The URL excludes `/v1/*`. All endpoints receive all telemetry. |
| `serviceNamespace`, `serviceVersion`, `environment`, `deploymentName`, `deploymentId` | none | Resource attributes (`deployment.environment.name` for `environment`). |
| `resourceAttributes` | `{}` | Extra resource attributes, for example app build or device model. |
| `additionalSignalAttributes` | `{}` | Attributes added to every signal. |
| `enabledInstrumentations` | all | Subset of `navigation`, `error`, `http`, `lifecycle`, `metrics`. `httpOverrides`, `profiling` and `console` are opt-in: they are only active when listed explicitly. |
| `sessionSamplingRate` | `100` | Percentage of sessions that send data, 0 to 100. Decided from the session id with CRC32. |
| `sessionInactivityTimeout` | 3 hours | Maximum idle time between app starts or resumes. Capped at 24 hours. |
| `sessionTerminationTimeout` | 6 hours | Maximum session age. Capped at 24 hours. |
| `propagators` | `[]` | `Dash0Propagator(type, match)` rules for trace headers (`traceparent` or `xray`). |
| `ignoreUrls` | `[]` | `List<Pattern>`: strings (substring) or `RegExp`. Requests to matching URLs are not traced. Also redacts them in stack traces. |
| `ignoreErrorMessages` | `[]` | `List<Pattern>`. Errors with a matching message are not reported. |
| `headersToCapture` | `[]` | Request and response headers whose names match are captured as span attributes. |
| `urlScrubber` | none | Function applied to every URL attribute. Credentials in URLs are always redacted first. |
| `screenNameResolver` | route name | Custom mapping from `Route` to screen name. |
| `nameUnnamedRoutes` | `true` | Name routes without `RouteSettings.name` after their page widget (`/StatisticsScreen`). |
| `trackPopupRoutes` | `false` | Report dialogs and bottom sheets as screens (`/popup/<WidgetType>` when unnamed). |
| `generatePageViewMetadata` | none | Custom title and attributes per page view. |
| `batchSize`, `batchDelay` | `15`, 1 second | Batching of signals. |
| `metricExportInterval` | 30 seconds | How often metrics are exported, at least 1 second. |
| `metricTemporality` | `delta` | `Dash0AggregationTemporality.delta` or `cumulative`. |
| `compression` | `gzip` | `Dash0Compression.gzip` or `none`. Bodies under 1 KiB are never compressed. |
| `vcs`, `disableVcsDetection` | none, `false` | `Dash0VcsAttributes` for `vcs.*` resource attributes, detected from `DASH0_VCS_*` dart-defines when null. |
| `storageNamespace` | none | Prefix for persisted keys, `<namespace>:d0_session`. |
| `console` | `Dash0ConsoleOptions()` | `ignoreMessages`, `maxMessageLength` (4096), `captureDebugPrint`, `capturePrint`. Needs `Dash0Instrumentation.console`. |
| `ignoreCrossOriginScriptErrors`, `ignoreBrowserExtensionErrors` | `true`, `true` | Drop `Script error.` and extension only stacks. Flutter web only in practice. |
| `debug` | `false` | Print SDK diagnostics. |

## Sessions and resources

A session id (16 hex characters) is stored in `shared_preferences` under `d0_session` and added to every signal as
`session.id`. Trace ids embed the session id (`d042` + flags + session id + random) and span ids start with the CRC32 of
the trace id, like in dash0-sdk-web. `app.instance.id` identifies one app launch (the equivalent of `browser.tab.id`).
The resource contains `service.*`, `deployment.*`, `telemetry.sdk.*` (`dash0-web-sdk`, `dart`), `os.type`, the client attributes above and
`app.locale`. Add `app.version`, device information and similar with `resourceAttributes`, for example from
`package_info_plus`.

### Client type: web, mobile web and native

All signals say where the app runs, so you can tell the desktop web build from the mobile web build and from the
native apps.

| Attribute | Where | Values |
| --- | --- | --- |
| `app.client.type` | resource, events, spans, logs | `web-desktop`, `web-mobile`, `ios`, `android`, `macos`, `windows`, `linux`, `fuchsia` |
| `app.runtime` | resource | `flutter-web`, `flutter-native` |
| `os.name` | resource | `iOS`, `Android`, `macOS`, `Windows`, `Linux`, `ChromeOS`, `Fuchsia` |
| `browser.mobile`, `browser.platform`, `browser.brands` | resource, web only | `true`/`false`, the OS name, brand names such as `Chromium` (only with `navigator.userAgentData`) |
| `user_agent.original` | events, spans, logs, web only | the browser user agent, like dash0-sdk-web (`undefined` when the browser has none) |
| `page.load.id` | events, spans, logs, web only | random id, once per client (page load) |
| `browser.tab.id` | events, spans, logs, web only | random id, once per client. A Flutter web app runs once per tab, so this is one id per tab |
| `browser.window.width`, `browser.window.height` | events, spans, logs, web only | `window.innerWidth` and `innerHeight` when the signal is recorded |
| `network.connection.subtype` | events, spans, logs, web only | `navigator.connection.effectiveType` (`4g`, `3g`, ...), only when the browser has it |

`web-mobile` covers phones and tablets in a browser. It is decided by `navigator.userAgentData.mobile` when the browser
has it, otherwise by the user agent (`Android|iPhone|iPad|iPod|Mobile`). iPadOS Safari in desktop mode sends a Mac user
agent and is recognized by its touch points. An Android browser in "desktop site" mode reports a desktop user agent and
is classified as `web-desktop`. `os.type` keeps its earlier values (`web` or the Flutter platform name).

The SDK does not read native device details (model, OS version). Add them with `resourceAttributes`, for example from
`device_info_plus`, using the OpenTelemetry names `device.model.identifier`, `device.manufacturer` and `os.version`.
Values from `resourceAttributes` replace the detected ones.

`user_agent.original` can identify individual browsers. Set `collectUserAgent: false` to leave it out. The other
attributes stay, and none of them is high cardinality. Dash0's browser and device breakdowns for websites may rely on
the user agent, so turn it off only when policy requires.

`userAgentOnResource: true` additionally puts `user_agent.original` on the resource of logs and spans (web only, never
metrics). dash0-sdk-web sends it on signals only, so this is a diagnostic hedge in case Dash0 reads the user agent from
the resource.

`syntheticUserAgent: true` is for native apps, which have no browser user agent. It sends
`<service.name>/<service.version> (<os.name> <os.version>; <device>)` as `user_agent.original` on events, spans and
logs, plus `app.client.user_agent.synthetic=true`. `os.version` and the device come from `resourceAttributes`
(`os.version`, `device.model.identifier` or `device.model.name`); missing parts are left out. iOS and iPadOS use the
form user agent parsers recognise as an OS, see below. This is a hack: Dash0 may
parse the string imperfectly. It is never used on the web and needs `collectUserAgent`.

### Native apps (iOS, Android)

Attributes a native app sends:

| Attribute | Where | Value |
| --- | --- | --- |
| `app.client.type` | resource, events, spans, logs | `ios` or `android` |
| `app.runtime` | resource | `flutter-native` |
| `os.name` | resource | `iOS` or `Android` |
| `os.type` | resource | the Flutter platform name: `iOS`, `android`, `macOS` |
| `app.instance.id`, `session.id` | resource / signals | one id per launch, session id |
| `user_agent.original`, `app.client.user_agent.synthetic` | events, spans, logs, only with `syntheticUserAgent: true` | see below |

`browser.*`, `page.load.id`, `network.connection.subtype` and the browser `user_agent.original` are web only. Native
apps send no `user_agent.original` unless `syntheticUserAgent` is on. `os.type` keeps the Flutter platform name
(`iOS`, `android`, `macOS`), which differs from the casing in the OpenTelemetry semantic conventions.

Add `os.version`, `device.model.identifier` and `device.manufacturer` through `resourceAttributes` (for example from
`device_info_plus`). `os.name` in `resourceAttributes` also replaces the detected value, so an iPad app can report
`iPadOS`.

`syntheticUserAgent: true` lets the Dash0 Websites view fill the System and Browser columns for native sessions. The
string, for example `nexus-share-flutter/1.2.3+45 (iPhone; CPU iPhone OS 17_2 like Mac OS X; iPhone15,2)`, is made up by the SDK and flagged with
`app.client.user_agent.synthetic=true` on events, spans and logs (not on the resource or metrics). Every part is
stripped of control characters, parentheses and semicolons and capped at 64 characters. That Dash0 parses it this way
is an inference and has not been verified.

iOS and iPadOS (`os.name` `iOS` or `iPadOS`, or a device identifier starting with `iPad`) use the WebKit comment form,
because Dash0 only derives `user_agent.os.name` and `user_agent.os.version` from it: `(iPhone; CPU iPhone OS 17_2 like
Mac OS X; iPhone15,2)` and `(iPad; CPU OS 17_2 like Mac OS X; iPad13,1)`. Version dots become underscores. This needs
`os.version` with at least two numeric parts; otherwise the plain `(iOS 17; device)` form is sent. Android and other
platforms keep `(Android 16; device)`, which already parses. No browser name is added.

Native sessions can also be filtered by `app.client.type` in Logs, Traces and Metrics.

### Sessions table shows empty System and Browser

Dash0 fills these columns from `user_agent.original`. To check what the app sends, open the browser dev tools, Network
tab, filter for `v1/logs`, and look at the request payload (the gzipped body is shown decoded in the Preview tab). Each
`logRecords[].attributes` entry should contain `user_agent.original`. If it is missing, check that the deployed build
uses SDK 0.6.0 or newer (`telemetry.sdk.version` in the resource), and that `collectUserAgent` is not `false`. Set
`debug: true` to log whether the user agent is attached. If the attribute is present, try `userAgentOnResource: true`.
Sessions that started before the upgrade keep empty columns.

## Security note

The `authToken` is compiled into the app and can be extracted by anyone. Use a Dash0 auth token that is restricted to
ingesting telemetry for the needed dataset, never an admin or query token. Pass it with `--dart-define` instead of
committing it, and rotate it if it leaks. Use `urlScrubber` and `ignoreUrls` to keep sensitive URL parts out of
telemetry.

## Differences to dash0-sdk-web

| Web SDK | Flutter SDK |
| --- | --- |
| `browser.page_view`, `browser.error` events | Same names by default (`legacyAppNames` restores `app.page_view`, `app.error`); `app.lifecycle` is Flutter specific |
| `fetch` / `XMLHttpRequest` wrapping | `Dash0HttpClient` for `package:http` |
| `window.onerror`, unhandled rejections | `FlutterError.onError`, `PlatformDispatcher.onError`, `Dash0.runGuarded` |
| `localStorage` session | `shared_preferences` session |
| Tab id | `app.instance.id` |
| Last chance unload flush | Flush on `paused`, `hidden` and `detached` lifecycle states |
| Web vitals | Frame based equivalents, see "Web vitals equivalents" |
| rrweb session recording | Event-based replay with optional masked screenshots |
| Rage clicks | `browser.rage_click` events |
| Profiling | Long task / ANR detection, runtime gauges and `Dash0.profile` |
| Transport compression | gzip (not on web) |
| `console` wrapping | `debugPrint`, `print` in `Dash0.runGuarded` and `Dash0.log`, opt-in |
| `startView`, `setParentTraceContext` | `Dash0.startView`, `Dash0.setParentTraceContext` |
| `wrapEventHandlers`, `wrapTimers` | Not applicable: no JS event handler or timer wrapping in Dart |
| Resource timing waits, `browser.navigation_timing` | Not applicable: no `PerformanceResourceTiming` or document load. See `app.start.duration` in `app.vitals` |
| Page load trace context (meta tag, Server-Timing) | Not applicable, use `setParentTraceContext` |
| History API virtual page views, script tag entry point, XHR | Not applicable |
| `urlAttributeScrubber` (record of URL attributes) | `urlScrubber` works on the URL string |
| Numbers sent as `doubleValue`, status code as string | Ints as `intValue`, status code as int (OTLP allows both, a guess that Dash0 accepts both) |

The full comparison, with web SDK source paths for each row and what is verified or a guess, is in
[doc/web-sdk-gap-analysis.md](doc/web-sdk-gap-analysis.md).

## Publishing

The package is published on [pub.dev](https://pub.dev/packages/dash0_flutter_sdk). Release steps are in [doc/publishing.md](doc/publishing.md).

## Development

```sh
flutter pub get
flutter analyze
dart format --set-exit-if-changed .
flutter test
cd example && flutter pub get && flutter analyze
```

## License

Apache-2.0, like the reference SDK.
