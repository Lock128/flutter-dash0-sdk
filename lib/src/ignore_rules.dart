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
  })  : ignoreUrls = normalizePatterns(ignoreUrls),
        ignoreErrorMessages = normalizePatterns(ignoreErrorMessages);

  final List<Pattern> ignoreUrls;
  final List<Pattern> ignoreErrorMessages;
  final List<Dash0Endpoint> endpoints;

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

  bool isErrorIgnored(String message) =>
      matchesAny(ignoreErrorMessages, message);
}
