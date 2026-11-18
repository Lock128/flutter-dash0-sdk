# Gap analysis: dash0-sdk-web vs flutter-dash0-sdk (0.8.0)

Written for flutter-dash0-sdk 0.8.0, implemented in 0.9.0 (see CHANGELOG.md). Web SDK source read: release 0.32.0 plus the files that changed up to the release 0.35.1 (console instrumentation 0.34.0, `storageNamespace` 0.33.0, string match lists 0.35.0). Source paths below are relative to `src/` of the dash0-sdk-web repository. The "Our status" column describes 0.8.0 and the "Decision" column what 0.9.0 does.

"Verified" means the behavior is read from web SDK source. "Guess" means it is inferred about what the Dash0 UI reads.

No Dash0 MCP server was available when this was written, so no live data was queried. Nothing here claims to be checked against a real dataset.

## Options and init

| Feature | Web SDK behavior (source) | Our status | Decision |
| --- | --- | --- | --- |
| serviceName/Namespace/Version, environment, deploymentName, deploymentId | resource attrs `service.*`, `deployment.environment.name`, `deployment.name`, `deployment.id`; env fallback from Vercel vars (`api/init.ts`) | have (`Dash0Options`, `client.dart buildResourceAttributes`) | Add compile-time fallback from `--dart-define` (`DASH0_ENVIRONMENT`, `DASH0_DEPLOYMENT_NAME`, `DASH0_DEPLOYMENT_ID`) when the option is null. Verified (analog of the env fallback). |
| vcs.* resource attributes | `vcs.provider.name`, `vcs.owner.name`, `vcs.repository.name`, `vcs.repository.url.full`, `vcs.ref.head.name`, `vcs.ref.head.revision`, `vcs.change.id`; `vcs` option, `disableVcsDetection`, URL parsing to provider/owner/repo (`api/vcs.ts`, `types/options.ts`) | missing | Implement `Dash0VcsAttributes`, `Dash0Options.vcs`, `disableVcsDetection`, detection from `--dart-define` `DASH0_VCS_*`, derivation of provider/owner/repo from the repository URL. Verified. |
| additionalSignalAttributes | merged into signal attrs (`api/init.ts`) | have | none |
| rejectSuspiciousServiceName | falls back to `location.hostname` | have (falls back to `unknown_service:flutter`) | none |
| enabledInstrumentations | names navigation, web-vitals, error, fetch, xhr, session-recording, frustration-signals, profiling (opt-in), console | have, except console | Add `Dash0Instrumentation.console`, opt-in (see console). |
| sessionSamplingRate | deterministic per session id | have | none |
| sessionInactivityTimeoutMillis, sessionTerminationTimeoutMillis, persistence | 3h / 6h, cap 24h, `d0_session` in localStorage, `id#start#last` (`api/session.ts`) | have, identical format (`session.dart`) | none |
| storageNamespace (0.33.0) | prefixes the storage key (`utils/storage-key.ts`) | missing | Implement `Dash0Options.storageNamespace`. Useful on Flutter web where several apps share one origin's localStorage. Verified. |
| ignoreUrls | strings (substring, trimmed, empty dropped) or RegExp, 0.35.0; data: urls, transport urls always ignored (`utils/ignore-rules.ts`) | partial: RegExp only | Widen to `List<Pattern>`, trim strings, drop empty. Verified. |
| ignoreErrorMessages | same string or RegExp | partial: RegExp only | Same widening. |
| propagators `match` | string or RegExp, 0.35.0 | partial: RegExp only | Same widening for `Dash0Propagator.match`. |
| propagateTraceHeadersCorsURLs (deprecated) | legacy alias | not applicable | We never had it. |
| Same-origin requests get traceparent automatically, default propagator `traceparent` with empty match | `instrumentations/http/utils.ts determinePropagatorTypes` | partial: only configured matches | On Flutter web, requests to `Uri.base` origin get `traceparent` plus all configured propagator types. Native has no page origin: not applicable there. Verified. |
| ignoreCrossOriginScriptErrors (default true) | drops "Script error." (`utils/ignore-rules.ts`) | missing | Implement for Flutter web (the message can occur through JS interop). Cheap. Verified. |
| ignoreBrowserExtensionErrors (default true) | drops errors whose url frames are all browser extension urls | missing | Implement (applies to Flutter web stacks). Verified. |
| wrapEventHandlers, wrapTimers | wrap addEventListener/setTimeout to catch cross-origin errors | not applicable | No such JS wrapping in Dart. `Dash0.runGuarded` and `PlatformDispatcher.onError` cover uncaught errors. |
| maxWaitForResourceTimingsMillis, maxToleranceForResourceTimingsMillis | wait for PerformanceResourceTiming | not applicable | No resource timing API in Dart. |
| headersToCapture | regex over header names, `http.request.header.*`, `http.response.header.*` | have | none |
| urlAttributeScrubber | scrubs a record of url attributes, rebuilds `url.full` if parts changed (`attributes/url.ts`) | partial: our `UrlScrubber` scrubs the url string | Keep our string scrubber (documented difference). No change. |
| pageViewInstrumentation.generateMetadata, trackVirtualPageViews, includeParts | custom title/attrs per url; history API tracking | have (`generatePageViewMetadata`) | none, history API is not applicable |
| sessionRecording, frustrationSignals, profiling settings | rrweb, rage click thresholds, JS self-profiling | have (ports) | none |
| enableTransportCompression | gzip, experimental | have (default gzip) | none |
| consoleLogs (0.34.0) | levels, ignoreMessages, maxMessageLength 4096 | missing | See console. |
| endpoint(s), dataset header | `Dash0-Dataset` header, multiple endpoints | have | none |

