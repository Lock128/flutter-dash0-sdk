/// Flutter SDK for Dash0 real user monitoring, modeled on dash0-sdk-web.
library;

export 'src/batcher.dart' show Batcher;
export 'src/client.dart' show Dash0Client, dash0SdkVersion;
export 'src/dash0.dart' show Dash0;
export 'src/ids.dart' show generateSpanId, generateTraceId, isSessionSampledIn;
export 'src/instrumentation/http_client.dart' show Dash0HttpClient;
export 'src/instrumentation/http_overrides.dart' show Dash0HttpOverrides;
export 'src/instrumentation/http_common.dart' show Dash0HttpSpan;
export 'src/instrumentation/navigation.dart' show Dash0NavigatorObserver;
export 'src/instrumentation/sub_screens.dart'
    show Dash0TabObserver, subScreenPath, trackSubScreen;
export 'src/instrumentation/profiling.dart'
    show LongTaskMonitor, RuntimeSampler;
export 'src/instrumentation/rage_clicks.dart'
    show RageClick, RageClickDetector, RageClickInstrumentation;
export 'src/instrumentation/vitals.dart' show VitalsInstrumentation, percentile;
export 'src/metrics/instruments.dart'
    show
        Dash0Counter,
        Dash0Gauge,
        Dash0Histogram,
        Dash0Instrument,
        Dash0UpDownCounter,
        defaultHistogramBoundaries,
        maxSeriesPerInstrument;
export 'src/options.dart'
    show
        Dash0AggregationTemporality,
        Dash0Compression,
        Dash0Endpoint,
        Dash0Instrumentation,
        Dash0Options,
        Dash0ProfilingOptions,
        Dash0PageViewMeta,
        Dash0Propagator,
        Dash0PropagatorType,
        Dash0RageClickOptions,
        Dash0ReplayOptions,
        Dash0VitalsOptions,
        UrlScrubber;
export 'src/otlp.dart' show Attributes;
export 'src/propagation.dart' show formatTraceparent, parseTraceparent;
export 'src/replay/recorder.dart' show ReplayRecorder;
export 'src/replay/replay_widgets.dart' show Dash0Mask, Dash0ReplayBoundary;
export 'src/semantic_conventions.dart' show Dash0Severity, EventNames;
export 'src/session.dart'
    show Dash0KeyValueStore, MemoryStore, SharedPreferencesStore;
export 'src/span.dart' show Dash0Span;
export 'src/transport.dart' show Dash0Transport, HttpDash0Transport;
