import 'dart:async';
import 'dart:isolate';

/// A helper isolate that observes the heartbeat of the main isolate and
/// reports when it stopped for longer than the ANR threshold.
class StallWatchdog {
  StallWatchdog._(this._isolate, this._commands, this._events);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _events;
  bool _stopped = false;

  /// Records a heartbeat, [micros] since epoch. Null marks a pause.
  void beat(int? micros) {
    if (!_stopped) _commands.send(micros ?? 0);
  }

  /// Stops the isolate and closes the port.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _commands.send('stop');
    _events.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// Starts the watchdog. Returns null when the isolate cannot be spawned.
Future<StallWatchdog?> startStallWatchdog({
  required Duration anrThreshold,
  required void Function(int sinceMicros, int stallMicros) onStall,
}) async {
  final events = ReceivePort();
  try {
    final ready = Completer<SendPort>();
    events.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is List && message.length == 2) {
        onStall(message[0] as int, message[1] as int);
      }
    });
    final isolate = await Isolate.spawn<List<Object>>(
      _watchdogMain,
      [events.sendPort, anrThreshold.inMicroseconds],
      debugName: 'dash0-watchdog',
    );
    final commands = await ready.future.timeout(const Duration(seconds: 2));
    return StallWatchdog._(isolate, commands, events);
  } catch (_) {
    events.close();
    return null;
  }
}

void _watchdogMain(List<Object> args) {
  final out = args[0] as SendPort;
  final threshold = args[1] as int;
  final inbox = ReceivePort();
  var last = DateTime.now().microsecondsSinceEpoch;
  var paused = false;
  var reportedFor = -1;
  late final Timer timer;
  timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
    if (paused) return;
    final now = DateTime.now().microsecondsSinceEpoch;
    if (now - last > threshold && reportedFor != last) {
      reportedFor = last;
      out.send([last, now - last]);
    }
  });
  inbox.listen((message) {
    if (message == 'stop') {
      timer.cancel();
      inbox.close();
    } else if (message is int) {
      if (message == 0) {
        paused = true;
      } else {
        paused = false;
        last = message;
      }
    }
  });
  out.send(inbox.sendPort);
}
