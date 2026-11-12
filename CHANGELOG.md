# Changelog

## Unreleased

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
