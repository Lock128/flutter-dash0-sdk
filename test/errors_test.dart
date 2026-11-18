import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:dash0_flutter_sdk/src/ignore_rules.dart';
import 'package:dash0_flutter_sdk/src/instrumentation/errors.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Future<(Dash0Client, FakeTransport)> start({
  bool install = false,
  List<RegExp> ignoreErrors = const [],
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      batchSize: 1,
      ignoreErrorMessages: ignoreErrors,
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: install,
    observeLifecycle: false,
  );
  return (client, transport);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('errors while disabled do not use up the cap or dedupe window',
      () async {
    final (client, transport) = await start();
    client.enabled = false;
    for (var i = 0; i < 150; i++) {
      client.reportError('same');
      client.reportError('error $i');
    }
    client.enabled = true;
    client.reportError('same');
    await client.flush();
    expect(transport.logs, hasLength(1));
    expect(attr(transport.logs.single, 'exception.message'), 'same');
  });

  test('Dash0Options.enabled false starts the client disabled', () async {
    final transport = FakeTransport();
    final client = await Dash0Client.start(
      const Dash0Options(
        serviceName: 'test',
        endpoint: testEndpoint,
        batchSize: 1,
        enabled: false,
      ),
      transport: transport,
      sessionStore: MemoryStore(),
      installErrorHandlers: false,
      observeLifecycle: false,
    );
    expect(client.isEnabled, isFalse);
    client.reportError('early');
    client.enabled = true;
    client.reportError('later');
    await client.flush();
    expect(transport.logs, hasLength(1));
    expect(attr(transport.logs.single, 'exception.message'), 'later');
  });

  test('reportError sends a browser.error event with exception attributes',
      () async {
    final (client, transport) = await start();
    client.reportError(
      StateError('bad state'),
      stackTrace: StackTrace.fromString('#0 main (file:///a.dart:1:1)'),
    );
    await client.flush();
    final log = transport.logs.single;
    expect(attr(log, 'event.name'), 'browser.error');
    expect(attr(log, 'exception.type'), 'StateError');
    expect(attr(log, 'exception.message'), contains('bad state'));
    expect(attr(log, 'exception.stacktrace'), contains('main'));
    expect(log['severityText'], 'ERROR');
  });

  test('ignores errors matching ignoreErrorMessages', () async {
    final (client, transport) = await start(ignoreErrors: [RegExp('noisy')]);
    client.reportError('a noisy failure');
    client.reportError('a real failure');
    await client.flush();
    expect(transport.logs, hasLength(1));
    expect(attr(transport.logs.single, 'exception.message'), 'a real failure');
  });

  test('identical errors in a short time are reported once', () async {
    final (client, transport) = await start();
    for (var i = 0; i < 5; i++) {
      client.reportError('same');
    }
    await client.flush();
    expect(transport.logs, hasLength(1));
  });

  test('caps the number of reported errors', () async {
    final (client, transport) = await start();
    for (var i = 0; i < 150; i++) {
      client.reportError('error $i');
    }
    await client.flush();
    expect(transport.logs, hasLength(100));
  });

  test('installs FlutterError and platform handlers and chains them', () async {
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    var previousCalled = 0;
    FlutterError.onError = (_) => previousCalled++;
    var platformCalled = 0;
    PlatformDispatcher.instance.onError = (e, s) {
      platformCalled++;
      return true;
    };

    final (client, transport) = await start(install: true);
    FlutterError.onError!(FlutterErrorDetails(
      exception: ArgumentError('widget broke'),
      stack: StackTrace.current,
      library: 'widgets library',
    ));
    final handled = PlatformDispatcher.instance.onError!(
      Exception('async broke'),
      StackTrace.current,
    );
    await client.flush();

    expect(previousCalled, 1);
    expect(platformCalled, 1);
    expect(handled, isTrue);
    final messages = transport.logs
        .map((l) => attr(l, 'exception.message') as String)
        .toList();
    expect(messages[0], contains('widget broke'));
    expect(messages[1], contains('async broke'));
    expect(attr(transport.logs[0], 'exception.library'), 'widgets library');

    await client.shutdown();
    // Handlers are restored on shutdown.
    FlutterError.onError!(const FlutterErrorDetails(exception: 'x'));
    expect(previousCalled, 2);

    FlutterError.onError = originalFlutter;
    PlatformDispatcher.instance.onError = originalPlatform;
  });

  group('sanitizeStackTrace', () {
    test('limits frames and redacts ignored urls', () {
      final stack = [
        for (var i = 0; i < 40; i++)
          '#$i f (https://app.example.com/secret/page.dart:$i:1)',
      ].join('\n');
      final result = sanitizeStackTrace(
        stack,
        ignoreRules: IgnoreRules(ignoreUrls: [RegExp('secret')]),
      );
      expect(result.split('\n'), hasLength(30));
      expect(result, isNot(contains('secret')));
      expect(result, contains('REDACTED'));
    });

    test('applies the scrubber to urls', () {
      final result = sanitizeStackTrace(
        '#0 f (https://user:pw@host/a.dart:1:1)',
        ignoreRules: IgnoreRules(),
      );
      expect(result, isNot(contains('pw')));
    });
  });

  test('cuts the message to 300 characters after scrubbing urls', () async {
    final (client, transport) = await start();
    client.reportError('a' * 400);
    client.reportError('see https://user:pw@example.com/x');
    await client.flush();
    expect(attr(transport.logs[0], 'exception.message'), 'a' * 300);
    expect(attr(transport.logs[1], 'exception.message'),
        'see https://REDACTED:REDACTED@example.com/x');
  });

  test('cuts and scrubs the component stack', () async {
    final (client, transport) = await start();
    client.reportError('e1',
        componentStack: 'https://u:p@example.com/a ${'b' * 3000}');
    await client.flush();
    final stack =
        attr(transport.logs.single, 'exception.component_stack')! as String;
    expect(stack.length, 2048);
    expect(stack, startsWith('https://REDACTED:REDACTED@example.com/a '));
  });

  test('drops Script error. variants by default', () async {
    final (client, transport) = await start();
    client.reportError('Script error.');
    client.reportError('Script error');
    client.reportError('Javascript error: Script error. on line 0');
    client.reportError('A Script error. happened');
    await client.flush();
    expect(transport.logs, hasLength(1));
  });

  test('keeps Script error. when ignoreCrossOriginScriptErrors is false',
      () async {
    final transport = FakeTransport();
    final client = await Dash0Client.start(
      const Dash0Options(
        serviceName: 'test',
        endpoint: testEndpoint,
        batchSize: 1,
        ignoreCrossOriginScriptErrors: false,
      ),
      transport: transport,
      sessionStore: MemoryStore(),
      installErrorHandlers: false,
      observeLifecycle: false,
    );
    client.reportError('Script error.');
    await client.flush();
    expect(transport.logs, hasLength(1));
  });

  group('browser extension errors', () {
    const extensionStack = 'TypeError: x\n'
        '    at a (chrome-extension://abc/content.js:1:1)\n'
        '    at b (moz-extension://abc/content.js:2:2)';
    const mixedStack = 'TypeError: x\n'
        '    at a (chrome-extension://abc/content.js:1:1)\n'
        '    at b (https://example.com/main.dart.js:2:2)';

    test('only extension frames are ignored', () {
      final rules = IgnoreRules();
      expect(rules.isErrorIgnored('TypeError: x', extensionStack), isTrue);
      expect(rules.isErrorIgnored('TypeError: x', mixedStack), isFalse);
      expect(rules.isErrorIgnored('TypeError: x', null), isFalse);
      expect(rules.isErrorIgnored('TypeError: x', '#0 main (file.dart:1:1)'),
          isFalse);
    });

    test('can be switched off', () {
      final rules = IgnoreRules(ignoreBrowserExtensionErrors: false);
      expect(rules.isErrorIgnored('TypeError: x', extensionStack), isFalse);
    });

    test('reportError drops them', () async {
      final (client, transport) = await start();
      client.reportError(StateError('x'),
          stackTrace: StackTrace.fromString(extensionStack));
      client.reportError(StateError('y'),
          stackTrace: StackTrace.fromString(mixedStack));
      await client.flush();
      expect(transport.logs, hasLength(1));
    });
  });
}
