import 'dart:convert';

import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Future<(Dash0Client, FakeTransport)> start({
  num replayRate = 100,
  num sampling = 100,
  Dash0ReplayOptions replay = const Dash0ReplayOptions(),
  Set<Dash0Instrumentation>? only,
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      sessionSamplingRate: sampling,
      sessionReplaySamplingRate: replayRate,
      replay: replay,
      enabledInstrumentations: only,
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
  );
  return (client, transport);
}

Widget app(Dash0Client client, {Widget? extra}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Navigator(
        observers: [Dash0NavigatorObserver(client)],
        initialRoute: '/',
        onGenerateRoute: (settings) => PageRouteBuilder<void>(
          settings: settings,
          pageBuilder: (context, _, __) => settings.name == '/'
              ? Column(children: [
                  GestureDetector(
                    key: const Key('go'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).pushNamed('/details'),
                    child: const SizedBox(width: 100, height: 50),
                  ),
                  if (extra != null) extra,
                ])
              : const Text('details'),
        ),
      ),
    );

List<Map<String, Object?>> chunks(FakeTransport t) => [
      for (final l
          in t.logs.where((l) => attr(l, 'event.name') == 'app.session_replay'))
        jsonDecode(((l['body']! as Map)['stringValue']! as String))
            as Map<String, Object?>,
    ];