## Public API

| Feature | Web SDK behavior (source) | Our status | Decision |
| --- | --- | --- | --- |
| identify(id, {name, fullName, email, hash, roles}) | `user.*` signal attrs (`api/identify.ts`) | have | none |
| addSignalAttribute / removeSignalAttribute | `api/attributes.ts` | have | none |
| sendEvent(name, {title, timestamp, data, attributes, severity}) | rejects reserved names (`api/events.ts`) | have | none |
| reportError(error, {componentStack, attributes}) | `api/report-error.ts` | have | none |
| terminateSession | removes stored session | have | none |
| startView(name, {url, attributes}) | manual `browser.page_view`, type 1, no change_state, no generateMetadata, url override (`api/start-view.ts`) | partial: `Dash0.trackScreen(name, {attributes})` has no url override | Add `Dash0.startView(name, {url, attributes})` as the web-named entry point with the url override for `page.url.*`. Verified. |
| setParentTraceContext(traceparent) (0.31.0) | spans without a parent join this trace, parentSpanId set (`api/parent-trace-context.ts`, `utils/otel/span.ts`) | missing | Implement `Dash0.setParentTraceContext(String?)`. Verified. |
| startSessionRecording / session-recording API | `api/session-recording.ts` | have (`startReplay`, `stopReplay`) | none |
| debug / log level | `api/debug.ts` | have (`Dash0Options.debug`) | none |
| script-tag command queue (`dash0("init", ...)`) | `entrypoint/script.ts` | not applicable | No script tags in Flutter. |

## Telemetry

