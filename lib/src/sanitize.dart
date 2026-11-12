final RegExp _suspiciousChars = RegExp('[\'"<>{};\\x00-\\x1F\\x7F]');

/// Returns true if [value] is safe to use as a `service.name`.
///
/// Rejects characters commonly used in injection payloads: quotes, angle
/// brackets, braces, semicolons and control characters.
bool isSafeServiceName(String value) => !_suspiciousChars.hasMatch(value);
