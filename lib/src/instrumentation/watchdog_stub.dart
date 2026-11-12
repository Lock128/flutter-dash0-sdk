/// Web has no isolates: the watchdog is not available.
class StallWatchdog {
  StallWatchdog._();

  /// Records a heartbeat, [micros] since epoch. Null marks a pause.
  void beat(int? micros) {}

  void stop() {}
}

/// Always returns null on this platform.
Future<StallWatchdog?> startStallWatchdog({
  required Duration anrThreshold,
  required void Function(int sinceMicros, int stallMicros) onStall,
}) async =>
    null;