| Feature | Web SDK behavior (source) | Our status | Decision |
| --- | --- | --- | --- |
| browser.page_view | body title, referrer, type, change_state; attrs `dash0.web.event.id`, `page.url.*` | have | none |
| browser.navigation_timing | PerformanceNavigationTiming fields (`navigation/page-load.ts`) | not applicable | Browser document load timings do not exist in Flutter. Equivalent: `app.start.duration`, time to first frame in `app.vitals`. |
| Page-load trace context on logs (meta traceparent, Server-Timing) | `utils/otel/trace-context.ts` | not applicable | No HTML document. `setParentTraceContext` covers the spans. |
| browser.web_vital | body `name`, `value`, `delta` only. No element, rating or navigation type (`web-vitals.ts`, verified) | have (LCP, INP approximations in `vitals.dart`, same body shape) | none. Extra vital fields such as element, rating or LCP url are not sent by the web SDK. |
| browser.error | `exception.message` (cut to 300, urls scrubbed), `exception.type`, `exception.stacktrace` (30 lines), `exception.component_stack` (2048), custom attrs, 100 per page, dedupe, severity ERROR (`errors/unhandled-error.ts`) | partial: no message cut at 300, component stack not cut or scrubbed | Cut message to 300 and component stack to 2048 with url scrubbing. Verified. |
| browser.console (0.34.0) | wraps console, event `browser.console`, attrs `dash0.web.console.method`, `exception.*` for Error args, `code.stacktrace` for trace, body is the message (max 4096), rate limits 5000/10 min + 200/10 s before formatting, 1000/10 min + 50/10 s sending, own budget, ignoreMessages (`instrumentations/console/index.ts`) | missing | Flutter analog: capture `debugPrint` and zone `print` (via `Dash0.runGuarded`). Opt-in `Dash0Instrumentation.console`, `Dash0ConsoleOptions`. Verified for event shape, guess for Dash0 UI display. |
| browser.rage_click | body click_count, duration_millis, selector, x, y, text; recording id | have (port) | none |
| Dead clicks | not in web SDK | have (opt-in `enableDeadTaps`) | none |
| Page visibility, time on page, unload events | none emitted. Only `onLastChance` flushes buffers on pagehide/visibilitychange (`utils/on-last-chance.ts`) | have equivalent: flush on paused/hidden/detached | A `page.visibility` event does not exist in the web SDK. Not added. |
| Telemetry about itself | `browser.profiling_unavailable` when JS Self-Profiling is missing; debug logging only | not applicable | Our profiling is not JS Self-Profiling. |
| HTTP span (fetch/xhr) | name `HTTP <METHOD>`, `http.request.method`, `_OTHER` + `http.request.method_original`, `http.response.status_code` as a string, `url.*`, `error.type`, `http.response.body.size`, headers, network events from resource timing (`http/fetch.ts`, `http/utils.ts`) | have, with these differences: status code is int, no network timing events (not applicable) | Keep int status code (guess: Dash0 accepts both). Document. |
| `dash0.web.request.cancelled` | set on aborted requests, no error status, no error.type (`http/utils.ts endSpanOnAbort`) | missing | Set it for aborted requests (`RequestAbortedException` of package:http 1.5+, by type name) without error status. Verified. |
| url.query / url.fragment value | no leading `?` / `#` (`attributes/url.ts`) | wrong: we send `?b=1` and `#frag` | Fix: strip the prefix. Verified, bug fix. Existing test `test/http_client_test.dart:57` asserts the old value and must change. |
| Common signal attrs | `page.load.id`, `session.id`, `browser.tab.id`, `browser.window.*`, `network.connection.subtype`, `user_agent.original` | have (web only) | none |
| Numbers on the wire | the web SDK sends numbers as `doubleValue` | partial: we send ints as `intValue` | Keep. OTLP allows both. Guess: the UI does not care. |
| Rate limiting | 4096/10 min and 128/10 s shared (`transport/index.ts`) | have (`rate_limiter.dart`) | none |
| Transport | `Authorization: Bearer`, `Dash0-Dataset`, gzip, keepalive limits | have (keepalive is browser only) | none |

## Dash0 UI fields (Websites, Sessions)

| UI element | Field the SDK sends | Status |
| --- | --- | --- |
| Websites filter Domain | `page.url.domain` (we set it to the service name), `url.domain` on HTTP spans | have (guess that this is the field read) |
| Path | `page.url.path` | have |
| Environment | resource `deployment.environment.name` | have (`Dash0Options.environment`) |
| Deployment Name / ID | resource `deployment.name`, `deployment.id` | have via options, add `--dart-define` fallback |
| Sessions System / Browser | `user_agent.original` signal attribute (web SDK sets it from `navigator.userAgent`, `api/init.ts initializeSignalAttributes`). Dash0 most likely parses it. | have since 0.8.0. Not verifiable without the Dash0 MCP server. If the columns stay empty, check that `user_agent.original` is present on the records of the session and that `collectUserAgent` is true. |
| Sessions Page views / Errors / Total duration | derived from `browser.page_view`, `browser.error` and session timestamps (guess) | have |

## Not applicable to Flutter (reasons)

`wrapEventHandlers`, `wrapTimers`, `ignoreCrossOriginScriptErrors` / `ignoreBrowserExtensionErrors` on native (kept for Flutter web only), `maxWait*ResourceTimings*`, `browser.navigation_timing`, page-load trace context from meta tag and Server-Timing, XHR instrumentation, script-tag entry point, JS Self-Profiling unavailable event, history API virtual page views, resource timing network events on spans.

## Other findings

- `publish_to: none` in `pubspec.yaml` blocks `dart pub publish`. To publish to pub.dev, remove that line, and make sure `repository`, a `LICENSE`, `CHANGELOG.md` and `dart pub publish --dry-run` pass. Not changed here. It is the owner's decision whether the package should be public.
- nexus-share: no SDK option has to be enabled there. To fill the new fields, the build workflows can pass `--dart-define=DASH0_DEPLOYMENT_ID=<run id>`, `DASH0_DEPLOYMENT_NAME`, `DASH0_VCS_REF_HEAD_REVISION=${{ github.sha }}`, `DASH0_VCS_REF_HEAD_NAME`, `DASH0_VCS_REPOSITORY_URL_FULL` next to the existing `--dart-define-from-file=otlp_config.json`. That needs the SDK pin bumped to the new tag.
