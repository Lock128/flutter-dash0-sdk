import 'dart:async';

import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

// ignore_for_file: avoid_print

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DebugPrintCallback originalDebugPrint;
  late List<String> printed;

  setUp(() {
    originalDebugPrint = debugPrint;
    printed = [];
    debugPrint = (String? message, {int? wrapWidth}) => printed.add('$message');
  });

  tearDown(() async {
    await Dash0.shutdown();
    debugPrint = originalDebugPrint;
  });

  Future<FakeTransport> init({
    Set<Dash0Instrumentation>? enabled = const {Dash0Instrumentation.console},
    Dash0ConsoleOptions console = const Dash0ConsoleOptions(),
    UrlScrubber? scrubber,
    bool debug = false,
    num sampling = 100,
  }) async {
    final transport = FakeTransport();
    await Dash0.init(
      Dash0Options(
        serviceName: 'test',
        endpoint: testEndpoint,
        batchSize: 1,
        enabledInstrumentations: enabled,
        console: console,
        urlScrubber: scrubber,
        debug: debug,
        sessionSamplingRate: sampling,
      ),
      transport: transport,
      sessionStore: MemoryStore(),
    );
    return transport;
  }

  test('debugPrint is captured and still printed', () async {
    final transport = await init();
    debugPrint('hello');
    await Dash0.flush();
    expect(printed, ['hello']);
    final log = transport.logs.single;
    expect(attr(log, 'event.name'), 'browser.console');
    expect(attr(log, 'dash0.web.console.method'), 'log');
    expect(log['severityText'], 'INFO');
    expect(((log['body']! as Map)['stringValue']), 'hello');
  });

  test('nothing is captured unless console is listed', () async {
    final transport = await init(enabled: null);
    final original = debugPrint;
    debugPrint('hello');
    Dash0.runGuarded(() => print('x'));
    Dash0.log(Dash0ConsoleLevel.warn, 'w');
    await Dash0.flush();
    expect(identical(debugPrint, original), isTrue);
    expect(transport.logs, isEmpty);
  });

  test('shutdown restores debugPrint', () async {
    await init();
    final wrapped = debugPrint;
    await Dash0.shutdown();
    expect(identical(wrapped, debugPrint), isFalse);
    debugPrint('after');
    expect(printed, ['after']);
  });

  test('print inside runGuarded is captured and forwarded', () async {
    final transport = await init();
    final lines = <String>[];
    Dash0.runGuarded(() {
      runZoned(() => print('inner'),
          zoneSpecification: ZoneSpecification(
              print: (self, parent, zone, line) => lines.add(line)));
    });
    // The outer guarded zone captures print of its own body.
    Dash0.runGuarded(() => print('guarded'));
    await Dash0.flush();
    final bodies = [
      for (final l in transport.logs) (l['body']! as Map)['stringValue']
    ];
    expect(bodies, contains('guarded'));
    expect(lines, ['inner']);
  });

  test('print through debugPrint is captured once', () async {
    final transport = await init();
    debugPrint = originalDebugPrint;
    // Reinstall on top of the real debugPrint.
    await Dash0.shutdown();
    final t2 = await init();
    expect(transport, isNot(same(t2)));
    Dash0.runGuarded(() {
      debugPrint('once');
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await Dash0.flush();
    final bodies = [
      for (final l in t2.logs) (l['body']! as Map)['stringValue']
    ];
    expect(bodies.where((b) => b == 'once'), hasLength(1));
  });

  test('Dash0.log maps levels to severities and adds exception attributes',
      () async {
    final transport = await init();
    final severities = {
      Dash0ConsoleLevel.log: 'INFO',
      Dash0ConsoleLevel.info: 'INFO',
      Dash0ConsoleLevel.warn: 'WARN',
      Dash0ConsoleLevel.error: 'ERROR',
      Dash0ConsoleLevel.debug: 'DEBUG',
      Dash0ConsoleLevel.trace: 'DEBUG',
    };
    for (final level in severities.keys) {
      Dash0.log(level, 'm ${level.name}');
    }
    Dash0.log(Dash0ConsoleLevel.error, 'failed',
        error: StateError('bad'), stackTrace: StackTrace.fromString('#0 f'));
    await Dash0.flush();
    final logs = transport.logs;
    for (var i = 0; i < severities.length; i++) {
      final level = severities.keys.elementAt(i);
      expect(attr(logs[i], 'dash0.web.console.method'), level.name);
      expect(logs[i]['severityText'], severities[level]);
    }
    final trace = logs[5];
    expect(attr(trace, 'code.stacktrace'), isNotNull);
    expect(attr(logs[0], 'code.stacktrace'), isNull);
    final err = logs.last;
    expect(attr(err, 'exception.type'), 'StateError');
    expect(attr(err, 'exception.message'), contains('bad'));
    expect(attr(err, 'exception.stacktrace'), '#0 f');
  });

  test('long messages are cut with an ellipsis after url scrubbing', () async {
    final transport = await init(
      console: const Dash0ConsoleOptions(maxMessageLength: 20),
    );
    Dash0.log(Dash0ConsoleLevel.log, 'x' * 50);
    Dash0.log(Dash0ConsoleLevel.log, 'a https://u:p@example.com/q');
    await Dash0.flush();
    expect((transport.logs[0]['body']! as Map)['stringValue'],
        '${'x' * 20}\u2026');
    expect((transport.logs[1]['body']! as Map)['stringValue'],
        'a https://REDACTED:R\u2026');
  });

  test('urls go through the scrubber before the cut', () async {
    final transport = await init(
      scrubber: (u) => u.replaceAll('secret', 'S'),
      console: const Dash0ConsoleOptions(maxMessageLength: 30),
    );
    Dash0.log(Dash0ConsoleLevel.log, 'go https://e.com/secret/secret');
    await Dash0.flush();
    expect((transport.logs.single['body']! as Map)['stringValue'],
        'go https://e.com/S/S');
  });

  test('ignoreMessages and an empty message drop the event', () async {
    final transport = await init(
      console: Dash0ConsoleOptions(ignoreMessages: ['noisy', RegExp('^x+\$')]),
    );
    Dash0.log(Dash0ConsoleLevel.log, 'very noisy thing');
    Dash0.log(Dash0ConsoleLevel.log, 'xxx');
    Dash0.log(Dash0ConsoleLevel.log, '');
    Dash0.log(Dash0ConsoleLevel.log, 'keep');
    await Dash0.flush();
    expect(transport.logs, hasLength(1));
  });

  test('captureDebugPrint false leaves debugPrint alone', () async {
    final transport = await init(
      console: const Dash0ConsoleOptions(captureDebugPrint: false),
    );
    debugPrint('hello');
    await Dash0.flush();
    expect(transport.logs, isEmpty);
  });

  test('sending budget of 50 per 10 seconds', () async {
    final transport = await init();
    for (var i = 0; i < 80; i++) {
      Dash0.log(Dash0ConsoleLevel.log, 'm$i');
    }
    await Dash0.flush();
    expect(transport.logs, hasLength(50));
  });

  test('the console budget is separate from the shared log budget', () async {
    final transport = await init();
    for (var i = 0; i < 50; i++) {
      Dash0.log(Dash0ConsoleLevel.log, 'm$i');
    }
    for (var i = 0; i < 100; i++) {
      Dash0.sendEvent('custom.$i');
    }
    await Dash0.flush();
    expect(transport.logs, hasLength(150));
  });

  test('the SDK debug output is not captured', () async {
    final transport = await init(debug: true);
    Dash0.log(Dash0ConsoleLevel.log, 'hello');
    await Dash0.flush();
    expect(printed.any((l) => l.startsWith('[dash0]')), isTrue);
    for (final l in transport.logs) {
      expect(((l['body']! as Map)['stringValue'] as String),
          isNot(startsWith('[dash0]')));
    }
  });

  test('console is a reserved event name', () async {
    final transport = await init();
    Dash0.sendEvent('browser.console', data: 'x');
    await Dash0.flush();
    expect(transport.logs, isEmpty);
  });

  test('legacy names use app.console', () async {
    final transport = FakeTransport();
    await Dash0.init(
      const Dash0Options(
        serviceName: 'test',
        endpoint: testEndpoint,
        batchSize: 1,
        legacyAppNames: true,
        enabledInstrumentations: {Dash0Instrumentation.console},
      ),
      transport: transport,
      sessionStore: MemoryStore(),
    );
    Dash0.log(Dash0ConsoleLevel.log, 'x');
    await Dash0.flush();
    expect(attr(transport.logs.single, 'event.name'), 'app.console');
  });

  test('sampled out sessions send nothing', () async {
    final transport = await init(sampling: 0);
    Dash0.log(Dash0ConsoleLevel.log, 'x');
    await Dash0.flush();
    expect(transport.logs, isEmpty);
  });

  test('disabled clients send nothing', () async {
    final transport = await init();
    Dash0.enabled = false;
    Dash0.log(Dash0ConsoleLevel.log, 'x');
    await Dash0.flush();
    expect(transport.logs, isEmpty);
  });
}
