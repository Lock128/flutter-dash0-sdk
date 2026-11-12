import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../client.dart';
import '../debug.dart';
import '../semantic_conventions.dart' as sc;

/// A detected burst of taps.
class RageClick {
  const RageClick(this.position, this.count);
  final Offset position;
  final int count;
}

/// Pure detection logic, independent of any binding.
///
/// Reports a [RageClick] once when [tapCount] taps within [radius] logical
/// pixels happened within [window]. Further taps of the same burst are
/// swallowed until the burst ended (a pause of [window] or a tap elsewhere).
class RageClickDetector {
  RageClickDetector({
    this.tapCount = 3,
    this.radius = 40,
    this.window = const Duration(seconds: 1),
  });

  final int tapCount;
  final double radius;
  final Duration window;

  final List<(Offset, DateTime)> _taps = [];
  bool _reported = false;

  /// Registers a tap. Returns a [RageClick] when the burst is detected.
  RageClick? onTap(Offset position, DateTime time) {
    if (_taps.isNotEmpty) {
      final (lastPos, lastTime) = _taps.last;
      final gap = time.difference(lastTime);
      if (gap > window || (position - lastPos).distance > radius) {
        _reported = false;
      }
    }
    _taps.removeWhere((t) =>
        time.difference(t.$2) > window || (position - t.$1).distance > radius);
    _taps.add((position, time));
    if (_reported || _taps.length < tapCount) return null;
    _reported = true;
    return RageClick(position, _taps.length);
  }

  void reset() {
    _taps.clear();
    _reported = false;
  }
}

/// Sends `app.rage_click` (and optionally `app.dead_tap`) events for pointer
/// down events. No text content is captured, only the render object type.
class RageClickInstrumentation {
  RageClickInstrumentation(this.client, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now,
        detector = RageClickDetector(
          tapCount: client.options.rageClicks.tapCount,
          radius: client.options.rageClicks.radius,
          window: client.options.rageClicks.window,
        );

  final Dash0Client client;
  final RageClickDetector detector;
  final DateTime Function() _clock;
  bool _installed = false;

  void install() {
    if (_installed) return;
    try {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
      _installed = true;
    } catch (e) {
      dash0Debug('Unable to install rage click detection', e);
    }
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    try {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
    } catch (_) {}
  }

  void _route(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    try {
      handleTap(event.position, hitTarget: () => _hit(event), time: _clock());
    } catch (e) {
      dash0Debug('Rage click handling failed', e);
    }
  }

  /// Processes a tap. [hitTarget] is evaluated lazily, only when an event is
  /// sent.
  void handleTap(
    Offset position, {
    required HitTestResult? Function() hitTarget,
    required DateTime time,
  }) {
    if (!client.isEnabled || !client.isSessionSampled) return;
    final result = detector.onTap(position, time);
    if (result != null) {
      client.emitEvent(
        sc.EventNames.rageClick,
        attributes: {
          sc.clickX: position.dx.round(),
          sc.clickY: position.dy.round(),
          sc.clickCount: result.count,
          sc.clickTarget: _targetName(hitTarget()),
        },
      );
    } else if (client.options.rageClicks.enableDeadTaps) {
      final hit = hitTarget();
      if (hit != null && !_isInteractive(hit)) {
        client.emitEvent(
          sc.EventNames.deadTap,
          attributes: {
            sc.clickX: position.dx.round(),
            sc.clickY: position.dy.round(),
            sc.clickTarget: _targetName(hit),
          },
        );
      }
    }
  }

  HitTestResult? _hit(PointerDownEvent event) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    return result;
  }

  static String? _targetName(HitTestResult? result) {
    if (result == null) return null;
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderObject) return target.runtimeType.toString();
    }
    return null;
  }

  static bool _isInteractive(HitTestResult result) {
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderEditable) return true;
      if (t is RenderSemanticsGestureHandler &&
          (t.onTap != null ||
              t.onLongPress != null ||
              t.onHorizontalDragUpdate != null ||
              t.onVerticalDragUpdate != null)) {
        return true;
      }
    }
    return false;
  }
}
