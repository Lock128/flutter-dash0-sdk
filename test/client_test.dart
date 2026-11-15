import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Future<(Dash0Client, FakeTransport)> start({
  num sampling = 100,
  Map<String, Object?> signalAttributes = const {},
  int batchSize = 1,
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test-app',
      serviceVersion: '1.2.3',
      environment: 'test',
      endpoint: testEndpoint,
      sessionSamplingRate: sampling,
      additionalSignalAttributes: signalAttributes,
      batchSize: batchSize,
      resourceAttributes: const {'app.build': '42'},
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

  test('sends events as OTLP logs with resource, session and attributes',
      () async {
    final (client, transport) = await start(
      signalAttributes: {'tenant': 'acme'},
    );
    client.sendEvent(
      'checkout',
      title: 'Checkout done',
      data: 'ok',
      attributes: {'cart.size': 3},
      severity: Dash0Severity.warn,
    );
    await client.flush();

    expect(transport.sent.single.path, '/v1/logs');
    final resource = ((transport.sent.single.body['resourceLogs']! as List)
        .single as Map)['resource'] as Map<String, Object?>;
    expect(attr(resource, 'service.name'), 'test-app');
    expect(attr(resource, 'service.version'), '1.2.3');
    expect(attr(resource, 'deployment.environment.name'), 'test');
    expect(attr(resource, 'telemetry.sdk.language'), 'dart');
    expect(attr(resource, 'app.build'), '42');

    final log = transport.logs.single;
    expect(attr(log, 'event.name'), 'checkout');
    expect(attr(log, 'dash0.web.event.title'), 'Checkout done');
    expect(attr(log, 'session.id'), client.sessionId);
    expect(attr(log, 'tenant'), 'acme');
    expect(attr(log, 'cart.size'), '3');
    expect(log['severityText'], 'WARN');
    expect(log['severityNumber'], 13);
    expect(log['body'], {'stringValue': 'ok'});
  });

  test('rejects reserved event names', () async {
    final (client, transport) = await start();
    client.sendEvent(EventNames.pageView);
    await client.flush();
    expect(transport.logs, isEmpty);
  });

  test('batches signals until the batch size is reached', () async {
    final (client, transport) = await start(batchSize: 3);
    client.sendEvent('a');
    client.sendEvent('b');
    expect(transport.sent, isEmpty);
    client.sendEvent('c');
    await client.flush();
    expect(transport.sent, hasLength(1));
    expect(transport.logs, hasLength(3));
  });

  test('identify and signal attributes are added and can be cleared', () async {
    final (client, transport) = await start();
    client.identify('u1', email: 'a@example.com', roles: ['admin']);
    client.addSignalAttribute('plan', 'pro');
    client.sendEvent('one');
    client.identify(null);
    client.removeSignalAttribute('plan');
    client.sendEvent('two');
    await client.flush();

    final one = transport.logs[0];
    expect(attr(one, 'user.id'), 'u1');
    expect(attr(one, 'user.email'), 'a@example.com');
    expect(attr(one, 'user.roles'), isA<Map>());
    expect(attr(one, 'plan'), 'pro');
    final two = transport.logs[1];
    expect(attr(two, 'user.id'), isNull);
    expect(attr(two, 'plan'), isNull);
  });

  test('sessions sampled out send nothing', () async {
    final (client, transport) = await start(sampling: 0);
    expect(client.isSessionSampled, isFalse);
    client.sendEvent('x');
    client.startSpan('s').end();
    await client.flush();
    expect(transport.sent, isEmpty);
  });

  test('can be disabled and re-enabled at runtime', () async {
    final (client, transport) = await start();
    client.enabled = false;
    client.sendEvent('dropped');
    client.enabled = true;
    client.sendEvent('kept');
    await client.flush();
    expect(transport.logs.map((l) => attr(l, 'event.name')), ['kept']);
  });

  test('rate limits excessive usage', () async {
    final (client, transport) = await start();
    for (var i = 0; i < 300; i++) {
      client.sendEvent('e$i');
    }
    await client.flush();
    expect(transport.logs.length, 128);
  });

  test('spans carry ids, parent relations and exceptions', () async {
    final (client, transport) = await start();
    await client.trace<void>('outer', (outer) async {
      final child = client.startSpan('inner');
      expect(child.traceId, outer.traceId);
      expect(child.parentSpanId, outer.spanId);
      child.end();
    });
    await expectLater(
      client.trace<void>('failing', (_) => throw StateError('boom')),
      throwsStateError,
    );
    await client.flush();

    final spans = transport.spans;
    expect(spans.map((s) => s['name']), ['inner', 'outer', 'failing']);
    final inner = spans[0];
    final outer = spans[1];
    expect(inner['parentSpanId'], outer['spanId']);
    expect((outer['traceId']! as String), hasLength(32));
    expect((outer['spanId']! as String), hasLength(16));
    final failing = spans[2];
    expect((failing['status']! as Map)['code'], 2);
    expect((failing['events']! as List), isNotEmpty);
    expect(
      int.parse(failing['endTimeUnixNano']! as String),
      greaterThanOrEqualTo(int.parse(failing['startTimeUnixNano']! as String)),
    );
  });

  test('ending a span twice sends it once', () async {
    final (client, transport) = await start();
    final span = client.startSpan('once');
    span.end();
    span.end();
    await client.flush();
    expect(transport.spans, hasLength(1));
  });

  test('going to the background flushes immediately', () async {
    final (client, transport) = await start(batchSize: 10);
    client.sendEvent('queued');
    expect(transport.sent, isEmpty);
    await client.handleLifecycleState(AppLifecycleState.paused);
    final names = transport.logs.map((l) => attr(l, 'event.name')).toList();
    expect(names, containsAll(['queued', 'app.lifecycle']));
    // While in background nothing is held back.
    client.sendEvent('late');
    await client.flush();
    expect(
      transport.logs.map((l) => attr(l, 'event.name')),
      contains('late'),
    );
  });

  test('going to the background exports metrics', () async {
    final (client, transport) = await start(batchSize: 10);
    client.counter('app.test.count').add(3);
    expect(transport.metrics, isEmpty);
    await client.handleLifecycleState(AppLifecycleState.paused);
    expect(transport.metrics.map((m) => m['name']), contains('app.test.count'));
  });

  test('terminating the session exports metrics', () async {
    final (client, transport) = await start();
    client.counter('app.test.count').add(1);
    await client.terminateSession();
    expect(transport.metrics.map((m) => m['name']), contains('app.test.count'));
  });

  test('terminating the session changes the session id', () async {
    final (client, _) = await start();
    final before = client.sessionId;
    await client.terminateSession();
    expect(client.sessionId, isNot(before));
  });

  test('shutdown flushes and closes the transport', () async {
    final (client, transport) = await start(batchSize: 10);
    client.sendEvent('last');
    await client.shutdown();
    expect(transport.logs, hasLength(1));
    expect(transport.closed, isTrue);
    client.sendEvent('after');
    await client.flush();
    expect(transport.logs, hasLength(1));
  });

  test('Dash0 facade is a no-op before init and works after', () async {
    Dash0.sendEvent('ignored');
    Dash0.identify('x');
    expect(Dash0.isInitialized, isFalse);

    final transport = FakeTransport();
    await Dash0.init(
      const Dash0Options(
        serviceName: 'facade',
        endpoint: testEndpoint,
        batchSize: 1,
      ),
      transport: transport,
      sessionStore: MemoryStore(),
    );
    expect(Dash0.isInitialized, isTrue);
    Dash0.sendEvent('hello');
    await Dash0.flush();
    expect(transport.logs, hasLength(1));
    await Dash0.shutdown();
    expect(Dash0.isInitialized, isFalse);
  });

  test('invalid options throw from init', () async {
    await expectLater(
      Dash0.init(const Dash0Options(serviceName: '')),
      throwsArgumentError,
    );
    expect(Dash0.isInitialized, isFalse);
  });
}
