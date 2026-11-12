import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../client.dart';
import '../dash0.dart';
import 'recorder.dart';

/// Marks the part of the UI that is captured by replay screenshots. Wrap the
/// app (or a screen) in it. Screenshots are only taken when
/// `Dash0ReplayOptions.screenshotInterval` is set and the session records a
/// replay.
class Dash0ReplayBoundary extends StatefulWidget {
  const Dash0ReplayBoundary({super.key, required this.child, this.client});

  final Widget child;

  /// Defaults to the client created by `Dash0.init`.
  final Dash0Client? client;

  @override
  State<Dash0ReplayBoundary> createState() => _Dash0ReplayBoundaryState();
}

class _Dash0ReplayBoundaryState extends State<Dash0ReplayBoundary> {
  final GlobalKey _key = GlobalKey(debugLabel: 'Dash0ReplayBoundary');
  ReplayRecorder? _recorder;

  @override
  void initState() {
    super.initState();
    _recorder = (widget.client ?? Dash0.client)?.replay;
    _recorder?.boundaryKey = _key;
  }

  @override
  void dispose() {
    final r = _recorder;
    if (r != null && r.boundaryKey == _key) r.boundaryKey = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        key: _key,
        child: widget.child,
      );
}

/// Blanks its subtree in replay screenshots. The widget itself is shown
/// normally on screen. Use it for anything sensitive that is not text, for
/// example photos, QR codes or charts. Text is masked automatically with
/// `Dash0ReplayOptions.maskAllText`.
class Dash0Mask extends SingleChildRenderObjectWidget {
  const Dash0Mask({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => RenderDash0Mask();
}

/// Render object of [Dash0Mask], found by the screenshot capture.
class RenderDash0Mask extends RenderProxyBox {
  RenderDash0Mask([super.child]);
}
