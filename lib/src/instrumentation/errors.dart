import 'package:flutter/foundation.dart';

import '../client.dart';
import '../debug.dart';
import '../ignore_rules.dart';
import '../otlp.dart';
import '../options.dart';
import '../semantic_conventions.dart' as sc;
import '../semantic_conventions.dart' show Dash0Severity;
import '../url_attributes.dart';

const _maxErrorsToReport = 100;
const _maxStackFrames = 30;
const _dedupeWindow = Duration(seconds: 1);

final RegExp _urlInFrame = RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://[^\s()]+');

/// Limits [stack] to [maxFrames] lines and passes URLs through the scrubber.
/// URLs of ignored pages are redacted.
String sanitizeStackTrace(
  String stack, {
  required IgnoreRules ignoreRules,
  UrlScrubber? scrubber,
  int maxFrames = _maxStackFrames,
}) {
  final lines = stack.split('\n').where((l) => l.trim().isNotEmpty).toList();
  final kept = lines.length > maxFrames ? lines.sublist(0, maxFrames) : lines;
  return kept.map((line) {
    return line.replaceAllMapped(_urlInFrame, (m) {
      final url = m[0]!;
      if (ignoreRules.ignoreUrls.isNotEmpty &&
          matchesAny(ignoreRules.ignoreUrls, url)) {
        return 'REDACTED';
      }
      return scrubUrl(url, scrubber);
    });
  }).join('\n');
}

/// Captures uncaught errors, mirroring the unhandled error instrumentation of
/// dash0-sdk-web: Flutter framework errors and uncaught async/platform
/// errors are sent as `app.error` events.
class ErrorInstrumentation {
  ErrorInstrumentation(this._client, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Dash0Client _client;
  final DateTime Function() _clock;

  FlutterExceptionHandler? _previousFlutterHandler;
  FlutterExceptionHandler? _installedFlutterHandler;
  bool Function(Object, StackTrace)? _previousPlatformHandler;
  bool Function(Object, StackTrace)? _installedPlatformHandler;

  int _reported = 0;
  final Map<String, DateTime> _recent = {};

  /// Hooks `FlutterError.onError` and `PlatformDispatcher.onError`. The
  /// previous handlers are still called.
  void install() {
    _previousFlutterHandler = FlutterError.onError;
    _installedFlutterHandler = (FlutterErrorDetails details) {
      try {
        report(
          details.exception,
          stackTrace: details.stack,
          componentStack: details.context?.toDescription(),
          attributes: {
            if (details.library != null) 'exception.library': details.library,
          },
        );
      } catch (e) {
        dash0Debug('Failed to report Flutter error', e);
      }
      final previous = _previousFlutterHandler;
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    FlutterError.onError = _installedFlutterHandler;

    _previousPlatformHandler = PlatformDispatcher.instance.onError;
    _installedPlatformHandler = (Object error, StackTrace stack) {
      try {
        report(error, stackTrace: stack);
      } catch (e) {
        dash0Debug('Failed to report platform error', e);
      }
      return _previousPlatformHandler?.call(error, stack) ?? false;
    };
    PlatformDispatcher.instance.onError = _installedPlatformHandler;
  }

  /// Restores the handlers that were active before [install].
  void uninstall() {
    if (identical(FlutterError.onError, _installedFlutterHandler)) {
      FlutterError.onError = _previousFlutterHandler;
    }
    if (identical(
        PlatformDispatcher.instance.onError, _installedPlatformHandler)) {
      PlatformDispatcher.instance.onError = _previousPlatformHandler;
    }
  }

  /// Sends [error] as an `app.error` event unless an ignore rule matches, the
  /// limit of reported errors is reached or the same error was just seen.
  void report(
    Object error, {
    StackTrace? stackTrace,
    Attributes? attributes,
    String? componentStack,
  }) {
    // Disabled or sampled out clients drop the signal, so they must not use
    // up the error cap or the dedupe window either.
    if (!_client.isEnabled || !_client.isSessionSampled) return;
    final message = error.toString();
    if (message.isEmpty || _reported >= _maxErrorsToReport) return;
    if (_client.ignoreRules.isErrorIgnored(message)) {
      dash0Debug('Error matches an ignore rule. Will not send it.', message);
      return;
    }

    final type = error is String ? 'Error' : error.runtimeType.toString();
    final stack = stackTrace?.toString() ?? '';
    final firstFrame = stack.split('\n').firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '',
        );
    final key = '$type|$message|$firstFrame';
    final now = _clock();
    final last = _recent[key];
    if (last != null && now.difference(last) < _dedupeWindow) return;
    if (_recent.length >= 20) _recent.clear();
    _recent[key] = now;
    _reported++;

    _client.emitEvent(
      _client.names.error,
      severity: Dash0Severity.error,
      data: message,
      attributes: {
        sc.exceptionType: type,
        sc.exceptionMessage: message,
        if (stack.isNotEmpty)
          sc.exceptionStacktrace: sanitizeStackTrace(
            stack,
            ignoreRules: _client.ignoreRules,
            scrubber: _client.options.urlScrubber,
          ),
        if (componentStack != null) sc.errorComponentStack: componentStack,
        ...attributes ?? const {},
      },
    );
  }
}
