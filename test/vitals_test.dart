import 'dart:ui' show FrameTiming;

import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Duration ms(num v) => Duration(microseconds: (v * 1000).round());

Future<(Dash0Client, FakeTransport)> start({
  Set<Dash0Instrumentation>? only,
  bool enabled = true,
  num sampling = 100,
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      enabledInstrumentations: only,
      enabled: enabled,
      sessionSamplingRate: sampling,
      metricTemporality: Dash0AggregationTemporality.cumulative,
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
  );
  return (client, transport);
}

void screen(Dash0Client c, String name) => Dash0NavigatorObserver(c).didPush(
    PageRouteBuilder<void>(
        settings: RouteSettings(name: name),
        pageBuilder: (_, __, ___) => const SizedBox()),
    null);

void frame(Dash0Client c, num build, num raster, num total) => c.vitals!
    .processFrame(build: ms(build), raster: ms(raster), total: ms(total));

Map<String, Object?> metric(FakeTransport t, String name) =>
    t.metrics.lastWhere((m) => m['name'] == name);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('slow and frozen frames increment counters in /v1/metrics', () async {
    final (client, transport) = await start();
    frame(client, 5, 5, 10);
    frame(client, 10, 10, 20);
    frame(client, 100, 10, 800);
    await client.flush();
    final slow = metric(transport, 'app.frame.slow');
    expect(((slow['sum']! as Map)['dataPoints'] as List).single['asInt'], '2');
    final frozen = metric(transport, 'app.frame.frozen');
    expect(
        ((frozen['sum']! as Map)['dataPoints'] as List).single['asInt'], '1');
    final build = metric(transport, 'app.frame.build.duration');
    expect(
        (((build['histogram']! as Map)['dataPoints'] as List).single
            as Map)['count'],
        '3');
    expect(transport.metrics.map((m) => m['name']),
        contains('app.start.duration'));
    await client.shutdown();
  });

  test('FrameTiming values are mapped', () async {
    final (client, transport) = await start();
    client.vitals!.onTimings([
      FrameTiming(
        vsyncStart: 0,
        buildStart: 0,
        buildFinish: 30000,
        rasterStart: 30000,
        rasterFinish: 50000,
        rasterFinishWallTime: 50000,
      ),
    ]);
    await client.flush();
    final slow = metric(transport, 'app.frame.slow');
    expect(((slow['sum']! as Map)['dataPoints'] as List).single['asInt'], '1');
    await client.shutdown();
  });

  test('app.vitals is sent on screen change with frame and interaction stats',
      () async {
    final (client, transport) = await start();
    screen(client, 'home');
    frame(client, 5, 5, 10);
    frame(client, 20, 5, 25);
    client.vitals!.markInteraction();
    frame(client, 5, 5, 10);
    screen(client, 'detail');
    await client.flush();
    final v = transport.logs
        .where((l) => attr(l, 'event.name') == 'app.vitals')
        .toList();
    expect(v, hasLength(1));
    expect(attr(v.single, 'app.screen.name'), 'home');
    expect(attr(v.single, 'app.vitals.frames_total'), '3');
    expect(attr(v.single, 'app.vitals.frames_slow'), '1');
    expect(attr(v.single, 'app.vitals.frames_frozen'), '0');
    expect(attr(v.single, 'app.vitals.interactions'), '1');
    expect(attr(v.single, 'app.vitals.interaction_p98_ms'), isNotNull);
    expect(attr(v.single, 'app.vitals.ttff_ms'), isNotNull);
    expect(attr(v.single, 'app.vitals.trigger'), 'screen_change');
    await client.shutdown();
  });

  test('app.vitals is sent when the app goes to the background', () async {
    final (client, transport) = await start();
    frame(client, 5, 5, 10);
    await client.handleLifecycleState(AppLifecycleState.paused);
    await client.flush();
    final v = transport.logs
        .where((l) => attr(l, 'event.name') == 'app.vitals')
        .toList();
    expect(attr(v.single, 'app.vitals.trigger'), 'background');
    await client.shutdown();
  });

  test('percentile uses nearest rank', () {
    expect(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 98), 10);
    expect(percentile([5], 98), 5);
    expect(percentile([1, 2, 3, 4], 50), 2);
  });

  test('records nothing when not listed, disabled or unsampled', () async {
    for (final cfg in [
      ({Dash0Instrumentation.error}, true, 100),
      (null, false, 100),
      (null, true, 0),
    ]) {
      final (client, transport) =
          await start(only: cfg.$1, enabled: cfg.$2, sampling: cfg.$3);
      if (client.vitals != null) {
        frame(client, 100, 100, 900);
        client.vitals!.flushScreen('background');
      }
      await client.flush();
      expect(transport.sent, isEmpty);
      await client.shutdown();
    }
  });

  test('options are validated', () {
    expect(
      () => const Dash0Options(
        serviceName: 's',
        endpoint: testEndpoint,
        rageClicks: Dash0RageClickOptions(tapCount: 1),
      ).validate(),
      throwsArgumentError,
    );
    expect(
      () => const Dash0Options(
        serviceName: 's',
        endpoint: testEndpoint,
        vitals: Dash0VitalsOptions(
            slowFrameThreshold: Duration(seconds: 1),
            frozenFrameThreshold: Duration(milliseconds: 10)),
      ).validate(),
      throwsArgumentError,
    );
  });
}
