import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const traceId = '4efaaf4d1e8720b39541901950019ee5';
  const spanId = '0123456789abcdef';

  Future<(Dash0Client, FakeTransport)> start() async {
    final transport = FakeTransport();
    final client = await Dash0Client.start(
      const Dash0Options(
          serviceName: 'test', endpoint: testEndpoint, batchSize: 1),
      transport: transport,
      sessionStore: MemoryStore(),
      installErrorHandlers: false,
      observeLifecycle: false,
    );
    return (client, transport);
  }

  test('root spans join the parent trace', () async {
    final (client, transport) = await start();
    client.setParentTraceContext('00-$traceId-$spanId-01');
    client.startSpan('a').end();
    await client.flush();
    final span = transport.spans.single;
    expect(span['traceId'], traceId);
    expect(span['parentSpanId'], spanId);
  });

  test('spans inside trace keep using the current span', () async {
    final (client, transport) = await start();
    client.setParentTraceContext('00-$traceId-$spanId-01');
    late Dash0Span outer;
    await client.trace('outer', (s) async {
      outer = s;
      client.startSpan('inner').end();
    });
    await client.flush();
    final inner = transport.spans.firstWhere((s) => s['name'] == 'inner');
    expect(inner['traceId'], traceId);
    expect(inner['parentSpanId'], outer.spanId);
  });

  test('invalid values are ignored and null clears', () async {
    final (client, transport) = await start();
    client.setParentTraceContext('00-$traceId-$spanId-01');
    client.setParentTraceContext('garbage');
    client.setParentTraceContext('00-${'0' * 32}-$spanId-01');
    client.startSpan('a').end();
    client.setParentTraceContext(null);
    client.startSpan('b').end();
    await client.flush();
    final a = transport.spans.firstWhere((s) => s['name'] == 'a');
    final b = transport.spans.firstWhere((s) => s['name'] == 'b');
    expect(a['traceId'], traceId);
    expect(b['traceId'], isNot(traceId));
    expect(b['parentSpanId'] ?? '', isEmpty);
  });

  test('the Dash0 facade forwards', () async {
    final transport = FakeTransport();
    await Dash0.init(
      const Dash0Options(
          serviceName: 'test', endpoint: testEndpoint, batchSize: 1),
      transport: transport,
      sessionStore: MemoryStore(),
    );
    Dash0.setParentTraceContext('00-$traceId-$spanId-01');
    Dash0.startSpan('a')!.end();
    await Dash0.flush();
    expect(transport.spans.single['traceId'], traceId);
    await Dash0.shutdown();
  });
}
