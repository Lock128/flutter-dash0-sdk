import 'options.dart';

/// Whether any pattern in [patterns] matches [s]. A [RegExp] is tested
/// against [s]. A [String] matches when [s] contains it (case-sensitive).
bool matchesAny(List<Pattern> patterns, String s) {
  for (final p in patterns) {
    if (p is String) {
      if (p.isNotEmpty && s.contains(p)) return true;
    } else if (p.allMatches(s).isNotEmpty) {
      return true;
    }
  }
  return false;
}

/// Trims strings and drops empty ones. Other patterns are kept.
List<Pattern> normalizePatterns(List<Pattern> patterns) => [
      for (final p in patterns)
        if (p is! String) p else if (p.trim().isNotEmpty) p.trim(),
    ];

/// Decides which URLs and errors are not tracked, mirroring
/// `ignore-rules.ts`.
class IgnoreRules {
  IgnoreRules({
    List<Pattern> ignoreUrls = const [],
    List<Pattern> ignoreErrorMessages = const [],
    this.endpoints = const [],
    this.ignoreCrossOriginScriptErrors = true,
    this.ignoreBrowserExtensionErrors = true,
  })  : ignoreUrls = normalizePatterns(ignoreUrls),
        ignoreErrorMessages = normalizePatterns(ignoreErrorMessages);

  final List<Pattern> ignoreUrls;
  final List<Pattern> ignoreErrorMessages;
  final List<Dash0Endpoint> endpoints;
  final bool ignoreCrossOriginScriptErrors;
  final bool ignoreBrowserExtensionErrors;

  /// True for empty URLs, `data:` URLs, requests to the telemetry endpoints
  /// and URLs matching [ignoreUrls].
  bool isUrlIgnored(String? url) {
    if (url == null || url.isEmpty) return true;
    final lower = url.toLowerCase();
    if (lower.startsWith('data:')) return true;
    for (final e in endpoints) {
      if (lower.startsWith(e.url.toLowerCase())) return true;
    }
    return matchesAny(ignoreUrls, url);
  }

  /// True when [message] matches [ignoreErrorMessages], is a cross-origin
  /// `Script error.` or [stack] only has browser extension frames. The last
  /// two are controlled by the matching options.
  bool isErrorIgnored(String message, [String? stack]) {
    if (matchesAny(ignoreErrorMessages, message)) return true;
    if (ignoreCrossOriginScriptErrors &&
        _crossOriginScriptError.hasMatch(message)) {
      return true;
    }
    return ignoreBrowserExtensionErrors &&
        hasOnlyBrowserExtensionFrames(message, stack);
  }
}

final RegExp _crossOriginScriptError =
    RegExp(r'^(Script error\.?|Javascript error: Script error\.? on line 0)$');

final RegExp _browserExtensionUrl = RegExp(
    r'^(chrome-extension|moz-extension|ms-browser-extension|safari-extension|safari-web-extension|webkit-masked-url)://',
    caseSensitive: false);

final RegExp _urlInFrame =
    RegExp(r'[a-z][a-z0-9+.-]*://[^\s()]+', caseSensitive: false);

/// True when [stack] has frames with a URL and every one of them belongs to a
/// browser extension. A single page frame keeps the error. Port of
/// `hasOnlyBrowserExtensionFrames` in dash0-sdk-web.
bool hasOnlyBrowserExtensionFrames(String message, String? stack) {
  if (stack == null || stack.isEmpty) return false;
  final lines = stack.split('\n');
  // V8 starts the stack with "<name>: <message>", and the message can span
  // lines.
  final firstFrame =
      _isMessageHeader(lines[0], message) ? message.split('\n').length : 0;
  var hasExtensionFrame = false;
  for (var i = firstFrame; i < lines.length; i++) {
    final url = _urlInFrame.firstMatch(lines[i]);
    if (url == null) continue;
    if (!_browserExtensionUrl.hasMatch(url[0]!)) return false;
    hasExtensionFrame = true;
  }
  return hasExtensionFrame;
}

bool _isMessageHeader(String firstLine, String message) {
  final separator = firstLine.indexOf(': ');
  final text = separator < 0 ? firstLine : firstLine.substring(separator + 2);
  final messageEnd = message.indexOf('\n');
  final firstMessageLine =
      messageEnd < 0 ? message : message.substring(0, messageEnd);
  return text.isNotEmpty && firstMessageLine.endsWith(text);
}
