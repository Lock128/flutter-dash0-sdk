# Changelog

## 0.2.0

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
