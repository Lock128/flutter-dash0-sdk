import 'dart:io' show ProcessInfo;

/// Resident set size in bytes, null where unavailable.
int? currentRssBytes() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return null;
  }
}
