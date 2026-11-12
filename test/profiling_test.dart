import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Future<(Dash0Client, FakeTransport)> start({
  Dash0ProfilingOptions profiling = const Dash0ProfilingOptions(),
  Set<Dash0Instrumentation>? only,
  num sampling = 100,
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      profiling: profiling,
      sessionSamplingRate: sampling,
      enabledInstrumentations: only,
      metricTemporality: Dash0AggregationTemporality.cumulative,
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
  );
  return (client, transport);
}

List<Map<String, Object?>> longTasks(FakeTransport t) =>
    t.logs.where((l) => attr(l, 'event.name') == 'app.long_task').toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LongTaskMonitor', () {
    final t0 = DateTime.utc(2025, 1, 1);
    const beat = Duration(milliseconds: 100);

    test('reports a stall above the threshold with its duration', () async {
      final (client, transport) = await start();
      final monitor = LongTaskMonitor(client, clock: () => t0)
        ..install(startTimer: false);
      client.currentScreen = '/home';
      monitor.tick(t0 + beat);
      monitor.tick(t0 + beat + beat + const Duration(milliseconds: 400));
      await client.flush();
      final events = longTasks(transport);
      expect(events, hasLength(1));
      expect(attr(events.single, 'app.long_task.duration_ms'), 400.0);
      expect(attr(events.single, 'app.long_task.anr'), false);
      expect(attr(events.single, 'app.long_task.source'), 'heartbeat');
      expect(attr(events.single, 'app.screen.name'), '/home');
      final metric = transport.metrics
          .singleWhere((m) => m['name'] == 'app.long_task.duration');
      expect(metric, isNotNull);
      monitor.uninstall();
    });

    test('ignores stalls below the threshold', () async {
      final (client, transport) = await start();
      final monitor = LongTaskMonitor(client, clock: () => t0)
        ..install(startTimer: false);
      var now = t0;
      for (var i = 0; i < 20; i++) {
        now += beat + const Duration(milliseconds: 200);
        monitor.tick(now);
      }
      await client.flush();
      expect(longTasks(transport), isEmpty);
    });

    test('flags stalls reaching the ANR threshold', () async {
      final (client, transport) = await start();
      final monitor = LongTaskMonitor(client, clock: () => t0)
        ..install(startTimer: false);
      monitor.tick(t0 + beat);
      monitor.tick(t0 + beat + beat + const Duration(seconds: 6));
      await client.flush();
      expect(attr(longTasks(transport).single, 'app.long_task.anr'), true);
    });

    test('pause suspends detection', () async {
      final (client, transport) = await start();
      final monitor = LongTaskMonitor(client, clock: () => t0)
        ..install(startTimer: false);
      monitor.pause();
      monitor.tick(t0 + const Duration(hours: 1));
      await client.flush();
      expect(longTasks(transport), isEmpty);
    });

    test('does not report for unsampled sessions', () async {
      final (client, transport) = await start(sampling: 0);
      final monitor = LongTaskMonitor(client, clock: () => t0)
        ..install(startTimer: false);
      monitor.tick(t0 + const Duration(seconds: 2));
      await client.flush();
      expect(transport.sent, isEmpty);
    });

    test('the real timer and watchdog isolate start and stop cleanly',
        () async {
      final (client, _) = await start(
        profiling: const Dash0ProfilingOptions(
            heartbeatInterval: Duration(milliseconds: 20)),
        only: {Dash0Instrumentation.profiling},
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await client.shutdown();
    });
  });

  group('RuntimeSampler', () {
    test('records memory, image cache and frame gauges', () async {
      final (client, transport) = await start();
      final sampler = RuntimeSampler(client)..sample();
      await client.flush();
      final names = transport.metrics.map((m) => m['name']).toSet();
      expect(
          names,
          containsAll([
            'process.runtime.dart.memory.rss',
            'app.image_cache.size',
            'app.image_cache.count',
            'app.runtime.frames',
            'app.runtime.frames.slow',
            'app.runtime.frames.frozen',
          ]));
      final rss = transport.metrics
          .firstWhere((m) => m['name'] == 'process.runtime.dart.memory.rss');
      expect(rss['gauge'], isNotNull);
      sampler.uninstall();
    });

    test('is only installed with an interval and the profiling flag', () async {
      final (off, _) = await start(only: {Dash0Instrumentation.profiling});
      await off.shutdown();
      final (on, transport) = await start(
        profiling: const Dash0ProfilingOptions(
            runtimeSampleInterval: Duration(seconds: 1)),
        only: {Dash0Instrumentation.profiling},
      );
      await on.shutdown();
      expect(transport.closed, isTrue);
    });
  });

  group('profile', () {
    test('sends a span with frame and RSS attributes', () async {
      final (client, transport) = await start();
      final result = await client.profile('x', (span) async {
        client.vitals!.processFrame(
          build: const Duration(milliseconds: 5),
          raster: const Duration(milliseconds: 5),
          total: const Duration(milliseconds: 30),
        );
        return 42;
      });
      await client.flush();
      expect(result, 42);
      final span = transport.spans.singleWhere((s) => s['name'] == 'x');
      expect(attr(span, 'profile.frames'), '1');
      expect(attr(span, 'profile.frames.slow'), '1');
      expect(attr(span, 'profile.frames.frozen'), '0');
      expect(attr(span, 'profile.duration_ms'), isA<double>());
      expect(attr(span, 'profile.rss.delta'), isA<String>());
      expect(attr(span, 'profile.rss.start'), isA<String>());
      final events = (span['events']! as List).cast<Map>();
      expect(events.map((e) => e['name']),
          ['profile.stack.start', 'profile.stack.end']);
    });

    test('records errors and rethrows', () async {
      final (client, transport) = await start();
      await expectLater(
        client.profile<void>('boom', (span) => throw StateError('x')),
        throwsStateError,
      );
      await client.flush();
      final span = transport.spans.single;
      expect((span['status']! as Map)['code'], 2);
      expect(attr(span, 'profile.duration_ms'), isA<double>());
    });

    test('Dash0.profile runs the body without a client', () async {
      expect(await Dash0.profile('x', (span) => span == null), isTrue);
    });
  });
}

extension on DateTime {
  DateTime operator +(Duration d) => add(d);
}
