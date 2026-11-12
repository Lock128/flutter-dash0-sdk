import 'package:dash0_flutter_sdk/src/ids.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final hex = RegExp(r'^[0-9a-f]+$');

  test('unique ids are lower case hex of the requested length', () {
    final id = generateUniqueId(8);
    expect(id, hasLength(16));
    expect(hex.hasMatch(id), isTrue);
    expect(generateUniqueId(8), isNot(id));
  });

  test('session id has 16 hex characters and carries the ephemeral flag', () {
    final id = generateSessionId();
    expect(id, matches(RegExp(r'^00[0-9a-f]{14}$')));
    expect(generateSessionId(ephemeral: true), startsWith('01'));
  });

  test('trace id has 32 hex characters and embeds the session', () {
    final session = generateSessionId();
    final trace = generateTraceId(session);
    expect(trace, hasLength(32));
    expect(hex.hasMatch(trace), isTrue);
    expect(trace.substring(0, 6), 'd04200');
    expect(trace.substring(6, 22), session);
  });

  test('trace id without session sets the flag', () {
    final trace = generateTraceId(null);
    expect(trace, hasLength(32));
    expect(trace.substring(0, 6), 'd04201');
  });

  test('span id has 16 hex characters prefixed by the trace id crc32', () {
    final trace = generateTraceId(generateSessionId());
    final span = generateSpanId(trace);
    expect(span, hasLength(16));
    expect(hex.hasMatch(span), isTrue);
    expect(
        span.substring(0, 8), crc32(trace).toRadixString(16).padLeft(8, '0'));
  });

  test('crc32 matches the IEEE test vector', () {
    // "123456789" as hex bytes.
    expect(crc32('313233343536373839'), 0xcbf43926);
  });

  group('isSessionSampledIn', () {
    test('0 never and 100 always samples', () {
      expect(isSessionSampledIn('0011223344556677', 0), isFalse);
      expect(isSessionSampledIn('0011223344556677', 100), isTrue);
    });

    test('is deterministic per session', () {
      final id = generateSessionId();
      final first = isSessionSampledIn(id, 50);
      for (var i = 0; i < 10; i++) {
        expect(isSessionSampledIn(id, 50), first);
      }
    });

    test('approximates the configured rate', () {
      var sampled = 0;
      for (var i = 0; i < 2000; i++) {
        if (isSessionSampledIn(generateSessionId(), 30)) sampled++;
      }
      expect(sampled / 2000, closeTo(0.3, 0.06));
    });
  });
}
