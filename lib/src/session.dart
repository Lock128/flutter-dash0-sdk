import 'package:shared_preferences/shared_preferences.dart';

import 'debug.dart';
import 'ids.dart';

/// Minimal async key value store used to persist the session.
abstract class Dash0KeyValueStore {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

/// Store backed by `shared_preferences`.
class SharedPreferencesStore implements Dash0KeyValueStore {
  SharedPreferencesStore([SharedPreferencesAsync? prefs])
      : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  @override
  Future<String?> get(String key) => _prefs.getString(key);

  @override
  Future<void> set(String key, String value) => _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

/// Store that keeps values in memory. Sessions in it are marked ephemeral.
class MemoryStore implements Dash0KeyValueStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> get(String key) async => _values[key];

  @override
  Future<void> set(String key, String value) async => _values[key] = value;

  @override
  Future<void> remove(String key) async => _values.remove(key);
}

const sessionStorageKey = 'd0_session';
const _separator = '#';
const _maxTimeout = Duration(hours: 24);

/// A session with its timestamps in milliseconds since the epoch.
class Dash0Session {
  Dash0Session(this.id, this.startTime, this.lastActivityTime);

  final String id;
  final int startTime;
  int lastActivityTime;

  String serialize() => '$id$_separator$startTime$_separator$lastActivityTime';

  static Dash0Session? parse(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    final parts = stored.split(_separator);
    if (parts.length < 3) return null;
    final start = int.tryParse(parts[1]);
    final last = int.tryParse(parts[2]);
    if (parts[0].isEmpty || start == null || last == null) return null;
    return Dash0Session(parts[0], start, last);
  }
}

/// Tracks the current session, persisted so it survives app restarts, until
/// it is inactive for too long or reaches its maximum age.
class SessionManager {
  SessionManager({
    required Dash0KeyValueStore store,
    Duration inactivityTimeout = const Duration(hours: 3),
    Duration terminationTimeout = const Duration(hours: 6),
    int Function()? nowMillis,
    this.ephemeral = false,
  })  : _store = store,
        inactivityTimeout =
            inactivityTimeout > _maxTimeout ? _maxTimeout : inactivityTimeout,
        terminationTimeout =
            terminationTimeout > _maxTimeout ? _maxTimeout : terminationTimeout,
        _now = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Dash0KeyValueStore _store;
  final Duration inactivityTimeout;
  final Duration terminationTimeout;
  final int Function() _now;

  /// True when the session cannot be persisted.
  final bool ephemeral;

  Dash0Session? _session;

  /// The current session id. Only valid after [start].
  String get sessionId => _session!.id;

  /// Loads a valid stored session or creates a new one.
  Future<String> start() async {
    try {
      var session = Dash0Session.parse(await _store.get(sessionStorageKey));
      if (session != null && !_isValid(session)) session = null;
      if (session != null) {
        session.lastActivityTime = _now();
      } else {
        session = _create();
      }
      _session = session;
      await _persist();
    } catch (e) {
      dash0Warn('Failed to record session information', e);
      _session ??= _create();
    }
    return _session!.id;
  }

  /// Marks activity. Returns true if the session expired and a new one was
  /// started, in which case [sessionId] changed.
  Future<bool> touch() async {
    final session = _session;
    if (session == null) {
      await start();
      return true;
    }
    if (!_isValid(session)) {
      _session = _create();
      await _persist();
      return true;
    }
    session.lastActivityTime = _now();
    await _persist();
    return false;
  }

  /// Ends the session and starts a new one.
  Future<String> terminate() async {
    try {
      await _store.remove(sessionStorageKey);
    } catch (e) {
      dash0Debug('Failed to terminate session', e);
    }
    _session = _create();
    await _persist();
    return _session!.id;
  }

  Dash0Session _create() {
    final now = _now();
    return Dash0Session(generateSessionId(ephemeral: ephemeral), now, now);
  }

  bool _isValid(Dash0Session session) {
    final now = _now();
    if (session.lastActivityTime < now - inactivityTimeout.inMilliseconds) {
      return false;
    }
    return session.startTime >= now - terminationTimeout.inMilliseconds;
  }

  Future<void> _persist() async {
    try {
      await _store.set(sessionStorageKey, _session!.serialize());
    } catch (e) {
      dash0Debug('Failed to persist session', e);
    }
  }
}
