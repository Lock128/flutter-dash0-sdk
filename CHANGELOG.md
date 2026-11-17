# Changelog

## 0.5.0

- Add `Dash0TabObserver`, a widget that sends a page view (`/admin/failed-payments`) whenever the selected tab of a `TabController` or `DefaultTabController` settles. Taps, `animateTo` and swipes are reported, mid animation changes and unchanged indexes are not. The first tab is reported as the parent route by default, because the route's own page view already covers it.
- Add `trackSubScreen` and `subScreenPath` for in screen views without a `TabController`, such as a `PageView`.
- Page views from sub screens have `change_state` `tab`.

## 0.4.0

- Fix the initial page view being lost when the client starts disabled: the latest screen seen while disabled is sent as the initial page view when `Dash0.enabled = true` is set. Screens are no longer marked as seen while nothing was sent.
- Report routes without `RouteSettings.name` by the type of their page widget (`/StatisticsScreen`). Controlled by `Dash0Options.nameUnnamedRoutes` (default `true`).
- Add `Dash0Options.trackPopupRoutes` (default `false`) to report dialogs and bottom sheets (`/popup/<WidgetType>` when unnamed).
- Strip query strings and fragments from route names.
- Add `Dash0.createNavigatorObserver()` for nested navigators, `ShellRoute` and `StatefulShellRoute`, and document go_router usage.
- Add `app.screen.previous.duration_ms` to page views, the time the previous screen was visible. Time while the app was in the background is not counted.
- Routes named after a minified widget type (release web builds) are not reported, because their names are unstable and indistinguishable. Use named routes or `screenNameResolver` in release web apps.
- Add `Dash0.startHttpRequest` and `Dash0HttpSpan` to create HTTP client spans for HTTP stacks the SDK cannot instrument, such as Amplify.

## 0.3.0

- **Breaking:** the default names now match dash0-sdk-web so that Dash0 Web Events can recognize the data: scope and `telemetry.sdk.name` `dash0-web-sdk`, events `browser.page_view`, `browser.error`, `browser.rage_click`, and attributes `dash0.web.event.title`, and `dash0.web.event.id`. Set `Dash0Options.legacyAppNames` to keep the 0.2.0 names.
- Add `page.url.full`, `page.url.scheme`, `page.url.domain` and `page.url.path` (`app://<screen>`) to all signals once a screen is known.
- Add `browser.web_vital` events for `LCP` (time to first frame) and `INP` (p98 interaction latency), sent with `app.vitals`. Not sent with `legacyAppNames`.
- `browser.*` event names are reserved for custom events. Flutter specific `app.*` events and metrics are unchanged.

## 0.2.0

- Export metrics when the app goes to the background and when a session is terminated, end HTTP spans of cancelled response streams and of requests that are never closed, do not report start up vitals for time spent while disabled, count rage clicks on taps instead of every pointer down, and document the screenshot masking and profiling limits.
- Add event-based session replay (`Dash0Instrumentation.sessionReplay`, `Dash0Options.sessionReplaySamplingRate`, `Dash0ReplayOptions`) sending `app.session_replay` records, with `Dash0ReplayBoundary`, `Dash0Mask`, optional masked screenshots and `Dash0.startReplay` / `stopReplay`.
- Add profiling (`Dash0Instrumentation.profiling`, `Dash0ProfilingOptions`): `app.long_task` events for main isolate stalls and ANRs with a watchdog isolate, runtime gauges and `Dash0.profile(name, body)`.
- `Dash0Client.emitEvent` and `sendLog` accept `rateLimited: false`.
- Add web vitals equivalents (`Dash0Instrumentation.vitals`, `Dash0VitalsOptions`): `app.start.duration`, `app.screen.ttff`, `app.interaction.latency`, `app.frame.*` metrics and per screen `app.vitals` events.
- Add rage click detection (`Dash0Instrumentation.rageClicks`, `Dash0RageClickOptions`) sending `app.rage_click`, and optional `app.dead_tap`.
- Add metrics: `Dash0.counter`, `upDownCounter`, `histogram` and `gauge`, exported to `/v1/metrics` with delta or cumulative temporality (`metricExportInterval`, `metricTemporality`).
- Add gzip compression of request bodies (`Dash0Options.compression`, default gzip, none on web).
- Add `Dash0HttpOverrides` and `Dash0.installHttpOverrides()` to instrument all `dart:io` HTTP clients, with `Dash0Instrumentation.httpOverrides` (opt-in) and `Dash0Instrumentation.metrics`.
- Record `http.client.request.duration` for `Dash0HttpClient` and `Dash0HttpOverrides`; no duplicate spans when both are used.
- Add `Dash0Options.enabled` to start disabled.
- Errors reported while disabled or sampled out no longer use up the error cap or dedupe window.

## 0.1.0

- Initial release modeled on dash0-sdk-web.
- `Dash0.init` with endpoints, sessions, sampling, ignore rules and propagators.
- Batched OTLP/HTTP JSON transport for traces and logs with rate limiting.
- Navigation (`Dash0NavigatorObserver`), HTTP (`Dash0HttpClient`), error and app lifecycle instrumentation.
- Custom events, spans, `identify`, signal attributes and `reportError`.