List<Map<String, Object?>> allEvents(FakeTransport t) => [
      for (final c in chunks(t))
        ...(c['events']! as List).cast<Map<String, Object?>>(),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a tap and a route change are recorded in order', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app(client));
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
    await client.shutdown();

    final records = transport.logs
        .where((l) => attr(l, 'event.name') == 'app.session_replay')
        .toList();
    expect(records, isNotEmpty);
    expect(attr(records.first, 'app.replay.sequence'), '0');
    final events = allEvents(transport);
    expect(events.map((e) => e['type']), ['navigation', 'tap', 'navigation']);
    expect(events[0]['screen'], '/');
    expect(events[2]['screen'], '/details');
    expect(events[2]['change'], 'push');
    final tap = events[1];
    expect(tap['x'], inInclusiveRange(0, 1));
    expect(tap['y'], inInclusiveRange(0, 1));
    expect(tap['target'], isA<String>());
    final chunk = chunks(transport).first;
    expect(chunk['session_id'], client.sessionId);
    expect(chunk['start_ts'], lessThanOrEqualTo(chunk['end_ts']! as int));
    expect(chunk['viewport'], isA<Map>());
  });

  testWidgets('sampling rate 0 records nothing, startReplay forces it',
      (tester) async {
    final (client, transport) = await start(replayRate: 0);
    await tester.pumpWidget(app(client));
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
    await client.flush();
    expect(chunks(transport), isEmpty);

    client.startReplay();
    await tester.tapAt(const Offset(300, 300));
    await tester.pump();
    client.stopReplay();
    await client.flush();
    expect(allEvents(transport).map((e) => e['type']), contains('tap'));
    await client.shutdown();
  });

  testWidgets('nothing is recorded when the session is not sampled',
      (tester) async {
    final (client, transport) = await start(sampling: 0);
    await tester.pumpWidget(app(client));
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
    await client.shutdown();
    expect(transport.sent, isEmpty);
  });

  testWidgets('nothing is recorded when the instrumentation is off',
      (tester) async {
    final (client, transport) = await start(only: {Dash0Instrumentation.error});
    expect(client.replay, isNull);
    await tester.pumpWidget(app(client));
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
    await client.shutdown();
    expect(chunks(transport), isEmpty);
  });

  testWidgets('text fields produce markers but never their values',
      (tester) async {
    final (client, transport) = await start();
    final controller = TextEditingController();
    final focus = FocusNode();
    await tester.pumpWidget(app(
      client,
      extra: EditableText(
        controller: controller,
        focusNode: focus,
        style: const TextStyle(),
        cursorColor: const Color(0xFF000000),
        backgroundCursorColor: const Color(0xFF000000),
        obscureText: true,
      ),
    ));
    await tester.enterText(find.byType(EditableText), 'my-secret-password');
    await tester.pump();
    focus.unfocus();
    await tester.pump();
    await client.shutdown();

    final types = allEvents(transport).map((e) => e['type']).toList();
    expect(
        types, containsAllInOrder(['text_focus', 'text_change', 'text_blur']));
    expect(
        allEvents(transport)
            .firstWhere((e) => e['type'] == 'text_focus')['obscured'],
        isTrue);
    final raw = jsonEncode(transport.logs);
    expect(raw, isNot(contains('my-secret-password')));
    controller.dispose();
    focus.dispose();
  });

  testWidgets('long presses and drags are classified', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app(client));
    final long = TestPointer(1);
    await tester.sendEventToBinding(long.down(const Offset(10, 10)));
    await tester.sendEventToBinding(
        long.up(timeStamp: const Duration(milliseconds: 800)));
    final drag = TestPointer(2);
    await tester.sendEventToBinding(drag.down(const Offset(10, 10)));
    await tester.sendEventToBinding(drag.move(const Offset(10, 200),
        timeStamp: const Duration(milliseconds: 50)));
    await tester.sendEventToBinding(
        drag.up(timeStamp: const Duration(milliseconds: 100)));
    await client.shutdown();
    final types = allEvents(transport).map((e) => e['type']).toList();
    expect(types, containsAllInOrder(['long_press', 'drag']));
    final press =
        allEvents(transport).firstWhere((e) => e['type'] == 'long_press');
    expect(press['duration_ms'], 800);
  });

  testWidgets('chunks are cut by event count with sequence numbers',
      (tester) async {
    final (client, transport) =
        await start(replay: const Dash0ReplayOptions(maxChunkEvents: 2));
    await tester.pumpWidget(app(client));
    for (var i = 0; i < 4; i++) {
      await tester.tapAt(const Offset(300, 300));
    }
    await client.shutdown();
    final cs = chunks(transport);
    expect(cs.map((c) => c['sequence']), [0, 1, 2]);
    expect(cs.first['events'], hasLength(2));
  });

  testWidgets('the chunk cap stops recording', (tester) async {
    final (client, transport) = await start(
        replay: const Dash0ReplayOptions(maxChunkEvents: 1, maxChunks: 2));
    await tester.pumpWidget(app(client));
    for (var i = 0; i < 5; i++) {
      await tester.tapAt(const Offset(300, 300));
    }
    await client.shutdown();
    expect(chunks(transport), hasLength(2));
  });

  testWidgets('pausing the app flushes the chunk', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app(client));
    await tester.tapAt(const Offset(300, 300));
    expect(chunks(transport), isEmpty);
    await client.handleLifecycleState(AppLifecycleState.paused);
    await client.flush();
    final events = allEvents(transport);
    expect(events.map((e) => e['type']), ['navigation', 'tap', 'lifecycle']);
    expect(events.last['state'], 'paused');
    await client.shutdown();
  });

  testWidgets('a new session starts again at sequence 0', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app(client));
    await tester.tapAt(const Offset(300, 300));
    final first = client.sessionId;
    await client.terminateSession();
    await tester.tapAt(const Offset(300, 300));
    await client.shutdown();
    final cs = chunks(transport);
    expect(cs.first['session_id'], first);
    expect(cs.last['session_id'], client.sessionId);
    expect(cs.last['sequence'], 0);
  });

  group('screenshots', () {
    testWidgets('mask rectangles cover Dash0Mask and text', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: const Column(children: [
            Text('secret'),
            Dash0Mask(child: SizedBox(width: 40, height: 30)),
            SizedBox(width: 10, height: 10),
          ]),
        ),
      ));
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final withText = ReplayRecorder.maskRects(boundary, maskAllText: true);
      final withoutText =
          ReplayRecorder.maskRects(boundary, maskAllText: false);
      expect(withText, hasLength(2));
      expect(withoutText, hasLength(1));
      expect(withoutText.single.size, const Size(40, 30));
    });

    testWidgets('a screenshot is recorded as base64 PNG', (tester) async {
      final (client, transport) = await start(
        replay:
            const Dash0ReplayOptions(screenshotInterval: Duration(seconds: 30)),
      );
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Dash0ReplayBoundary(
          client: client,
          child: const Column(children: [
            Text('secret'),
            Dash0Mask(child: SizedBox(width: 40, height: 30)),
          ]),
        ),
      ));
      await tester.runAsync(() => client.replay!.captureScreenshot());
      await client.shutdown();
      final shot =
          allEvents(transport).firstWhere((e) => e['type'] == 'screenshot');
      expect(shot['format'], 'png');
      expect(shot['masked_regions'], 2);
      final bytes = base64Decode(shot['data']! as String);
      expect(bytes.sublist(1, 4), 'PNG'.codeUnits);
    });

    testWidgets('no screenshot without a boundary', (tester) async {
      final (client, transport) = await start();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => client.replay!.captureScreenshot());
      await client.shutdown();
      expect(allEvents(transport), isEmpty);
    });
  });

  test('options are validated', () {
    expect(
      () => const Dash0Options(
        serviceName: 's',
        endpoint: testEndpoint,
        sessionReplaySamplingRate: 101,
      ).validate(),
      throwsArgumentError,
    );
    expect(
      () => const Dash0ReplayOptions(maxChunkEvents: 0).validate(),
      throwsArgumentError,
    );
    expect(
      () => const Dash0ReplayOptions(screenshotScale: 0).validate(),
      throwsArgumentError,
    );
    expect(
      () => const Dash0ReplayOptions(
              screenshotInterval: Duration(milliseconds: 10))
          .validate(),
      throwsArgumentError,
    );
    expect(
      () => const Dash0Options(serviceName: 's', endpoint: testEndpoint)
          .sessionReplaySamplingRate,
      returnsNormally,
    );
    expect(const Dash0Options(serviceName: 's').sessionReplaySamplingRate, 0);
  });
}
