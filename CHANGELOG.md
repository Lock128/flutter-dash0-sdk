# Changelog

## 0.9.0

Closes the gaps to dash0-sdk-web 0.35.1 that make sense on Flutter. See `docs/web-sdk-gap-analysis.md`.

Resource and options (read from the web SDK source):

- Add `vcs.*` resource attributes: `Dash0VcsAttributes`, `Dash0Options.vcs`, `Dash0Options.disableVcsDetection` and detection from `--dart-define` values `DASH0_VCS_PROVIDER_NAME`, `DASH0_VCS_OWNER_NAME`, `DASH0_VCS_REPOSITORY_NAME`, `DASH0_VCS_REPOSITORY_URL_FULL`, `DASH0_VCS_REF_HEAD_NAME`, `DASH0_VCS_REF_HEAD_REVISION` and `DASH0_VCS_CHANGE_ID`. Provider, owner and repository are derived from the repository URL.
- Fall back to `--dart-define` values `DASH0_ENVIRONMENT`, `DASH0_DEPLOYMENT_NAME` and `DASH0_DEPLOYMENT_ID` when `environment`, `deploymentName` or `deploymentId` are null.
- Add `Dash0Options.storageNamespace`, a prefix for persisted keys (`<namespace>:d0_session`).
- `ignoreUrls`, `ignoreErrorMessages` and `Dash0Propagator.match` accept `List<Pattern>`, so plain strings work next to `RegExp`. Strings are trimmed and empty ones dropped.
- Fix: `url.query` and `url.fragment` no longer start with `?` and `#`.

New behavior (read from the web SDK source, Dash0 UI display is a guess):

- Add the opt-in `Dash0Instrumentation.console` with `Dash0ConsoleOptions` (`ignoreMessages`, `maxMessageLength` 4096, `captureDebugPrint`, `capturePrint`). It sends `browser.console` events (`app.console` with `legacyAppNames`) with `dash0.web.console.method` for `debugPrint`, for `print` inside `Dash0.runGuarded` and for the new `Dash0.log(level, message, {error, stackTrace})`. Messages are scrubbed, cut with `…`, rate limited before formatting (5000 per 10 minutes, 200 per 10 seconds) and before sending (1000 per 10 minutes, 50 per 10 seconds, separate from the shared budget). The SDK's own debug output is not captured. Export `Dash0ConsoleLevel`.
- Add `Dash0.setParentTraceContext(traceparent)`: spans without a parent join the given trace and get its span id as `parentSpanId`. Null clears it, invalid values are ignored.
- Add `Dash0.startView(name, {url, attributes})`: a virtual `browser.page_view` without `change_state` and without changing the current screen. The `url` override feeds `page.url.*`. `trackScreen` stays for compatibility.
- Errors: `exception.message` is cut to 300 characters and `exception.component_stack` to 2048, both after URL scrubbing.
- Add `Dash0Options.ignoreCrossOriginScriptErrors` and `ignoreBrowserExtensionErrors` (both default true), which drop `Script error.` and errors whose URL frames all belong to browser extensions. Only Flutter web stacks can match.
- Aborted requests (`RequestAbortedException` of `package:http` 1.5) get `dash0.web.request.cancelled=true` and no error status or `error.type`.
- Flutter web: requests to the page origin always get `traceparent` plus every configured propagator type, like the web SDK. Native apps are unchanged.

Docs:

- README: new options, dart-define examples, console capture, `startView`, `setParentTraceContext` and the list of web SDK features that do not apply to Flutter.
- Add `docs/web-sdk-gap-analysis.md`.
- No Dash0 MCP server was available, so nothing here was checked against a live dataset.
- `publish_to: none` is unchanged.

## 0.8.0

- Web: add the attributes dash0-sdk-web puts on every signal: `page.load.id`, `browser.tab.id`, `browser.window.width`, `browser.window.height` (read when the signal is recorded) and `network.connection.subtype` (`navigator.connection.effectiveType`, when the browser has it). Events, spans and logs only, never metrics. Not sent on native.
- Web: read `navigator.userAgent` independently of `navigator.userAgentData`, so a failing client hints read no longer drops `user_agent.original`. The probe reads through `@JS` getters and a testable `NavigatorSource`.
- Web: send `user_agent.original: undefined` when the browser has no user agent, like dash0-sdk-web does.
- Add `Dash0Options.userAgentOnResource` (default false): also put `user_agent.original` on the resource of logs and spans (web, never metrics). Diagnostic hedge.
- Add `Dash0Options.syntheticUserAgent` (default false): native apps send `<service>/<version> (<os> <os.version>; <device>)` as `user_agent.original` plus `app.client.user_agent.synthetic=true`. A hack, never used on the web.
- `debug: true` logs the client type and whether `user_agent.original` is attached, with its length.
- Export `ViewportProbe`.

## 0.7.0

- Name GraphQL operations. Spans get `graphql.operation.name` and `graphql.operation.type` and are called `HTTP POST <OperationName>`. `Dash0HttpClient` does this for JSON POST requests of `http.Request`.
- Detect GraphQL errors in HTTP 200 responses: the span gets error status and `error.type` (`errorType`, `extensions.code` or `GraphQLError`). Error messages, query text and variables are never recorded.
- Add the histogram `graphql.client.operation.duration` (seconds). Distinct operation names are capped at 100, further names are `_OTHER`.
- Add `Dash0GraphQLOperation`, `Dash0GraphQLErrors`, `Dash0GraphQL.inspectRequestBody`, `Dash0GraphQL.inspectResponse`, `Dash0HttpSpan.setGraphQLOperation` and `Dash0HttpSpan.setGraphQLErrors` for HTTP stacks that are not instrumented, such as AWS Amplify.
- Add `Dash0Span.updateName`.
- README: GraphQL section and a checklist to verify signals in Dash0.

## 0.6.0

- Tell clients apart. Every event, span and log carries `app.client.type` (`web-desktop`, `web-mobile`, `ios`, `android`, `macos`, `windows`, `linux`, `fuchsia`). The resource, which also covers metrics, carries `app.client.type`, `app.runtime` (`flutter-web` or `flutter-native`) and `os.name`.
- On the web the resource also has `browser.mobile`, `browser.platform` and, where the browser has `navigator.userAgentData`, `browser.brands`. Events, spans and logs have `user_agent.original` like dash0-sdk-web. Metrics never get the raw user agent.
- Mobile web is detected with `navigator.userAgentData.mobile`, then the user agent (`Android|iPhone|iPad|iPod|Mobile`), and iPadOS Safari in desktop mode by its touch points. Tablets are `web-mobile`.
- Add `Dash0Options.collectUserAgent` (default `true`) to leave out `user_agent.original`.
- Export `Dash0ClientInfo`, `Dash0ClientType`, `WebProbe` and `classifyClient`, and expose `Dash0Client.clientInfo`.
- `os.type` is unchanged (`web` or the Flutter platform name).

## 0.5.0

- Add `Dash0TabObserver`, a widget that sends a page view (`/admin/failed-payments`) whenever the selected tab of a tab controller settles (any controller class, passed as `controller`, `index` and `isChanging`). Taps, `animateTo` and swipes are reported, mid animation changes and unchanged indexes are not. The first tab is reported as the parent route by default, because the route's own page view already covers it.
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
