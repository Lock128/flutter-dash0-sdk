import 'package:flutter/foundation.dart';

bool _debugEnabled = false;

/// Enables or disables SDK debug logging.
void setDash0Debug(bool enabled) => _debugEnabled = enabled;

/// Whether SDK debug logging is enabled.
bool get isDash0Debug => _debugEnabled;

bool _loggingInternally = false;

/// True while the SDK prints its own diagnostics. The console capture ignores
/// that output so it cannot loop back into the telemetry.
bool get isLoggingInternally => _loggingInternally;

void _print(String line) {
  final previous = _loggingInternally;
  _loggingInternally = true;
  try {
    debugPrint(line);
  } finally {
    _loggingInternally = previous;
  }
}

/// Logs a debug message when debug logging is enabled.
void dash0Debug(String message, [Object? detail]) {
  if (!_debugEnabled) return;
  _print('[dash0] $message${detail == null ? '' : ' $detail'}');
}

/// Logs a warning. Always printed in debug mode builds, otherwise only when
/// SDK debug logging is enabled.
void dash0Warn(String message, [Object? detail]) {
  if (!_debugEnabled && !kDebugMode) return;
  _print('[dash0] WARN $message${detail == null ? '' : ' $detail'}');
}
