/// Identifier generation, mirroring `id.ts`, `trace-id.ts`, `span-id.ts`,
/// `session-id.ts` and `crc32.ts` of dash0-sdk-web.
library;

import 'dart:math';

const spanIdBytes = 8;
const traceIdBytes = 16;
const sessionIdBytes = 8;
const appInstanceIdBytes = 8;
const eventIdBytes = 8;

const _traceIdPrefix = 'd042';

Random _random = _createRandom();

Random _createRandom() {
  try {
    return Random.secure();
  } catch (_) {
    return Random();
  }
}

/// Replaces the random source. Only intended for tests.
void debugSetRandom(Random random) => _random = random;

/// Generates [byteCount] random bytes encoded as lower case hex.
String generateUniqueId(int byteCount) {
  final buffer = StringBuffer();
  for (var i = 0; i < byteCount; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Generates a session id: one flags byte followed by random bytes. The
/// ephemeral flag (0x01) marks sessions that could not be persisted.
String generateSessionId({bool ephemeral = false}) {
  final flags = (ephemeral ? 0x01 : 0x00).toRadixString(16).padLeft(2, '0');
  return '$flags${generateUniqueId(sessionIdBytes - 1)}';
}

/// Generates a 32 character trace id embedding the session id so that traces
/// can be correlated with sessions. Layout: `d042` + flags + session id +
/// random. The flag 0x01 marks traces without a session.
String generateTraceId(String? sessionId) {
  if (sessionId == null || sessionId.isEmpty) {
    return '${_traceIdPrefix}01${generateUniqueId(traceIdBytes - 3)}';
  }
  return '${_traceIdPrefix}00$sessionId'
      '${generateUniqueId(traceIdBytes - sessionIdBytes - 3)}';
}

/// Generates a 16 character span id whose first four bytes are the CRC32 of
/// the trace id.
String generateSpanId(String traceId) {
  final prefix = crc32(traceId).toRadixString(16).padLeft(8, '0');
  return '$prefix${generateUniqueId(spanIdBytes - 4)}';
}

final List<int> _crcTable = () {
  const polynomial = 0xedb88320;
  return List<int>.generate(256, (i) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? polynomial ^ (c >> 1) : c >> 1;
    }
    return c & 0xffffffff;
  });
}();

/// CRC32 (IEEE 802.3) of the bytes described by the hex string [hex].
int crc32(String hex) {
  var crc = 0xffffffff;
  for (var i = 0; i + 1 < hex.length; i += 2) {
    final byte = int.tryParse(hex.substring(i, i + 2), radix: 16) ?? 0;
    crc = (crc >> 8) ^ _crcTable[(crc ^ byte) & 0xff];
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

/// Deterministic sampling decision per session id.
///
/// [samplingRate] is a percentage between 0 and 100.
bool isSessionSampledIn(String sessionId, num samplingRate) {
  if (samplingRate <= 0) return false;
  if (samplingRate >= 100) return true;
  return crc32(sessionId) % 100 < samplingRate;
}
