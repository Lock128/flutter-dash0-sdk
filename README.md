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
- Navigation: `Dash0NavigatorObserver` sends `app.page_view` events. Works with `Navigator`, `MaterialApp` and
  `go_router`.
- HTTP: `Dash0HttpClient` wraps a `package:http` client, creates client spans with OpenTelemetry HTTP attributes and
  injects W3C `traceparent` (or AWS X-Ray) headers.
- Errors: `FlutterError.onError` and `PlatformDispatcher.onError` are captured and sent as `app.error` events with
  sanitized stack traces. `Dash0.runGuarded` covers zones.
- App lifecycle events (`app.lifecycle`).
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

Routes need a name (`RouteSettings.name`; go_router sets it from the route `name`). Use `screenNameResolver` for other
schemes, `generatePageViewMetadata` to change the title or add attributes, and `Dash0.trackScreen(name)` for manual page
views. Dialogs and bottom sheets are not reported. The current screen is added to all later signals as
`app.screen.name`.

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
through `Dash0HttpClient` are not recorded twice. The spans end when the response body is fully read or fails, so
a response that is never read does not produce a span. On web `dart:io` is unavailable, install does nothing and
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

Limitations: there is no layout shift concept in Flutter. Frame timings come from `SchedulerBinding.addTimingsCallback`, which may report nothing on some web renderers, in which case the vitals stay empty. Interaction latency is measured with the SDK clock when the timing callback runs, so it can be slightly higher than the real value.

### Rage clicks

`Dash0Instrumentation.rageClicks` (on by default) sends `app.rage_click` when `tapCount` (3) taps land within `radius` (40 logical px) within `window` (1 s). Attributes: `app.screen.name`, `app.click.x`, `app.click.y` (rounded), `app.click.count` and `app.click.target` (render object type, never text). One burst sends one event. Set `Dash0RageClickOptions(enableDeadTaps: true)` to also send `app.dead_tap` for taps that hit nothing tappable (heuristic).

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

Event names starting with the SDK's own names (`app.page_view`, `app.error`, `app.lifecycle`) are rejected.

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
The resource contains `service.*`, `deployment.*`, `telemetry.sdk.*` (`dash0-flutter-sdk`, `dart`), `os.type` and
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
| `browser.page_view`, `browser.error` events | `app.page_view`, `app.error`, `app.lifecycle` events |
| `fetch` / `XMLHttpRequest` wrapping | `Dash0HttpClient` for `package:http` |
| `window.onerror`, unhandled rejections | `FlutterError.onError`, `PlatformDispatcher.onError`, `Dash0.runGuarded` |
| `localStorage` session | `shared_preferences` session |
| Tab id | `app.instance.id` |
| Last chance unload flush | Flush on `paused`, `hidden` and `detached` lifecycle states |
| Web vitals, session recording, rage clicks, profiling, transport compression | Not implemented |

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
