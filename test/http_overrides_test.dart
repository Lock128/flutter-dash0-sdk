import 'dart:io';

import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart'
    hide Dash0HttpOverrides;
// The analyzer resolves the public export to the web stub, so import the
// dart:io implementation directly.
import 'package:dash0_flutter_sdk/src/instrumentation/http_overrides_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'test_helpers.dart';

/// Hands out plain clients, bypassing the mock overrides of flutter_test.
class _Plain extends HttpOverrides {}

Future<(Dash0Client, FakeTransport)> startClient({
  List<RegExp> ignoreUrls = const [],
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      batchSize: 1,
      ignoreUrls: ignoreUrls,
      propagators: [
        Dash0Propagator.traceparent([RegExp(r'127\.0\.0\.1')])
      ],
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
    installHttpOverrides: false,
  );
  return (client, transport);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late List<HttpRequest> seen;
  late Uri base;

  setUp(() async {
    seen = [];
    server = await HttpServer.bind('127.0.0.1', 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      seen.add(request);
      if (request.uri.path == '/fail') {
        request.response.statusCode = 500;
      }
      request.response.write('hello');
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  Future<R> underOverrides<R>(Dash0Client client, Future<R> Function() body) {
    return HttpOverrides.runWithHttpOverrides(
      body,
      Dash0HttpOverrides(client, previous: _Plain()),
    );
  }

  test('instruments plain dart:io HttpClient requests', () async {
    final (client, transport) = await startClient();
    String? traceparent;
    await underOverrides(client, () async {
      final http1 = HttpClient();
      final request =
          await http1.getUrl(base.replace(path: '/a', query: 'b=1'));
      final response = await request.close();
      final body =
          await response.transform(const SystemEncoding().decoder).join();
      expect(body, 'hello');
      http1.close();
    });
    traceparent = seen.single.headers.value('traceparent');
    await client.flush();

    final span = transport.spans.single;
    expect(span['name'], 'HTTP GET');
    expect(span['kind'], 3);
    expect(attr(span, 'http.request.method'), 'GET');
    expect(attr(span, 'url.full'), '$base/a?b=1');
    expect(attr(span, 'http.response.status_code'), '200');
    expect(traceparent, contains(span['traceId']! as String));
    expect(traceparent, contains(span['spanId']! as String));

    final metric = transport.metrics.single;
    expect(metric['name'], 'http.client.request.duration');
    await client.shutdown();
  });

  test('instruments package:http IOClient', () async {
    final (client, transport) = await startClient();
    await underOverrides(client, () async {
      final c = IOClient();
      final r = await c.post(base.replace(path: '/p'), body: 'data');
      expect(r.statusCode, 200);
      c.close();
    });
    await client.flush();
    final span = transport.spans.single;
    expect(attr(span, 'http.request.method'), 'POST');
    expect(seen.single.headers.value('traceparent'), isNotNull);
    await client.shutdown();
  });

  test('marks error responses', () async {
    final (client, transport) = await startClient();
    await underOverrides(client, () async {
      final c = HttpClient();
      final res = await (await c.getUrl(base.replace(path: '/fail'))).close();
      await res.drain<void>();
      c.close();
    });
    await client.flush();
    final span = transport.spans.single;
    expect(attr(span, 'error.type'), '500');
    expect((span['status']! as Map)['code'], 2);
    await client.shutdown();
  });

  test('records connection errors', () async {
    final (client, transport) = await startClient();
    final port = server.port;
    await server.close(force: true);
    await underOverrides(client, () async {
      final c = HttpClient();
      await expectLater(
        c.getUrl(Uri.parse('http://127.0.0.1:$port/x')).then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
      c.close();
    });
    await client.flush();
    final span = transport.spans.single;
    expect(attr(span, 'error.type'), 'SocketException');
    expect((span['status']! as Map)['code'], 2);
    await client.shutdown();
    server = await HttpServer.bind('127.0.0.1', 0);
  });

  test('cancelling the response subscription ends the span', () async {
    final (client, transport) = await startClient();
    await underOverrides(client, () async {
      final c = HttpClient();
      final res = await (await c.getUrl(base.replace(path: '/c'))).close();
      await res.listen((_) {}).cancel();
      c.close(force: true);
    });
    await client.flush();
    expect(transport.spans, hasLength(1));
    expect(transport.metrics.single['name'], 'http.client.request.duration');
    await client.shutdown();
  });

  test('a request that is never closed ends its span', () async {
    final (client, transport) = await startClient();
    final old = dash0AbandonedRequestTimeout;
    dash0AbandonedRequestTimeout = const Duration(milliseconds: 20);
    try {
      await underOverrides(client, () async {
        final c = HttpClient();
        await c.getUrl(base.replace(path: '/never'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        c.close(force: true);
      });
    } finally {
      dash0AbandonedRequestTimeout = old;
    }
    await client.flush();
    expect(transport.spans, hasLength(1));
    expect(attr(transport.spans.single, 'error.type'), 'TimeoutException');
    await client.shutdown();
  });

  test('a slow upload is not reported as abandoned', () async {
    final (client, transport) = await startClient();
    final old = dash0AbandonedRequestTimeout;
    dash0AbandonedRequestTimeout = const Duration(milliseconds: 150);
    try {
      await underOverrides(client, () async {
        final c = HttpClient();
        final req = await c.postUrl(base.replace(path: '/slow'));
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 70));
          req.add([1, 2, 3]);
        }
        final res = await req.close();
        await res.drain<void>();
        c.close();
      });
    } finally {
      dash0AbandonedRequestTimeout = old;
    }
    await client.flush();
    expect(transport.spans, hasLength(1));
    expect(attr(transport.spans.single, 'error.type'), isNull);
    await client.shutdown();
  });

  test('respects ignoreUrls', () async {
    final (client, transport) =
        await startClient(ignoreUrls: [RegExp('/ignored')]);
    await underOverrides(client, () async {
      final c = HttpClient();
      final res =
          await (await c.getUrl(base.replace(path: '/ignored'))).close();
      await res.drain<void>();
      c.close();
    });
    await client.flush();
    expect(transport.spans, isEmpty);
    expect(seen.single.headers.value('traceparent'), isNull);
    await client.shutdown();
  });

  test('no duplicate span when Dash0HttpClient runs on top', () async {
    final (client, transport) = await startClient();
    await underOverrides(client, () async {
      final c = Dash0HttpClient(client, IOClient());
      final r = await c.get(base.replace(path: '/dup'));
      expect(r.statusCode, 200);
      c.close();
    });
    await client.flush();
    expect(transport.spans, hasLength(1));
    expect(transport.metrics.single['name'], 'http.client.request.duration');
    final points =
        (transport.metrics.single['histogram']! as Map)['dataPoints'] as List;
    expect((points.single as Map)['count'], '1');
    await client.shutdown();
  });

  test('install chains to the previous overrides and uninstall restores',
      () async {
    final (client, transport) = await startClient();
    client.installHttpOverrides();
    expect(HttpOverrides.current, isA<Dash0HttpOverrides>());
    final c = http.Client();
    // flutter_test mocks answer 400, the span is created either way.
    try {
      await c.get(base.replace(path: '/g'));
    } catch (_) {}
    client.uninstallHttpOverrides();
    expect(HttpOverrides.current, isNot(isA<Dash0HttpOverrides>()));
    await client.flush();
    expect(transport.spans, hasLength(1));
    await client.shutdown();
  });
}
