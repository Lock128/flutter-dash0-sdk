import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Future<(Dash0Client, FakeTransport)> start({
  Dash0AggregationTemporality temporality = Dash0AggregationTemporality.delta,
  Duration interval = const Duration(seconds: 30),
  num sampling = 100,
  bool enabled = true,
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      metricTemporality: temporality,
      metricExportInterval: interval,
      sessionSamplingRate: sampling,
      enabled: enabled,
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
  );
  return (client, transport);
}

Map<String, Object?> point(Map<String, Object?> metric, String kind,
        [int i = 0]) =>
    ((metric[kind]! as Map)['dataPoints'] as List)[i] as Map<String, Object?>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('counter sends an OTLP sum to /v1/metrics', () async {
    final (client, transport) = await start();
    client.counter('x', unit: '1', description: 'things').add(1);
    await client.flush();

    expect(transport.sent.single.path, '/v1/metrics');
    final body = transport.sent.single.body;
    expect(body['resourceMetrics'], isNotEmpty);
    final metric = transport.metrics.single;
    expect(metric['name'], 'x');
    expect(metric['unit'], '1');
    expect(metric['description'], 'things');
    final sum = metric['sum']! as Map;
    expect(sum['isMonotonic'], isTrue);
    expect(sum['aggregationTemporality'], 1);
    final p = point(metric, 'sum');
    expect(p['asInt'], '1');
    expect(p['startTimeUnixNano'], isA<String>());
    expect(p['timeUnixNano'], isA<String>());
    await client.shutdown();
  });

  test('delta temporality resets after export, cumulative keeps totals',
      () async {
    final (delta, dt) = await start();
    final c = delta.counter('d');
    c.add(2, attributes: {'k': 'a'});
    c.add(3, attributes: {'k': 'a'});
    c.add(5, attributes: {'k': 'b'});
    await delta.flush();
    final points = (dt.metrics.single['sum']! as Map)['dataPoints'] as List;
    expect(points, hasLength(2));
    expect((points[0] as Map)['asInt'], '5');
    expect(attr(points[0] as Map<String, Object?>, 'k'), 'a');
    await delta.flush();
    expect(dt.metrics, hasLength(1), reason: 'nothing new to export');
    c.add(1, attributes: {'k': 'a'});
    await delta.flush();
    expect(dt.metrics, hasLength(2));
    await delta.shutdown();

    final (cum, ct) =
        await start(temporality: Dash0AggregationTemporality.cumulative);
    final cc = cum.counter('c');
    cc.add(2);
    await cum.flush();
    cc.add(3);
    await cum.flush();
    expect(point(ct.metrics[0], 'sum')['asInt'], '2');
    expect(point(ct.metrics[1], 'sum')['asInt'], '5');
    expect((ct.metrics[1]['sum']! as Map)['aggregationTemporality'], 2);
    await cum.shutdown();
  });

  test('counter ignores negative values, up down counter does not', () async {
    final (client, transport) = await start();
    client.counter('c').add(-1);
    final u = client.upDownCounter('u');
    u.add(2);
    u.add(-1.5);
    await client.flush();
    expect(transport.metrics.map((m) => m['name']), ['u']);
    final sum = transport.metrics.single['sum']! as Map;
    expect(sum['isMonotonic'], isFalse);
    expect(point(transport.metrics.single, 'sum')['asDouble'], 0.5);
    await client.shutdown();
  });

  test('histogram aggregates count, sum, min, max and buckets', () async {
    final (client, transport) = await start();
    final h = client.histogram('h', unit: 's', boundaries: [1, 5]);
    h.record(0.5);
    h.record(1);
    h.record(3);
    h.record(10);
    await client.flush();
    final p = point(transport.metrics.single, 'histogram');
    expect(p['count'], '4');
    expect(p['sum'], 14.5);
    expect(p['min'], 0.5);
    expect(p['max'], 10);
    expect(p['bucketCounts'], ['2', '1', '1']);
    expect(p['explicitBounds'], [1, 5]);
    await client.shutdown();
  });

  test('gauge exports the latest value', () async {
    final (client, transport) = await start();
    final g = client.gauge('g');
    g.record(1);
    g.record(7);
    await client.flush();
    expect(point(transport.metrics.single, 'gauge')['asInt'], '7');
    await client.flush();
    expect(transport.metrics, hasLength(1));
    await client.shutdown();
  });

  test('same name returns the same instrument', () async {
    final (client, _) = await start();
    expect(identical(client.counter('a'), client.counter('a')), isTrue);
    await client.shutdown();
  });

  test('limits the number of attribute sets per instrument', () async {
    final (client, _) = await start();
    final c = client.counter('many');
    for (var i = 0; i < maxSeriesPerInstrument + 10; i++) {
      c.add(1, attributes: {'i': i});
    }
    expect(c.seriesCount, maxSeriesPerInstrument);
    await client.shutdown();
  });

  test('exports periodically and stops on shutdown', () {
    fakeAsync((async) {
      late Dash0Client client;
      late FakeTransport transport;
      start(interval: const Duration(seconds: 5)).then((r) {
        client = r.$1;
        transport = r.$2;
      });
      async.flushMicrotasks();
      client.counter('p').add(1);
      async.elapse(const Duration(seconds: 4));
      expect(transport.metrics, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(transport.metrics, hasLength(1));
      client.counter('p').add(1);
      client.shutdown();
      async.flushMicrotasks();
      expect(transport.metrics, hasLength(2));
      async.elapse(const Duration(seconds: 30));
      expect(transport.metrics, hasLength(2));
    });
  });

  test('records nothing when disabled or sampled out', () async {
    final (off, offT) = await start(enabled: false);
    off.counter('x').add(1);
    await off.flush();
    expect(offT.sent, isEmpty);

    final (out, outT) = await start(sampling: 0);
    out.counter('x').add(1);
    await out.flush();
    expect(outT.sent, isEmpty);
  });

  test('metrics instrumentation gates only automatic metrics', () async {
    final transport = FakeTransport();
    final client = await Dash0Client.start(
      const Dash0Options(
        serviceName: 'test',
        endpoint: testEndpoint,
        enabledInstrumentations: {Dash0Instrumentation.http},
      ),
      transport: transport,
      sessionStore: MemoryStore(),
      installErrorHandlers: false,
      observeLifecycle: false,
    );
    client.recordHttpClientDuration(0.1, {});
    client.counter('manual').add(1);
    await client.flush();
    expect(transport.metrics.map((m) => m['name']), ['manual']);
    await client.shutdown();
  });

  test('facade returns no-op instruments before init', () {
    Dash0.counter('x').add(1);
    Dash0.upDownCounter('x').add(1);
    Dash0.histogram('x').record(1);
    Dash0.gauge('x').record(1);
  });

  test('validates metricExportInterval', () {
    expect(
      () => const Dash0Options(
        serviceName: 's',
        endpoint: testEndpoint,
        metricExportInterval: Duration(milliseconds: 10),
      ).validate(),
      throwsArgumentError,
    );
  });
}
