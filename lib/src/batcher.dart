import 'dart:async';

/// Collects items and hands them to [sink] in batches, mirroring
/// `batcher.ts`. A batch is sent when [maxQueueSize] items are queued or
/// [scheduleDelay] has passed since the first queued item.
class Batcher<T> {
  Batcher(
    this._sink, {
    this.maxQueueSize = 15,
    this.scheduleDelay = const Duration(seconds: 1),
  });

  final void Function(List<T> items) _sink;
  final int maxQueueSize;
  final Duration scheduleDelay;

  final List<T> _queue = [];
  Timer? _timer;

  /// When true items are sent immediately. Used while the app is in the
  /// background, where there is no guarantee that a timer will fire.
  bool immediate = false;

  int get pending => _queue.length;

  void send(T item) {
    if (immediate) {
      _sink([item]);
      return;
    }
    _queue.add(item);
    if (_queue.length >= maxQueueSize) {
      flush();
    } else {
      _timer ??= Timer(scheduleDelay, flush);
    }
  }

  /// Sends all queued items now.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_queue.isEmpty) return;
    final items = List<T>.of(_queue);
    _queue.clear();
    _sink(items);
  }

  /// Flushes and stops the timer.
  void dispose() => flush();
}
