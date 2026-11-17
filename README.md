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
- Public API: `sendEvent`, `startSpan`, `trace`, `reportError`, `identify`, `addSignalAttribute`,
  `removeSignalAttribute`, `terminateSession`, `flush`, `shutdown` and a runtime `enabled` switch.

## Installation

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
  controller: _tabController,             // or omit to use DefaultTabController
  child: Column(children: [TabBar(...), Expanded(child: TabBarView(...))]),
)
// /admin (Overview), /admin/failed-payments, /admin/feature-flags
```

Names are lower-cased and non alphanumerics become `-`. Use fixed names, never ids or user data. The first tab is reported as the parent route (`/admin`) because the observer already sent that page view when the route was pushed. Set `firstTabIsParent: false` to report `/admin/overview` as well. Changes are reported once they settle, so a tap is reported when the animation ends. Nothing is sent while the SDK is not initialized or disabled, and errors are never thrown into the UI.

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
Stack traces are limited to 30 frames and URLs in them pass through `urlScrubber`.

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
| `enabledInstrumentations` | all | Subset of `navigation`, `error`, `http`, `lifecycle`, `metrics`. `httpOverrides` is opt-in: it is only active when listed explicitly. |
| `sessionSamplingRate` | `100` | Percentage of sessions that send data, 0 to 100. Decided from the session id with CRC32. |
| `sessionInactivityTimeout` | 3 hours | Maximum idle time between app starts or resumes. Capped at 24 hours. |
| `sessionTerminationTimeout` | 6 hours | Maximum session age. Capped at 24 hours. |
| `propagators` | `[]` | `Dash0Propagator(type, match)` rules for trace headers (`traceparent` or `xray`). |
| `ignoreUrls` | `[]` | Requests to matching URLs are not traced. Also redacts them in stack traces. |
| `ignoreErrorMessages` | `[]` | Errors with a matching message are not reported. |
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
| `debug` | `false` | Print SDK diagnostics. |

## Sessions and resources

A session id (16 hex characters) is stored in `shared_preferences` under `d0_session` and added to every signal as
`session.id`. Trace ids embed the session id (`d042` + flags + session id + random) and span ids start with the CRC32 of
the trace id, like in dash0-sdk-web. `app.instance.id` identifies one app launch (the equivalent of `browser.tab.id`).
The resource contains `service.*`, `deployment.*`, `telemetry.sdk.*` (`dash0-web-sdk`, `dart`), `os.type` and
`app.locale`. Add `app.version`, device information and similar with `resourceAttributes`, for example from
`package_info_plus`.

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
