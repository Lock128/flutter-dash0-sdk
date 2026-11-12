/// Fixed window rate limiter, mirroring `rate-limit.ts`.
///
/// Uses timestamps instead of timers so it creates no background work.
class RateLimiter {
  RateLimiter({
    int maxCallsPerTenMinutes = 128,
    int maxCallsPerTenSeconds = 32,
    DateTime Function()? clock,
  })  : maxCallsPerTenMinutes =
            maxCallsPerTenMinutes == 0 ? 128 : maxCallsPerTenMinutes,
        maxCallsPerTenSeconds =
            maxCallsPerTenSeconds == 0 ? 32 : maxCallsPerTenSeconds,
        _clock = clock ?? DateTime.now {
    final now = _clock();
    _minuteWindowStart = now;
    _secondWindowStart = now;
  }

  final int maxCallsPerTenMinutes;
  final int maxCallsPerTenSeconds;
  final DateTime Function() _clock;

  late DateTime _minuteWindowStart;
  late DateTime _secondWindowStart;
  int _callsInTenMinutes = 0;
  int _callsInTenSeconds = 0;

  /// Registers a call and returns true when a limit is exceeded.
  bool isExcessiveUsage() {
    final now = _clock();
    if (now.difference(_minuteWindowStart) >= const Duration(minutes: 10)) {
      _minuteWindowStart = now;
      _callsInTenMinutes = 0;
    }
    if (now.difference(_secondWindowStart) >= const Duration(seconds: 10)) {
      _secondWindowStart = now;
      _callsInTenSeconds = 0;
    }
    _callsInTenMinutes++;
    _callsInTenSeconds++;
    return _callsInTenMinutes > maxCallsPerTenMinutes ||
        _callsInTenSeconds > maxCallsPerTenSeconds;
  }
}
