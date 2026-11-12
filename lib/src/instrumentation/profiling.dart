import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../client.dart';
import '../debug.dart';
import '../metrics/instruments.dart';
import '../options.dart';
import '../otlp.dart';
import '../semantic_conventions.dart' as sc;
import '../span.dart';
import 'process_info.dart';
import 'watchdog.dart';

/// Detects stalls of the main isolate and reports them as `app.long_task`
/// events.
///
/// A periodic heartbeat timer runs on the main isolate. If it fires later than
/// expected by at least the long task threshold, the main isolate was busy for
/// that long. Stalls reaching the ANR threshold are flagged with
/// `app.long_task.anr`. Where isolates exist a watchdog isolate observes the
/// same heartbeat and reports ANRs too, which keeps working if the heartbeat
/// timer itself is starved.
class LongTaskMonitor {
  LongTaskMonitor(this.client, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Dash0Client client;
  final DateTime Function() _clock;
  Timer? _timer;
  DateTime? _last;
  StallWatchdog? _watchdog;
  bool _installed = false;
  int _reportedSince = -1;
  Dash0Histogram? _duration;

  Dash0ProfilingOptions get _o => client.options.profiling;

  /// Starts the heartbeat. [startTimer] false is for tests that call [tick]
  /// themselves.
  void install({bool startTimer = true}) {
    if (_installed) return;
    _installed = true;
    _last = _clock();
    if (startTimer) {
      _timer = Timer.periodic(_o.heartbeatInterval, (_) => tick());
      if (_o.useWatchdogIsolate && !kIsWeb) unawaited(_startWatchdog());
    }
  }

  Future<void> _startWatchdog() async {
    try {
      final w = await startStallWatchdog(
        anrThreshold: _o.anrThreshold,
        onStall: (since, stall) => _report(since, stall, 'watchdog'),
      );
      if (!_installed) {
        w?.stop();
        return;
      }
      _watchdog = w;
      w?.beat(_clock().microsecondsSinceEpoch);
    } catch (e) {
      dash0Debug('Unable to start the stall watchdog', e);
    }
  }

  /// Stops the heartbeat and the watchdog isolate.
  void uninstall() {
    _installed = false;
    _timer?.cancel();
    _timer = null;
    _watchdog?.stop();
    _watchdog = null;
  }

  /// Suspends monitoring, for example while the app is in the background
  /// where timers do not run.
  void pause() {
    _last = null;
    _watchdog?.beat(null);
  }

  /// Continues after [pause].
  void resume() {
    if (!_installed) return;
    final now = _clock();
    _last = now;
    _watchdog?.beat(now.microsecondsSinceEpoch);
  }

  /// One heartbeat. Exposed so that tests can drive time.
  void tick([DateTime? at]) {
    try {
      final now = at ?? _clock();
      final last = _last;
      _last = now;
      _watchdog?.beat(now.microsecondsSinceEpoch);
      if (last == null) return;
      final stall = now.difference(last) - _o.heartbeatInterval;
      if (stall >= _o.longTaskThreshold) {
        _report(last.microsecondsSinceEpoch, stall.inMicroseconds, 'heartbeat');
      }
    } catch (e) {
      dash0Debug('Long task detection failed', e);
    }
  }

  void _report(int sinceMicros, int stallMicros, String source) {
    try {
      if (sinceMicros <= _reportedSince) return;
      _reportedSince = sinceMicros;
      if (!client.isEnabled || !client.isSessionSampled) return;
      final ms = stallMicros / 1000;
      client.emitEvent(
        sc.EventNames.longTask,
        timestamp: DateTime.fromMicrosecondsSinceEpoch(sinceMicros),
        attributes: {
          sc.longTaskDurationMs: ms,
          sc.longTaskAnr: stallMicros >= _o.anrThreshold.inMicroseconds,
          sc.longTaskSource: source,
        },
      );
      if (client.options.isEnabled(Dash0Instrumentation.metrics)) {
        (_duration ??= client.histogram(sc.metricLongTaskDuration,
                unit: 'ms',
                description: 'Main isolate stalls above the threshold.'))
            .record(ms, attributes: {
          if (client.currentScreen != null)
            sc.appScreenName: client.currentScreen,
        });
      }
    } catch (e) {
      dash0Debug('Long task reporting failed', e);
    }
  }
}

/// Periodically records process memory, image cache and frame totals as gauge
/// metrics.
class RuntimeSampler {
  RuntimeSampler(this.client);

