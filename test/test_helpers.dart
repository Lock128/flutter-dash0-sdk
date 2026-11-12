import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';

/// Transport that records everything instead of sending it.
class FakeTransport implements Dash0Transport {
  final List<({String path, Map<String, Object?> body})> sent = [];
  bool closed = false;

  @override
  Future<void> send(String path, Map<String, Object?> body) async {
    sent.add((path: path, body: body));
  }

  @override
  void close() => closed = true;

  /// All log records sent so far.
  List<Map<String, Object?>> get logs => [
        for (final s in sent.where((s) => s.path == '/v1/logs'))
          for (final rl in s.body['resourceLogs']! as List)
            for (final sl in (rl as Map)['scopeLogs'] as List)
              ...((sl as Map)['logRecords'] as List)
                  .cast<Map<String, Object?>>(),
      ];

  /// All spans sent so far.
  List<Map<String, Object?>> get spans => [
        for (final s in sent.where((s) => s.path == '/v1/traces'))
          for (final rs in s.body['resourceSpans']! as List)
            for (final ss in (rs as Map)['scopeSpans'] as List)
              ...((ss as Map)['spans'] as List).cast<Map<String, Object?>>(),
      ];
}

const testEndpoint = Dash0Endpoint(
  url: 'https://ingress.example.dash0.com',
  authToken: 'auth_test',
);

/// Reads an attribute from an OTLP attribute list.
Object? attr(Map<String, Object?> signal, String key) {
  for (final kv in (signal['attributes']! as List).cast<Map>()) {
    if (kv['key'] == key) {
      final v = kv['value'] as Map;
      return v.values.first;
    }
  }
  return null;
}

extension FakeTransportMetrics on FakeTransport {
  /// All metrics sent so far.
  List<Map<String, Object?>> get metrics => [
        for (final s in sent.where((s) => s.path == '/v1/metrics'))
          for (final rm in s.body['resourceMetrics']! as List)
            for (final sm in (rm as Map)['scopeMetrics'] as List)
              ...((sm as Map)['metrics'] as List).cast<Map<String, Object?>>(),
      ];
}
