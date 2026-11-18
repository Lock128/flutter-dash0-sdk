import 'options.dart';
import 'semantic_conventions.dart' as sc;

/// Removes `user:password@` credentials from [url].
String redactCredentials(String url) {
  return url.replaceFirstMapped(
    RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/?#@]*@'),
    (m) => '${m[1]}REDACTED:REDACTED@',
  );
}

/// Scrubs [url]: credentials first, then the user supplied [scrubber].
String scrubUrl(String url, UrlScrubber? scrubber) {
  final redacted = redactCredentials(url);
  if (scrubber == null) return redacted;
  try {
    return scrubber(redacted);
  } catch (_) {
    return redacted;
  }
}

/// Builds the `url.*` attributes for [url].
Map<String, Object?> urlAttributes(String url, UrlScrubber? scrubber) {
  final scrubbed = scrubUrl(url, scrubber);
  final uri = Uri.tryParse(scrubbed);
  final attrs = <String, Object?>{sc.urlFull: scrubbed};
  if (uri == null) return attrs;
  if (uri.hasScheme) attrs[sc.urlScheme] = uri.scheme;
  if (uri.host.isNotEmpty) attrs[sc.urlDomain] = uri.host;
  if (uri.path.isNotEmpty) attrs[sc.urlPath] = uri.path;
  if (uri.hasQuery) attrs[sc.urlQuery] = uri.query;
  if (uri.hasFragment) attrs[sc.urlFragment] = uri.fragment;
  return attrs;
}
