/// Gzip is not available without `dart:io`, bodies are sent uncompressed.
List<int>? gzipEncode(List<int> bytes) => null;
