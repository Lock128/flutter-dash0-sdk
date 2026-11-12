import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  final t0 = DateTime(2024);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  group('RageClickDetector', () {
    test('three taps in radius and window trigger once', () {
      final d = RageClickDetector();
      expect(d.onTap(const Offset(10, 10), at(0)), isNull);
      expect(d.onTap(const Offset(12, 14), at(200)), isNull);
      final hit = d.onTap(const Offset(11, 11), at(400));
      expect(hit, isNotNull);
      expect(hit!.count, 3);
      // Burst continues: no further events.
      expect(d.onTap(const Offset(11, 11), at(500)), isNull);
      expect(d.onTap(const Offset(11, 11), at(600)), isNull);
    });

    test('spread taps do not trigger', () {
      final d = RageClickDetector();
      expect(d.onTap(const Offset(0, 0), at(0)), isNull);
      expect(d.onTap(const Offset(200, 0), at(100)), isNull);
      expect(d.onTap(const Offset(400, 0), at(200)), isNull);
    });

    test('slow taps do not trigger', () {
      final d = RageClickDetector();
      expect(d.onTap(const Offset(0, 0), at(0)), isNull);
      expect(d.onTap(const Offset(0, 0), at(900)), isNull);
      expect(d.onTap(const Offset(0, 0), at(1800)), isNull);
    });

    test('a new burst after a pause triggers again', () {
      final d = RageClickDetector(tapCount: 2);
      d.onTap(Offset.zero, at(0));
      expect(d.onTap(Offset.zero, at(100)), isNotNull);
      expect(d.onTap(Offset.zero, at(3000)), isNull);
      expect(d.onTap(Offset.zero, at(3100)), isNotNull);
    });
  });

  Future<(Dash0Client, FakeTransport)> start({
    Set<Dash0Instrumentation>? only,
    bool enabled = true,
    num sampling = 100,
    Dash0RageClickOptions rage = const Dash0RageClickOptions(),
  }) async {
    final transport = FakeTransport();
    final client = await Dash0Client.start(
      Dash0Options(
        serviceName: 'test',
        endpoint: testEndpoint,
        enabledInstrumentations: only,
        enabled: enabled,
        sessionSamplingRate: sampling,
        rageClicks: rage,
      ),
      transport: transport,
      sessionStore: MemoryStore(),
      installErrorHandlers: false,
      observeLifecycle: false,
    );
    return (client, transport);
  }

  Widget app() => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: GestureDetector(
            key: const Key('btn'),
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: const SizedBox(width: 100, height: 50),
          ),
        ),
      );

  List<Map<String, Object?>> events(FakeTransport t, String name) =>
      t.logs.where((l) => attr(l, 'event.name') == name).toList();

  testWidgets('three quick taps produce exactly one app.rage_click',
      (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app());
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('btn')));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.byKey(const Key('btn')));
    await client.flush();
    final rage = events(transport, 'app.rage_click');
    expect(rage, hasLength(1));
    expect(attr(rage.single, 'app.click.count'), '3');
    expect(attr(rage.single, 'app.click.target'), isA<String>());
    expect(attr(rage.single, 'app.click.x'), isA<String>());
    await client.shutdown();
  });

  testWidgets('drags are not counted as taps', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app());
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byKey(const Key('btn')), const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await client.flush();
    expect(events(transport, 'app.rage_click'), isEmpty);
    await client.shutdown();
  });

  testWidgets('nothing recorded when disabled, unsampled or not listed',
      (tester) async {
    await tester.pumpWidget(app());
    for (final cfg in [
      (null, false, 100),
      (null, true, 0),
      ({Dash0Instrumentation.error}, true, 100),
    ]) {
      final (client, transport) =
          await start(only: cfg.$1, enabled: cfg.$2, sampling: cfg.$3);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const Key('btn')));
      }
      await client.flush();
      expect(events(transport, 'app.rage_click'), isEmpty);
      await client.shutdown();
    }
  });

  testWidgets('dead taps are opt in', (tester) async {
    final (client, transport) =
        await start(rage: const Dash0RageClickOptions(enableDeadTaps: true));
    await tester.pumpWidget(app());
    await tester.tapAt(const Offset(5, 5));
    await tester.tap(find.byKey(const Key('btn')));
    await client.flush();
    expect(events(transport, 'app.dead_tap'), hasLength(1));
    await client.shutdown();
  });
}
