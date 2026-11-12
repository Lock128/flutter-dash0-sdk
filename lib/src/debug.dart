import 'package:flutter/foundation.dart';

bool _debugEnabled = false;

/// Enables or disables SDK debug logging.
void setDash0Debug(bool enabled) => _debugEnabled = enabled;

/// Whether SDK debug logging is enabled.
bool get isDash0Debug => _debugEnabled;

/// Logs a debug message when debug logging is enabled.
void dash0Debug(String message, [Object? detail]) {
  if (!_debugEnabled) return;
  debugPrint('[dash0] $message${detail == null ? '' : ' $detail'}');
}

/// Logs a warning. Always printed in debug mode builds, otherwise only when
/// SDK debug logging is enabled.
void dash0Warn(String message, [Object? detail]) {
  if (!_debugEnabled && !kDebugMode) return;
  debugPrint('[dash0] WARN $message${detail == null ? '' : ' $detail'}');
}
