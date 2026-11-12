import 'options.dart';

/// Whether any expression in [patterns] matches [s].
bool matchesAny(List<RegExp> patterns, String s) {
  for (final p in patterns) {
    if (p.hasMatch(s)) return true;
  }
  return false;
}

/// Decides which URLs and errors are not tracked, mirroring
/// `ignore-rules.ts`.
class IgnoreRules {
  IgnoreRules({
    this.ignoreUrls = const [],
    this.ignoreErrorMessages = const [],
    this.endpoints = const [],
  });

  final List<RegExp> ignoreUrls;
  final List<RegExp> ignoreErrorMessages;
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
