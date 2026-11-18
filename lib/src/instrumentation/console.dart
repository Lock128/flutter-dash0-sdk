import 'dart:async';

import 'package:flutter/foundation.dart';

import '../client.dart';
import '../debug.dart';
import '../ignore_rules.dart';
import '../rate_limiter.dart';
import '../semantic_conventions.dart' as sc;
import '../semantic_conventions.dart' show Dash0Severity;
import '../url_attributes.dart';
import 'errors.dart' show sanitizeStackTrace;

/// Level of a captured console message, the values of
/// `dash0.web.console.method`.
enum Dash0ConsoleLevel {
  log(Dash0Severity.info),
  info(Dash0Severity.info),
  warn(Dash0Severity.warn),
  error(Dash0Severity.error),
  debug(Dash0Severity.debug),
  trace(Dash0Severity.debug);

  const Dash0ConsoleLevel(this.severity);
  final Dash0Severity severity;
}

const _truncationMarker = '\u2026';

/// Zone value set while the original `debugPrint` runs, so that the `print`
/// it ends in is not captured a second time.
const Object _inDebugPrintKey = #dash0InDebugPrint;

final RegExp _urlInText = RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://[^\s()]+');

/// Sends console output as `browser.console` events, the Flutter analog of
/// the console instrumentation of dash0-sdk-web (0.34.0). Sources are
/// `debugPrint`, `print` inside `Dash0.runGuarded` and `Dash0.log`.
class ConsoleInstrumentation {
  ConsoleInstrumentation(this._client, {DateTime Function()? clock})
      : _formatCap = RateLimiter(
          maxCallsPerTenMinutes: 5000,
          maxCallsPerTenSeconds: 200,
          clock: clock,
        ),
        _sendBudget = RateLimiter(
          maxCallsPerTenMinutes: 1000,
          maxCallsPerTenSeconds: 50,
          clock: clock,
        );

  final Dash0Client _client;

  /// Drops messages before formatting beyond this cap.
  final RateLimiter _formatCap;

  /// Budget for sent messages, checked after the ignore rules.
  final RateLimiter _sendBudget;

  DebugPrintCallback? _previousDebugPrint;
  DebugPrintCallback? _installedDebugPrint;

  /// Re-entry guard: formatting calls `toString()` on user objects, which may
  /// print themselves.
  bool _capturing = false;

  /// Wraps `debugPrint`. The original is kept and always called.
  void install() {
    if (!_client.options.console.captureDebugPrint) return;
    final previous = debugPrint;
    _previousDebugPrint = previous;
    _installedDebugPrint = (String? message, {int? wrapWidth}) {
      if (!isLoggingInternally && message != null) {
        capture(Dash0ConsoleLevel.log, message);
      }
      runZoned(
        () => previous(message, wrapWidth: wrapWidth),
        zoneValues: {_inDebugPrintKey: true},
      );
    };
    debugPrint = _installedDebugPrint!;
  }

  /// Restores the `debugPrint` that was active before [install].
  void uninstall() {
    final installed = _installedDebugPrint;
    if (installed != null && identical(debugPrint, installed)) {
      debugPrint = _previousDebugPrint!;
    }
    _installedDebugPrint = null;
    _previousDebugPrint = null;
  }

  /// Captures a line passed to `print` in [zone], see `Dash0.runGuarded`.
  void capturePrint(String line, Zone zone) {
    if (!_client.options.console.capturePrint) return;
    if (zone[_inDebugPrintKey] == true) return;
    capture(Dash0ConsoleLevel.log, line);
  }

  /// Sends [message] as a console event. Never throws.
  void capture(
    Dash0ConsoleLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (_capturing || isLoggingInternally) return;
    _capturing = true;
    try {
      _capture(level, message, error, stackTrace);
    } catch (e) {
      dash0Debug('Failed to capture console message', e);
    } finally {
      _capturing = false;
    }
  }

  void _capture(Dash0ConsoleLevel level, String message, Object? error,
      StackTrace? stackTrace) {
    if (!_client.isEnabled || !_client.isSessionSampled) return;
    // Beyond this cap messages are dropped before they are formatted.
    if (_formatCap.isExcessiveUsage()) return;

    final maxLength = _client.options.console.maxMessageLength;
    final text = _format(message, maxLength);
    if (text.isEmpty) return;
    if (matchesAny(_client.options.console.ignoreMessages, text)) return;
    if (_sendBudget.isExcessiveUsage()) return;

    final attributes = <String, Object?>{sc.consoleMethod: level.name};
    if (error != null) {
      attributes[sc.exceptionType] =
          error is String ? 'Error' : error.runtimeType.toString();
      final errorMessage = _scrub(error.toString());
      attributes[sc.exceptionMessage] = _cut(errorMessage, maxLength);
      if (stackTrace != null) {
        attributes[sc.exceptionStacktrace] = _sanitize(stackTrace);
      }
    }
    if (level == Dash0ConsoleLevel.trace) {
      final stack = _sanitize(
          error == null && stackTrace != null ? stackTrace : StackTrace.current,
          dropOwnFrames: true);
      if (stack.isNotEmpty) attributes[sc.codeStacktrace] = stack;
    }

    _client.emitEvent(
      _client.names.console,
      severity: level.severity,
      data: text,
      attributes: attributes,
      rateLimited: false,
    );
  }

  /// Scrubs URLs, then cuts. Cutting first could shorten a URL so that it no
  /// longer matches the scrubber.
  String _format(String message, int maxLength) {
    final scrubbed = _scrub(message);
    return scrubbed.length > maxLength
        ? '${scrubbed.substring(0, maxLength)}$_truncationMarker'
        : scrubbed;
  }

  String _scrub(String text) => text.replaceAllMapped(
      _urlInText, (m) => scrubUrl(m[0]!, _client.options.urlScrubber));

  String _cut(String text, int max) =>
      text.length > max ? text.substring(0, max) : text;

  String _sanitize(StackTrace stack, {bool dropOwnFrames = false}) {
    var text = stack.toString();
    if (dropOwnFrames) {
      text = text
          .split('\n')
          .where((l) => !l.contains('package:dash0_flutter_sdk/'))
          .join('\n');
    }
    return sanitizeStackTrace(
      text,
      ignoreRules: _client.ignoreRules,
      scrubber: _client.options.urlScrubber,
    );
  }
}
