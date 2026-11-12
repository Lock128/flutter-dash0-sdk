import 'dart:io' show gzip;

/// Gzip compresses [bytes]. Returns null when compression failed.
List<int>? gzipEncode(List<int> bytes) {
  try {
    return gzip.encode(bytes);
  } catch (_) {
    return null;
  }
}
