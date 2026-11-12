import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../client.dart';
import '../debug.dart';
import '../ids.dart';
import '../semantic_conventions.dart' as sc;
import 'events.dart';
import 'replay_widgets.dart';

class _Pointer {
  _Pointer(this.position, this.time, this.target, this.scrollable, this.wall,
      this.slot, this.chunk);
  final Offset position;
  final Duration time;
  final String? target;
  final bool scrollable;

  /// Wall clock time of the pointer down.
  final DateTime wall;

  /// Position in the pending chunk at pointer down, and the chunk count then.
  /// Gesture callbacks (for example a tap that navigates) run before the
  /// recorder sees the pointer up, so the gesture is inserted at its start to
  /// keep the stream in causal order.
  final int slot;
  final int chunk;
}

/// Records the event-based session replay and sends it as
/// `app.session_replay` log records.
///
/// Privacy: the stream contains coordinates, render object types, route names
/// and markers. Text field values are never read. Screenshots are off by
/// default and blank all text.
class ReplayRecorder with WidgetsBindingObserver {
  ReplayRecorder(this.client, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Dash0Client client;
  final DateTime Function() _clock;

  /// Key of the `Dash0ReplayBoundary` that screenshots are taken from.
  GlobalKey? boundaryKey;

  bool? _override;
  final List<ReplayEvent> _events = [];
  DateTime? _chunkStart;
  String? _chunkSession;
  DateTime? _sessionStart;
  int _sequence = 0;
  int _chunksSent = 0;
  String? _decisionSession;
  bool _decision = false;
  Timer? _flushTimer;
  Timer? _screenshotTimer;
  bool _installed = false;
  bool _capturing = false;
  final Map<int, _Pointer> _pointers = {};
  Duration? _lastScroll;
  double? _viewW, _viewH;
  bool _keyboardVisible = false;
  EditableTextState? _field;
  int? _fieldTextHash;
  DateTime? _lastTextChange;

  /// Number of chunks sent in the current session.
  int get chunksSent => _chunksSent;

  /// Whether events are recorded right now.
  bool get isActive {
    if (!client.isEnabled || !client.isSessionSampled) return false;
    final forced = _override;
    if (forced != null) return forced;
    final sid = client.sessionId;
    if (_decisionSession != sid) {
      _decisionSession = sid;
      _decision =
          isSessionSampledIn(sid, client.options.sessionReplaySamplingRate);
      _sequence = 0;
      _chunksSent = 0;
      _sessionStart = null;
    }
    return _decision;
  }

  /// Records regardless of `sessionReplaySamplingRate` (the session still has
  /// to be sampled in).
  void start() => _override = true;

  /// Stops recording and sends what was recorded.
  void stop() {
    _override = false;
    flush();
  }

  void install() {
    if (_installed) return;
    try {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
      WidgetsBinding.instance.addObserver(this);
      FocusManager.instance.addListener(_onFocus);
      _installed = true;
      final interval = client.options.replay.screenshotInterval;
      if (interval != null) {
        _screenshotTimer =
            Timer.periodic(interval, (_) => unawaited(captureScreenshot()));
      }
    } catch (e) {
      dash0Debug('Unable to install session replay', e);
    }
  }

  /// Sends the pending chunk and removes all hooks.
  void uninstall() {
    flush();
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
    if (!_installed) return;
    _installed = false;
    _detachField();
    try {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
      WidgetsBinding.instance.removeObserver(this);
      FocusManager.instance.removeListener(_onFocus);
    } catch (_) {}
  }

  // -------------------------------------------------------------------
  // Chunking

  /// Adds an event. Public for tests and custom markers.
  void record(
    String type, [
    Map<String, Object?> data = const {},
    ({int slot, int chunk, DateTime time})? at,
  ]) {
    try {
      if (!isActive) return;
      final now = _clock();
      final o = client.options.replay;
      _sessionStart ??= now;
      if (_chunksSent >= o.maxChunks ||
          now.difference(_sessionStart!) > o.maxSessionDuration) {
        return;
      }
      if (_events.isEmpty) {
        _chunkStart = now;
        _chunkSession = client.sessionId;
      }
      if (at != null && at.chunk == _chunksSent && at.slot <= _events.length) {
        _events.insert(at.slot, ReplayEvent(type, at.time, data));
      } else {
        _events.add(ReplayEvent(type, now, data));
      }
      if (_events.length >= o.maxChunkEvents) {
        flush();
      } else {
        _flushTimer ??= Timer(o.flushInterval, flush);
      }
    } catch (e) {
      dash0Debug('Replay recording failed', e);
    }
  }

  /// Sends the pending events as one chunk.
  void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_events.isEmpty) return;
    try {
      final events = List<ReplayEvent>.of(_events);
      _events.clear();
      final sequence = _sequence++;
      _chunksSent++;
      final session = _chunkSession ?? client.sessionId;
      final chunk = buildReplayChunk(
        sessionId: session,
        sequence: sequence,
        start: _chunkStart ?? events.first.timestamp,
        end: events.last.timestamp,
        events: events,
        viewportWidth: _viewW,
        viewportHeight: _viewH,
      );
      client.emitEvent(
        sc.EventNames.sessionReplay,
        data: jsonEncode(chunk),
        attributes: {
          sc.sessionId: session,
          'app.replay.sequence': sequence,
          'app.replay.event_count': events.length,
        },
        rateLimited: false,
      );
    } catch (e) {
      dash0Debug('Replay flush failed', e);
    }
  }

  // -------------------------------------------------------------------
  // Hooks

  /// Called by the navigation instrumentation.
  void onNavigation(String screen, String? changeState) =>
      record(ReplayEventTypes.navigation, {
        'screen': screen,
        if (changeState != null) 'change': changeState,
      });

  /// Called by the client on lifecycle changes.
  void onLifecycle(AppLifecycleState state, {required bool background}) {
    record(ReplayEventTypes.lifecycle, {'state': state.name});
    if (background) flush();
  }

  @override
  void didChangeMetrics() {
    try {
      if (!isActive) return;
      final dispatcher = WidgetsBinding.instance.platformDispatcher;
      final view = dispatcher.implicitView ??
          (dispatcher.views.isEmpty ? null : dispatcher.views.first);
      if (view == null) return;
      final size = view.physicalSize / view.devicePixelRatio;
      if (size.width != _viewW || size.height != _viewH) {
        _viewW = size.width;
        _viewH = size.height;
        record(ReplayEventTypes.viewport, {
          'w': size.width.round(),
          'h': size.height.round(),
          'orientation': size.width > size.height ? 'landscape' : 'portrait',
          'dpr': view.devicePixelRatio,
        });
      }
      final keyboard = view.viewInsets.bottom > 0;
      if (keyboard != _keyboardVisible) {
        _keyboardVisible = keyboard;
        record(ReplayEventTypes.keyboard, {'visible': keyboard});
      }
    } catch (e) {
      dash0Debug('Replay metrics handling failed', e);
    }
  }

  void _route(PointerEvent event) {
    try {
      if (!isActive) {
        if (_pointers.isNotEmpty) _pointers.clear();
        return;
      }
      if (event is PointerDownEvent) {
        _viewSize(event.viewId);
        final (target, scrollable) = _hit(event);
        _pointers[event.pointer] = _Pointer(event.position, event.timeStamp,
            target, scrollable, _clock(), _events.length, _chunksSent);
      } else if (event is PointerUpEvent) {
        final p = _pointers.remove(event.pointer);
        if (p != null) _onPointerUp(event, p);
      } else if (event is PointerCancelEvent) {
        _pointers.remove(event.pointer);
      } else if (event is PointerScrollEvent) {
        final last = _lastScroll;
        if (last != null && event.timeStamp - last < _scrollThrottle) return;
        _lastScroll = event.timeStamp;
        final size = _viewSize(event.viewId);
        record(ReplayEventTypes.scroll, {
          'x': normalized(event.position.dx, size.width),
          'y': normalized(event.position.dy, size.height),
          'dx': event.scrollDelta.dx.round(),
          'dy': event.scrollDelta.dy.round(),
        });
      }
    } catch (e) {
      dash0Debug('Replay pointer handling failed', e);
    }
  }

  static const _scrollThrottle = Duration(milliseconds: 100);
  static const _longPress = Duration(milliseconds: 500);

  void _onPointerUp(PointerUpEvent up, _Pointer down) {
    final size = _viewSize(up.viewId);
    final duration = up.timeStamp - down.time;
    final distance = (up.position - down.position).distance;
    final base = <String, Object?>{
      'x': normalized(down.position.dx, size.width),
      'y': normalized(down.position.dy, size.height),
      if (down.target != null) 'target': down.target,
    };
    final at = (slot: down.slot, chunk: down.chunk, time: down.wall);
    if (distance > kTouchSlop) {
      record(
        down.scrollable ? ReplayEventTypes.scroll : ReplayEventTypes.drag,
        {
          ...base,
          'x2': normalized(up.position.dx, size.width),
          'y2': normalized(up.position.dy, size.height),
          'duration_ms': duration.inMilliseconds,
        },
        at,
      );
    } else if (duration >= _longPress) {
      record(ReplayEventTypes.longPress,
          {...base, 'duration_ms': duration.inMilliseconds}, at);
    } else {
      record(ReplayEventTypes.tap, base, at);
    }
  }

  Size _viewSize(int viewId) {
    final view = WidgetsBinding.instance.platformDispatcher.view(id: viewId);
    final size = view == null
        ? const Size(1, 1)
        : view.physicalSize / view.devicePixelRatio;
    if (_viewW == null && view != null) {
      _viewW = size.width;
      _viewH = size.height;
    }
    return size;
  }

  (String?, bool) _hit(PointerDownEvent event) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    String? name;
    var scrollable = false;
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderObject) {
        name ??= t.runtimeType.toString();
        if (t is RenderAbstractViewport) scrollable = true;
      }
    }
    return (name, scrollable);
  }

  // -------------------------------------------------------------------
  // Text fields: only markers, never values

  void _onFocus() {
    try {
      if (!isActive) return;
      final context = FocusManager.instance.primaryFocus?.context;
      EditableTextState? field;
      if (context is StatefulElement && context.state is EditableTextState) {
        field = context.state as EditableTextState;
      } else {
        field = context?.findAncestorStateOfType<EditableTextState>();
      }
      if (identical(field, _field)) return;
      if (_field != null) {
        _detachField();
        record(ReplayEventTypes.textBlur);
      }
      if (field != null) {
        _field = field;
        final controller = field.widget.controller;
        _fieldTextHash = controller.text.hashCode;
        controller.addListener(_onText);
        record(
            ReplayEventTypes.textFocus, {'obscured': field.widget.obscureText});
      }
    } catch (e) {
      dash0Debug('Replay focus handling failed', e);
    }
  }

  void _detachField() {
    try {
      _field?.widget.controller.removeListener(_onText);
    } catch (_) {}
    _field = null;
    _fieldTextHash = null;
  }

  void _onText() {
    try {
      final field = _field;
      if (field == null) return;
      final hash = field.widget.controller.text.hashCode;
      if (hash == _fieldTextHash) return;
      _fieldTextHash = hash;
      final now = _clock();
      final last = _lastTextChange;
      if (last != null && now.difference(last) < const Duration(seconds: 1)) {
        return;
      }
      _lastTextChange = now;
      record(ReplayEventTypes.textChange);
    } catch (e) {
      dash0Debug('Replay text handling failed', e);
    }
  }

  // -------------------------------------------------------------------
  // Screenshots

  /// Rectangles in the coordinate space of [boundary] that must be blanked:
  /// `Dash0Mask` subtrees and, with [maskAllText], all text.
  static List<Rect> maskRects(
    RenderRepaintBoundary boundary, {
    required bool maskAllText,
  }) {
    final rects = <Rect>[];
    void visit(RenderObject o) {
      final isMask = o is RenderDash0Mask;
      if (o is RenderBox &&
          (isMask ||
              (maskAllText && (o is RenderParagraph || o is RenderEditable))) &&
          o.hasSize) {
        try {
          final m = o.getTransformTo(boundary);
          rects.add(MatrixUtils.transformRect(m, Offset.zero & o.size));
        } catch (_) {}
        if (isMask) return;
      }
      o.visitChildren(visit);
    }

    boundary.visitChildren(visit);
    return rects;
  }

  /// Takes a downscaled PNG screenshot of the `Dash0ReplayBoundary` with
  /// sensitive regions blanked and records it.
  Future<void> captureScreenshot() async {
    if (_capturing || !isActive) return;
    final ro = boundaryKey?.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return;
    _capturing = true;
    ui.Image? image;
    ui.Image? masked;
    try {
      final o = client.options.replay;
      final scale = o.screenshotScale;
      final rects = maskRects(ro, maskAllText: o.maskAllText);
      image = await ro.toImage(pixelRatio: scale);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(image, Offset.zero, Paint());
      final paint = Paint()..color = const Color(0xFF000000);
      for (final r in rects) {
        canvas.drawRect(
          Rect.fromLTRB(
              r.left * scale, r.top * scale, r.right * scale, r.bottom * scale),
          paint,
        );
      }
      masked = await recorder.endRecording().toImage(image.width, image.height);
      final bytes = await masked.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      record(ReplayEventTypes.screenshot, {
        'format': 'png',
        'width': masked.width,
        'height': masked.height,
        'masked_regions': rects.length,
        'data': base64Encode(bytes.buffer.asUint8List()),
      });
      flush();
    } catch (e) {
      dash0Debug('Replay screenshot failed', e);
    } finally {
      image?.dispose();
      masked?.dispose();
      _capturing = false;
    }
  }
}
