import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Future<FakeTransport> init({
  bool enabled = true,
  List<RegExp> ignoreUrls = const [],
}) async {
  final transport = FakeTransport();
  await Dash0.init(
    Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      batchSize: 1,
      enabled: enabled,
      ignoreUrls: ignoreUrls,
      headersToCapture: [RegExp('^x-request-id\$', caseSensitive: false)],
      propagators: [
        Dash0Propagator.traceparent([RegExp(r'^https://api\.example\.com')]),
      ],
    ),
    transport: transport,
    sessionStore: MemoryStore(),
  );
  return transport;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => Dash0.shutdown());

  test('returns null before init', () {
    expect(Dash0.startHttpRequest('GET', 'https://api.example.com/'), isNull);
  });

  test('creates a client span with http attributes', () async {
    final transport = await init();
    final span =
        Dash0.startHttpRequest('post', 'https://api.example.com/a?b=1')!;
    final headers = span.propagationHeaders();
    expect(headers['traceparent'], isNotNull);
    span.captureHeaders({'X-Request-Id': 'r1'}, request: true);
    span.setResponse(201, contentLength: 12);
    span.finish();
    span.finish();
    await Dash0.flush();

    expect(transport.spans, hasLength(1));
    final s = transport.spans.single;
    expect(s['name'], 'HTTP POST');
    expect(s['kind'], 3);
    expect(attr(s, 'http.request.method'), 'POST');
    expect(attr(s, 'http.response.status_code'), '201');
    expect(attr(s, 'http.response.body.size'), '12');
    expect(attr(s, 'http.request.header.x-request-id'), 'r1');
    expect(attr(s, 'url.full'), contains('https://api.example.com/a'));
    expect(headers['traceparent'], contains(s['traceId'] as String));
    expect((s['status']! as Map)['code'], 0);
  });

  test('status 400 and above is an error', () async {
    final transport = await init();
    Dash0.startHttpRequest('GET', 'https://api.example.com/')!
      ..setResponse(503, reason: 'Service Unavailable')
      ..finish();
    await Dash0.flush();
    final s = transport.spans.single;
    expect((s['status']! as Map)['code'], 2);
    expect(attr(s, 'error.type'), '503');
  });

  test('failures record the error', () async {
    final transport = await init();
    Dash0.startHttpRequest('GET', 'https://api.example.com/')!.finish(
        error: StateError('socket closed'), stackTrace: StackTrace.current);
    await Dash0.flush();
    final s = transport.spans.single;
    expect((s['status']! as Map)['code'], 2);
    expect(attr(s, 'error.type'), 'StateError');
  });

  test('returns null when disabled or ignored', () async {
    final transport = await init(
      enabled: false,
      ignoreUrls: [RegExp('ignored')],
    );
    expect(Dash0.startHttpRequest('GET', 'https://api.example.com/'), isNull);
    Dash0.enabled = true;
    expect(Dash0.startHttpRequest('GET', 'https://x.com/ignored'), isNull);
    expect(
        Dash0.startHttpRequest('GET', 'https://api.example.com/'), isNotNull);
    expect(transport.spans, isEmpty);
  });
}
