import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Future<(Dash0Client, FakeTransport)> start({
  bool legacy = false,
  Set<Dash0Instrumentation>? only,
  bool enabled = true,
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      legacyAppNames: legacy,
      enabledInstrumentations: only,
      enabled: enabled,
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

Map scopeOf(FakeTransport t, String path, String key, String scopeKey) {
  final body = t.sent.firstWhere((s) => s.path == path).body;
  final rl = (body[key]! as List).first as Map;
  return ((rl[scopeKey]! as List).first as Map)['scope'] as Map;
}

List<Map<String, Object?>> named(FakeTransport t, String name) =>
    t.logs.where((l) => attr(l, 'event.name') == name).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default names match dash0-sdk-web', () async {
    final (client, transport) = await start();
    screen(client, '/home');
    client.reportError(StateError('boom'));
    client.startSpan('s').end();
    await client.flush();
    expect(scopeOf(transport, '/v1/logs', 'resourceLogs', 'scopeLogs')['name'],
        'dash0-web-sdk');
    final resource = ((transport.sent.first.body['resourceLogs']! as List).first
        as Map)['resource'] as Map<String, Object?>;
    expect(attr(resource, 'telemetry.sdk.name'), 'dash0-web-sdk');
    expect(attr(resource, 'telemetry.sdk.language'), 'dart');
    expect(attr(resource, 'telemetry.sdk.version'), dash0SdkVersion);
    expect(named(transport, 'browser.page_view'), hasLength(1));
    expect(named(transport, 'browser.error'), hasLength(1));
    expect(
        attr(named(transport, 'browser.page_view').single,
            'dash0.web.event.title'),
        '/home');
    expect(attr(transport.spans.single, 'dash0.web.event.id'), isNotNull);
    expect(attr(transport.spans.single, 'dash0.app.event.id'), isNull);
    await client.shutdown();
  });

  test('legacyAppNames restores the app.* names', () async {
    final (client, transport) = await start(legacy: true);
    screen(client, '/home');
    client.reportError(StateError('boom'));
    client.startSpan('s').end();
    await client.flush();
    expect(scopeOf(transport, '/v1/logs', 'resourceLogs', 'scopeLogs')['name'],
        'dash0-flutter-sdk');
    expect(named(transport, 'app.page_view'), hasLength(1));
    expect(named(transport, 'app.error'), hasLength(1));
    expect(named(transport, 'browser.page_view'), isEmpty);
    expect(
        attr(named(transport, 'app.page_view').single, 'dash0.app.event.title'),
        '/home');
    expect(attr(transport.spans.single, 'dash0.app.event.id'), isNotNull);
    await client.shutdown();
  });

  test('page.url.* is present once a screen is set', () async {
    final (client, transport) = await start();
    client.sendEvent('before');
    screen(client, '/details');
    client.sendEvent('after');
    client.reportError(StateError('x'));
    client.startSpan('s').end();
    await client.flush();
    final before = named(transport, 'before').single;
    expect(attr(before, 'page.url.full'), isNull);
    final view = named(transport, 'browser.page_view').single;
    for (final signal in [
      view,
      named(transport, 'after').single,
      named(transport, 'browser.error').single,
      transport.spans.single,
    ]) {
      expect(attr(signal, 'page.url.full'), 'app://details');
      expect(attr(signal, 'page.url.scheme'), 'app');
      expect(attr(signal, 'page.url.domain'), 'test');
      expect(attr(signal, 'page.url.path'), '/details');
      expect(attr(signal, 'app.screen.name'), '/details');
    }
    await client.shutdown();
  });

  test('page.url.* is also set with legacy names', () async {
    final (client, transport) = await start(legacy: true);
    screen(client, 'home');
    await client.flush();
    expect(attr(transport.logs.single, 'page.url.full'), 'app://home');
    await client.shutdown();
  });

  test('page.url.full goes through the url scrubber', () async {
    final transport = FakeTransport();
    final client = await Dash0Client.start(
      Dash0Options(
        serviceName: 'test',
        endpoint: testEndpoint,
        urlScrubber: (u) => u.replaceAll('secret', 'x'),
      ),
      transport: transport,
      sessionStore: MemoryStore(),
      installErrorHandlers: false,
      observeLifecycle: false,
    );
    screen(client, '/user/secret');
    await client.flush();
    expect(attr(transport.logs.single, 'page.url.full'), 'app://user/x');
    expect(attr(transport.logs.single, 'page.url.path'), '/user/x');
    await client.shutdown();
  });

  test('browser.* names are reserved for custom events', () async {
    final (client, transport) = await start();
    for (final n in [
      'browser.page_view',
      'browser.error',
      'browser.rage_click',
      'browser.web_vital',
      'app.page_view',
    ]) {
      client.sendEvent(n);
    }
    await client.flush();
    expect(transport.logs, isEmpty);
    await client.shutdown();
  });

  group('browser.web_vital', () {
    void frame(Dash0Client c, num total) => c.vitals!.processFrame(
        build: const Duration(milliseconds: 5),
        raster: const Duration(milliseconds: 5),
        total: Duration(microseconds: (total * 1000).round()));

    test('INP and LCP are emitted when leaving a screen', () async {
      final (client, transport) = await start();
      screen(client, 'home');
      frame(client, 10);
      client.vitals!.markInteraction();
      frame(client, 10);
      screen(client, 'detail');
      await client.flush();
      final vitals = named(transport, 'browser.web_vital');
      expect(vitals, hasLength(2));
      final byName = {
        for (final v in vitals)
          ((v['body']! as Map)['kvlistValue'] as Map)['values']
                  .firstWhere((kv) => kv['key'] == 'name')['value']
              ['stringValue']: v,
      };
      expect(byName.keys, containsAll(['LCP', 'INP']));
      final inp = ((byName['INP']!['body']! as Map)['kvlistValue']
          as Map)['values'] as List;
      expect(
          inp.map((kv) => kv['key']), containsAll(['name', 'value', 'delta']));
      expect(byName['INP']!['severityText'], 'INFO');
      expect(attr(byName['INP']!, 'page.url.full'), 'app://home');
      await client.shutdown();
    });

    test('are not emitted with legacyAppNames', () async {
      final (client, transport) = await start(legacy: true);
      screen(client, 'home');
      frame(client, 10);
      client.vitals!.markInteraction();
      frame(client, 10);
      screen(client, 'detail');
      await client.flush();
      expect(named(transport, 'browser.web_vital'), isEmpty);
      await client.shutdown();
    });

    test('are not emitted when vitals are disabled', () async {
      final (client, transport) =
          await start(only: {Dash0Instrumentation.navigation});
      screen(client, 'home');
      screen(client, 'detail');
      await client.flush();
      expect(named(transport, 'browser.web_vital'), isEmpty);
      await client.shutdown();
    });
  });
}