  final Dash0Client client;
  Timer? _timer;

  void install({bool startTimer = true}) {
    final interval = client.options.profiling.runtimeSampleInterval;
    if (!startTimer || interval == null || _timer != null) return;
    _timer = Timer.periodic(interval, (_) => sample());
  }

  void uninstall() {
    _timer?.cancel();
    _timer = null;
  }

  /// Records one sample.
  void sample() {
    try {
      if (!client.isEnabled || !client.isSessionSampled) return;
      final rss = currentRssBytes();
      if (rss != null) {
        client
            .gauge(sc.metricRuntimeRss,
                unit: 'By', description: 'Resident set size of the process.')
            .record(rss);
      }
      final cache = _imageCache();
      if (cache != null) {
        client
            .gauge(sc.metricImageCacheSize,
                unit: 'By', description: 'Bytes held by the image cache.')
            .record(cache.currentSizeBytes);
        client
            .gauge(sc.metricImageCacheCount,
                unit: '{image}', description: 'Images in the image cache.')
            .record(cache.currentSize);
        client
            .gauge(sc.metricImageCacheLive,
                unit: '{image}', description: 'Live images.')
            .record(cache.liveImageCount);
      }
      final v = client.vitals;
      if (v != null) {
        client
            .gauge(sc.metricRuntimeFrames,
                unit: '{frame}', description: 'Frames since SDK start.')
            .record(v.totalFrames);
        client
            .gauge(sc.metricRuntimeFramesSlow,
                unit: '{frame}', description: 'Slow frames since SDK start.')
            .record(v.totalSlowFrames);
        client
            .gauge(sc.metricRuntimeFramesFrozen,
                unit: '{frame}', description: 'Frozen frames since SDK start.')
            .record(v.totalFrozenFrames);
      }
    } catch (e) {
      dash0Debug('Runtime sampling failed', e);
    }
  }

  static ImageCache? _imageCache() {
    try {
      return PaintingBinding.instance.imageCache;
    } catch (_) {
      return null;
    }
  }
}

/// Runs [body] in a span named [name] and attaches frame, memory and timing
/// attributes measured while it ran. See `Dash0.profile`.
Future<T> runProfiled<T>(
  Dash0Client client,
  String name,
  FutureOr<T> Function(Dash0Span span) body, {
  Attributes? attributes,
}) async {
  final span = client.startSpan(name, attributes: attributes);
  final v = client.vitals;
  final frames = v?.totalFrames ?? 0;
  final slow = v?.totalSlowFrames ?? 0;
  final frozen = v?.totalFrozenFrames ?? 0;
  final rssStart = currentRssBytes();
  final watch = Stopwatch()..start();
  if (kDebugMode) {
    span.addEvent('profile.stack.start', attributes: {
      'profile.stack': StackTrace.current.toString(),
    });
  }
  try {
    return await span.runAsCurrent(() => body(span));
  } catch (e, st) {
    span.recordException(e, st);
    rethrow;
  } finally {
    watch.stop();
    try {
      if (kDebugMode) {
        span.addEvent('profile.stack.end', attributes: {
          'profile.stack': StackTrace.current.toString(),
        });
      }
      final rssEnd = currentRssBytes();
      final v2 = client.vitals;
      span.setAttributes({
        'profile.duration_ms': watch.elapsedMicroseconds / 1000,
        'profile.frames': (v2?.totalFrames ?? 0) - frames,
        'profile.frames.slow': (v2?.totalSlowFrames ?? 0) - slow,
        'profile.frames.frozen': (v2?.totalFrozenFrames ?? 0) - frozen,
        if (rssStart != null && rssEnd != null) ...{
          'profile.rss.start': rssStart,
          'profile.rss.end': rssEnd,
          'profile.rss.delta': rssEnd - rssStart,
        },
      });
    } catch (e) {
      dash0Debug('Profile attributes failed', e);
    }
    span.end();
  }
}
