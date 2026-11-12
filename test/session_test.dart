import 'package:dash0_flutter_sdk/src/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  var now = 1000000;
  setUp(() => now = 1000000);

  SessionManager manager(MemoryStore store) => SessionManager(
        store: store,
        inactivityTimeout: const Duration(minutes: 30),
        terminationTimeout: const Duration(hours: 2),
        nowMillis: () => now,
      );

  test('creates and persists a session', () async {
    final store = MemoryStore();
    final id = await manager(store).start();
    expect(id, hasLength(16));
    expect(await store.get(sessionStorageKey), startsWith('$id#'));
  });

  test('reuses a valid stored session', () async {
    final store = MemoryStore();
    final first = await manager(store).start();
    now += const Duration(minutes: 10).inMilliseconds;
    expect(await manager(store).start(), first);
  });

  test('starts a new session after inactivity', () async {
    final store = MemoryStore();
    final first = await manager(store).start();
    now += const Duration(minutes: 31).inMilliseconds;
    expect(await manager(store).start(), isNot(first));
  });

  test('starts a new session after the termination timeout', () async {
    final store = MemoryStore();
    final m = manager(store);
    final first = await m.start();
    for (var i = 0; i < 5; i++) {
      now += const Duration(minutes: 25).inMilliseconds;
      await m.touch();
    }
    expect(m.sessionId, isNot(first));
  });

  test('touch rotates an expired session and reports it', () async {
    final m = manager(MemoryStore());
    final first = await m.start();
    expect(await m.touch(), isFalse);
    now += const Duration(minutes: 31).inMilliseconds;
    expect(await m.touch(), isTrue);
    expect(m.sessionId, isNot(first));
  });

  test('terminate replaces the session', () async {
    final store = MemoryStore();
    final m = manager(store);
    final first = await m.start();
    final second = await m.terminate();
    expect(second, isNot(first));
    expect(await store.get(sessionStorageKey), startsWith('$second#'));
  });

  test('ignores corrupt stored values', () async {
    final store = MemoryStore();
    await store.set(sessionStorageKey, 'junk');
    expect(await manager(store).start(), hasLength(16));
  });

  test('ephemeral sessions carry the flag', () async {
    final m = SessionManager(store: MemoryStore(), ephemeral: true);
    expect(await m.start(), startsWith('01'));
  });
}
