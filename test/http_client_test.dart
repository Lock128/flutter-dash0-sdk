import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'test_helpers.dart';

Future<(Dash0Client, FakeTransport)> start({
  List<Dash0Propagator> propagators = const [],
  List<RegExp> ignoreUrls = const [],
  List<RegExp> headersToCapture = const [],
  UrlScrubber? scrubber,
  Set<Dash0Instrumentation>? enabled,
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      batchSize: 1,
      propagators: propagators,
      ignoreUrls: ignoreUrls,
      headersToCapture: headersToCapture,
      urlScrubber: scrubber,
      enabledInstrumentations: enabled,
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
  );
  return (client, transport);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('creates a client span with http semantic attributes', () async {
    final (client, transport) = await start();
    final http1 = Dash0HttpClient(
      client,
      MockClient((r) async => http.Response('hello', 200)),
    );
    final response =
        await http1.get(Uri.parse('https://api.example.com/a?b=1#frag'));
    await client.flush();

    expect(response.body, 'hello');
    final span = transport.spans.single;
    expect(span['name'], 'HTTP GET');
    expect(span['kind'], 3);
    expect(attr(span, 'http.request.method'), 'GET');
    expect(attr(span, 'http.response.status_code'), '200');
    expect(attr(span, 'url.full'), 'https://api.example.com/a?b=1#frag');
    expect(attr(span, 'url.fragment'), 'frag');
    expect(attr(span, 'url.domain'), 'api.example.com');
    expect(attr(span, 'url.path'), '/a');
    expect(attr(span, 'url.query'), 'b=1');
    expect((span['status']! as Map)['code'], 0);
  });

  test('marks 4xx and 5xx responses as errors', () async {
    final (client, transport) = await start();
    final c = Dash0HttpClient(
      client,
      MockClient((r) async => http.Response('nope', 503)),
    );
    await c.post(Uri.parse('https://api.example.com/x'), body: 'a');
    await client.flush();
    final span = transport.spans.single;
    expect((span['status']! as Map)['code'], 2);
    expect(attr(span, 'error.type'), '503');
    expect(attr(span, 'http.request.method'), 'POST');
  });

  test('records exceptions and rethrows', () async {
    final (client, transport) = await start();
    final c = Dash0HttpClient(
      client,
      MockClient((r) async => throw http.ClientException('offline', r.url)),
    );
    await expectLater(
      c.get(Uri.parse('https://api.example.com/x')),
      throwsA(isA<http.ClientException>()),
    );
    await client.flush();
    final span = transport.spans.single;
    expect((span['status']! as Map)['code'], 2);
    expect(attr(span, 'error.type'), 'ClientException');
    expect(span['events'], isNotEmpty);
  });

  test('injects traceparent for matching urls only', () async {
    final (client, transport) = await start(propagators: [
      Dash0Propagator.traceparent([RegExp(r'^https://api\.example\.com')]),
    ]);
    final seen = <String, String?>{};
    final c = Dash0HttpClient(client, MockClient((r) async {
      seen[r.url.host] = r.headers['traceparent'];
      return http.Response('', 200);
    }));
    await c.get(Uri.parse('https://api.example.com/a'));
    await c.get(Uri.parse('https://other.example.org/a'));
    await client.flush();

    expect(seen['other.example.org'], isNull);
    final header = seen['api.example.com']!;
    final span = transport.spans.first;
    expect(header, '00-${span['traceId']}-${span['spanId']}-01');
    expect(parseTraceparent(header), isNotNull);
  });

  test('requests inside trace() become child spans', () async {
    final (client, transport) = await start();
    final c = Dash0HttpClient(
      client,
      MockClient((r) async => http.Response('', 200)),
    );
    await client.trace<void>('op', (_) async {
      await c.get(Uri.parse('https://api.example.com/a'));
    });
    await client.flush();
    final http1 = transport.spans.firstWhere((s) => s['name'] == 'HTTP GET');
    final op = transport.spans.firstWhere((s) => s['name'] == 'op');
    expect(http1['traceId'], op['traceId']);
    expect(http1['parentSpanId'], op['spanId']);
  });

  test('ignored urls and the telemetry endpoint create no spans', () async {
    final (client, transport) = await start(ignoreUrls: [RegExp('/health')]);
    var calls = 0;
    final c = Dash0HttpClient(client, MockClient((r) async {
      calls++;
      return http.Response('', 200);
    }));
    await c.get(Uri.parse('https://api.example.com/health'));
    await c.get(Uri.parse('https://ingress.example.dash0.com/v1/traces'));
    await client.flush();
    expect(calls, 2);
    expect(transport.spans, isEmpty);
  });

  test('disabled http instrumentation creates no spans', () async {
    final (client, transport) =
        await start(enabled: {Dash0Instrumentation.error});
    final c = Dash0HttpClient(
      client,
      MockClient((r) async => http.Response('', 200)),
    );
    await c.get(Uri.parse('https://api.example.com/a'));
    await client.flush();
    expect(transport.spans, isEmpty);
  });

  test('redacts credentials and applies the url scrubber', () async {
    final (client, transport) = await start(
      scrubber: (u) => u.replaceAll(RegExp(r'token=[^&]+'), 'token=REDACTED'),
    );
    final c = Dash0HttpClient(
      client,
      MockClient((r) async => http.Response('', 200)),
    );
    await c.get(Uri.parse('https://user:pw@api.example.com/a?token=secret'));
    await client.flush();
    final url = attr(transport.spans.single, 'url.full')! as String;
    expect(url, isNot(contains('secret')));
    expect(url, isNot(contains('pw')));
    expect(url, contains('token=REDACTED'));
  });

  test('captures configured headers', () async {
    final (client, transport) = await start(
        headersToCapture: [RegExp('^x-request-id\$', caseSensitive: false)]);
    final c = Dash0HttpClient(
      client,
      MockClient((r) async =>
          http.Response('', 200, headers: {'x-request-id': 'abc'})),
    );
    await c.get(Uri.parse('https://api.example.com/a'),
        headers: {'X-Request-Id': 'req1', 'Authorization': 'secret'});
    await client.flush();
    final span = transport.spans.single;
    expect(attr(span, 'http.request.header.x-request-id'), 'req1');
    expect(attr(span, 'http.response.header.x-request-id'), 'abc');
    expect(attr(span, 'http.request.header.authorization'), isNull);
  });

  test('unknown methods are reported as _OTHER', () async {
    final (client, transport) = await start();
    final c = Dash0HttpClient(
      client,
      MockClient((r) async => http.Response('', 200)),
    );
    await c.send(http.Request('BREW', Uri.parse('https://api.example.com/')));
    await client.flush();
    final span = transport.spans.single;
    expect(attr(span, 'http.request.method'), '_OTHER');
    expect(attr(span, 'http.request.method_original'), 'BREW');
  });
}
