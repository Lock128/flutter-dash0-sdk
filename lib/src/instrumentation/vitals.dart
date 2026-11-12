import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';

import '../client.dart';
import '../debug.dart';
import '../metrics/instruments.dart';
import '../options.dart';
import '../semantic_conventions.dart' as sc;

/// Flutter equivalents of web vitals, see the README for the mapping.
class VitalsInstrumentation {
  VitalsInstrumentation(this.client, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now {
    _startedAt = _clock();
    _screenStartedAt = _startedAt;
  }

  final Dash0Client client;
  final DateTime Function() _clock;
  late DateTime _startedAt;
  late DateTime _screenStartedAt;
  bool _installed = false;
  bool _appStartRecorded = false;

  // Per screen aggregation.
  int _frames = 0;
  int _slow = 0;
  int _frozen = 0;
  int _totalFrames = 0;
  int _totalSlow = 0;
  int _totalFrozen = 0;
  double? _ttffMs;
  final List<double> _interactions = [];
  static const _maxInteractions = 1000;

  DateTime? _pendingInteraction;

  Dash0Histogram? _appStart, _ttff, _latency, _build, _raster;
  Dash0Counter? _slowCounter, _frozenCounter;

  /// Frames processed since the SDK started, not reset per screen.
  int get totalFrames => _totalFrames;

  /// Slow frames since the SDK started.
  int get totalSlowFrames => _totalSlow;

  /// Frozen frames since the SDK started.
  int get totalFrozenFrames => _totalFrozen;

  bool get _metricsOn => client.options.isEnabled(Dash0Instrumentation.metrics);

  void install() {
    if (_installed) return;
    try {
      SchedulerBinding.instance.addTimingsCallback(onTimings);
      GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
      _installed = true;
    } catch (e) {
      dash0Debug('Unable to install vitals', e);
    }
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    try {
      SchedulerBinding.instance.removeTimingsCallback(onTimings);
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
    } catch (_) {}
  }

  void _route(PointerEvent event) {
    if (event is PointerUpEvent) markInteraction();
  }

  /// Starts measuring the latency of an interaction up to the next frame.
  /// Called for every pointer up, may be called for custom gestures.
  void markInteraction() {
    if (!client.isEnabled || !client.isSessionSampled) return;
    _pendingInteraction ??= _clock();
  }

  /// Handler of `SchedulerBinding.addTimingsCallback`.
  void onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      processFrame(
        build: t.buildDuration,
        raster: t.rasterDuration,
        total: t.totalSpan,
      );
    }
  }

  /// Processes one frame. Exposed so that tests can feed synthetic values.
  void processFrame({
    required Duration build,
    required Duration raster,
    required Duration total,
  }) {
    try {
      final now = _clock();
      if (!client.isEnabled || !client.isSessionSampled) {
        // Frames that are not observed: the start up was not measured, so
        // do not report time spent while disabled (for example waiting for
        // a feature flag) as app start or time to first frame.
        _appStartRecorded = true;
        _screenStartedAt = now;
        return;
      }
      final screen = client.currentScreen;
      final attrs = screen == null ? null : {sc.appScreenName: screen};
      _frames++;
      final o = client.options.vitals;
      final slow = total > o.slowFrameThreshold;
      final frozen = total > o.frozenFrameThreshold;
      if (slow) _slow++;
      if (frozen) _frozen++;
      _totalFrames++;
      if (slow) _totalSlow++;
      if (frozen) _totalFrozen++;

      final firstFrameOfScreen = _ttffMs == null;
      final ttff =
          _ttffMs ??= now.difference(_screenStartedAt).inMicroseconds / 1000;
      final pending = _pendingInteraction;
      double? latency;
      if (pending != null) {
        _pendingInteraction = null;
        latency = now.difference(pending).inMicroseconds / 1000;
        if (_interactions.length < _maxInteractions) _interactions.add(latency);
      }

      if (!_metricsOn) return;
      if (!_appStartRecorded) {
        _appStartRecorded = true;
        (_appStart ??= client.histogram(sc.metricAppStartDuration,
                unit: 'ms',
                description: 'Time from SDK start to the first frame.'))
            .record(now.difference(_startedAt).inMicroseconds / 1000);
      }
      if (firstFrameOfScreen) {
        (_ttff ??= client.histogram(sc.metricScreenTtff,
                unit: 'ms',
                description: 'Time from a screen change to its first frame.'))
            .record(ttff, attributes: attrs);
      }
      (_build ??= client.histogram(sc.metricFrameBuildDuration,
              unit: 'ms', description: 'Frame build (UI thread) duration.'))
          .record(build.inMicroseconds / 1000, attributes: attrs);
      (_raster ??= client.histogram(sc.metricFrameRasterDuration,
              unit: 'ms', description: 'Frame raster duration.'))
          .record(raster.inMicroseconds / 1000, attributes: attrs);
      if (slow) {
        (_slowCounter ??= client.counter(sc.metricFrameSlow,
                unit: '{frame}', description: 'Frames slower than the budget.'))
            .add(1, attributes: attrs);
      }
      if (frozen) {
        (_frozenCounter ??= client.counter(sc.metricFrameFrozen,
                unit: '{frame}', description: 'Frames slower than 700 ms.'))
            .add(1, attributes: attrs);
      }
      if (latency != null) {
        (_latency ??= client.histogram(sc.metricInteractionLatency,
                unit: 'ms',
                description: 'Time from pointer up to the next frame.'))
            .record(latency, attributes: attrs);
      }
    } catch (e) {
      dash0Debug('Vitals frame handling failed', e);
    }
  }

  /// Called by the navigation instrumentation before the current screen
  /// changes. Sends `app.vitals` for the screen that is left.
  void onScreenChange() => flushScreen('screen_change');

  /// Sends `app.vitals` for the current screen and starts over.
  void flushScreen(String trigger) {
    try {
      final hadData = _frames > 0 || _interactions.isNotEmpty;
      if (hadData &&
          client.options.isEnabled(Dash0Instrumentation.vitals) &&
          client.isEnabled &&
          client.isSessionSampled) {
        final ttff = _ttffMs;
        client.emitEvent(
          sc.EventNames.vitals,
          attributes: {
            sc.vitalsTrigger: trigger,
            if (ttff != null) sc.vitalsTtffMs: _round(ttff),
            sc.vitalsFramesTotal: _frames,
            sc.vitalsFramesSlow: _slow,
            sc.vitalsFramesFrozen: _frozen,
            sc.vitalsInteractions: _interactions.length,
            if (_interactions.isNotEmpty)
              sc.vitalsInteractionP98Ms: _round(percentile(_interactions, 98)),
          },
        );
      }
    } catch (e) {
      dash0Debug('Vitals flush failed', e);
    }
    _frames = 0;
    _slow = 0;
    _frozen = 0;
    _ttffMs = null;
    _interactions.clear();
    _screenStartedAt = _clock();
  }

  static double _round(double v) => (v * 100).round() / 100;
}

/// Nearest rank percentile of [values] (not modified).
double percentile(List<double> values, num p) {
  final sorted = [...values]..sort();
  final rank = (p / 100 * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}
