import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:dash0_flutter_sdk/src/client_probe_reader.dart';
import 'package:dash0_flutter_sdk/src/client_info.dart'
    show buildSyntheticUserAgent;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0';

class _Nav implements NavigatorSource {
  _Nav({this.throwHints = false});
  final bool throwHints;

  @override
  String? get userAgent => ua;
  @override
  int? get maxTouchPoints => throwHints ? throw StateError('x') : 0;
  @override
  bool? get uaDataMobile => throwHints ? throw StateError('x') : false;
  @override
  String? get uaDataPlatform => throwHints ? throw StateError('x') : 'Windows';
  @override
  List<String>? get uaDataBrands =>
      throwHints ? throw StateError('x') : ['Chromium'];
  @override
  int? get innerWidth => throwHints ? throw StateError('x') : 1280;
  @override
  int? get innerHeight => 720;
  @override
  String? get connectionEffectiveType => throw StateError('x');
}

Dash0ClientInfo _web(String? agent) => classifyClient(
      isWeb: true,
      probe: agent == null ? null : WebProbe(userAgent: agent),
    );

Future<(Dash0Client, FakeTransport)> _start(
  Dash0ClientInfo info, {
  bool collectUserAgent = true,
  bool userAgentOnResource = false,
  bool syntheticUserAgent = false,
  Map<String, Object?> resourceAttributes = const {},
  ViewportProbe? Function()? viewport,
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'my-app',
      serviceVersion: '1.2.3',
      endpoint: testEndpoint,
      batchSize: 1,
      collectUserAgent: collectUserAgent,
      userAgentOnResource: userAgentOnResource,
      syntheticUserAgent: syntheticUserAgent,
      resourceAttributes: resourceAttributes,
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
    clientInfo: info,
    viewportProbe: viewport,
  );
  return (client, transport);
}

Map<String, Object?> _resource(FakeTransport t, String path, String key) =>
    ((t.sent.firstWhere((s) => s.path == path).body[key]! as List).single
        as Map)['resource'] as Map<String, Object?>;

void main() {
  group('probe readers', () {
    test('a failing userAgentData read keeps userAgent', () {
      final probe = readWebProbe(_Nav(throwHints: true));
      expect(probe.userAgent, ua);
      expect(probe.brands, isEmpty);
      expect(probe.uaDataPlatform, isNull);
    });

    test('healthy navigator is read fully', () {
      final probe = readWebProbe(_Nav());
      expect(probe.uaDataPlatform, 'Windows');
      expect(probe.brands, ['Chromium']);
    });

    test('viewport reads are independent', () {
      final v = readViewportProbe(_Nav());
      expect(v.width, 1280);
      expect(v.height, 720);
      expect(v.connectionType, isNull);
      expect(readViewportProbe(_Nav(throwHints: true)).height, 720);
    });
  });

  group('user agent on web signals', () {
    test('log, span and event carry it, metrics never', () async {
      final (client, transport) = await _start(_web(ua));
      client.sendEvent('my.event');
      client.startSpan('work').end();
      client.counter('x').add(1);
      await client.flush();
      expect(attr(transport.logs.single, 'user_agent.original'), ua);
      expect(attr(transport.spans.single, 'user_agent.original'), ua);
      final m = transport.sent.firstWhere((s) => s.path == '/v1/metrics');
      expect(m.body.toString(), isNot(contains('user_agent')));
      expect(m.body.toString(), isNot(contains('page.load.id')));
      expect(m.body.toString(), isNot(contains('browser.tab.id')));
    });

    test('empty or missing user agent sends undefined like the web SDK',
        () async {
      for (final agent in [null, '']) {
        final (client, transport) = await _start(_web(agent));
        client.sendEvent('my.event');
        await client.flush();
        expect(attr(transport.logs.single, 'user_agent.original'), 'undefined');
      }
    });

    test('collectUserAgent false sends nothing', () async {
      final (client, transport) =
          await _start(_web(ua), collectUserAgent: false);
      client.sendEvent('my.event');
      await client.flush();
      expect(attr(transport.logs.single, 'user_agent.original'), isNull);
    });
  });

  group('web only attributes', () {
    test('present on web, stable ids, window read at emission time', () async {
      var width = 800;
      final (client, transport) = await _start(
        _web(ua),
        viewport: () =>
            ViewportProbe(width: width, height: 600, connectionType: '4g'),
      );
      client.sendEvent('a');
      width = 1000;
      client.sendEvent('b');
      await client.flush();
      final logs = transport.logs;
      expect(attr(logs[0], 'browser.window.width'), '800');
      expect(attr(logs[1], 'browser.window.width'), '1000');
      expect(attr(logs[0], 'browser.window.height'), '600');
      expect(attr(logs[0], 'network.connection.subtype'), '4g');
      expect(attr(logs[0], 'page.load.id'), isNotNull);
      expect(attr(logs[0], 'page.load.id'), attr(logs[1], 'page.load.id'));
      expect(attr(logs[0], 'browser.tab.id'), isNotNull);
      expect(attr(logs[0], 'page.load.id'), client.pageLoadId);
    });

    test('a throwing viewport probe does not break the signal', () async {
      final (client, transport) =
          await _start(_web(ua), viewport: () => throw StateError('x'));
      client.sendEvent('a');
      await client.flush();
      expect(attr(transport.logs.single, 'page.load.id'), isNotNull);
      expect(attr(transport.logs.single, 'browser.window.width'), isNull);
    });

    test('absent on native', () async {
      final (client, transport) = await _start(
        classifyClient(isWeb: false, platform: TargetPlatform.iOS),
        viewport: () => const ViewportProbe(width: 1, height: 2),
      );
      client.sendEvent('a');
      await client.flush();
      final log = transport.logs.single;
      for (final k in [
        'page.load.id',
        'browser.tab.id',
        'browser.window.width',
        'browser.window.height',
        'network.connection.subtype',
        'user_agent.original',
      ]) {
        expect(attr(log, k), isNull, reason: k);
      }
    });
  });

  group('userAgentOnResource', () {
    test('logs and spans resource, never metrics', () async {
      final (client, transport) =
          await _start(_web(ua), userAgentOnResource: true);
      client.sendEvent('a');
      client.startSpan('s').end();
      client.counter('x').add(1);
      await client.flush();
      expect(
          attr(_resource(transport, '/v1/logs', 'resourceLogs'),
              'user_agent.original'),
          ua);
      expect(
          attr(_resource(transport, '/v1/traces', 'resourceSpans'),
              'user_agent.original'),
          ua);
      expect(
          attr(_resource(transport, '/v1/metrics', 'resourceMetrics'),
              'user_agent.original'),
          isNull);
    });

    test('off by default and with collectUserAgent false', () async {
      for (final (opt, collect) in [(false, true), (true, false)]) {
        final (client, transport) = await _start(_web(ua),
            userAgentOnResource: opt, collectUserAgent: collect);
        client.sendEvent('a');
        await client.flush();
        expect(
            attr(_resource(transport, '/v1/logs', 'resourceLogs'),
                'user_agent.original'),
            isNull);
      }
    });
  });

  group('syntheticUserAgent', () {
    final ios = classifyClient(isWeb: false, platform: TargetPlatform.iOS);

    test('format', () {
      expect(
          buildSyntheticUserAgent(
              service: 'a',
              serviceVersion: '1',
              osName: 'iOS',
              osVersion: '17.4',
              device: 'iPhone15,2'),
          'a/1 (iOS 17.4; iPhone15,2)');
      expect(buildSyntheticUserAgent(service: 'a', osName: 'iOS'), 'a (iOS)');
      expect(buildSyntheticUserAgent(service: 'a'), 'a');
    });

    test('sent on native signals, not metrics', () async {
      final (client, transport) = await _start(
        ios,
        syntheticUserAgent: true,
        resourceAttributes: const {
          'os.version': '17.4',
          'device.model.identifier': 'iPhone15,2',
        },
      );
      client.sendEvent('a');
      client.startSpan('s').end();
      client.counter('x').add(1);
      await client.flush();
      for (final s in [transport.logs.single, transport.spans.single]) {
        expect(attr(s, 'user_agent.original'),
            'my-app/1.2.3 (iOS 17.4; iPhone15,2)');
        expect(attr(s, 'app.client.user_agent.synthetic'), true);
      }
      final m = transport.sent.firstWhere((s) => s.path == '/v1/metrics');
      expect(m.body.toString(), isNot(contains('user_agent')));
    });

    test('off by default, off with collectUserAgent false', () async {
      for (final (syn, collect) in [(false, true), (true, false)]) {
        final (client, transport) = await _start(ios,
            syntheticUserAgent: syn, collectUserAgent: collect);
        client.sendEvent('a');
        await client.flush();
        expect(attr(transport.logs.single, 'user_agent.original'), isNull);
        expect(attr(transport.logs.single, 'app.client.user_agent.synthetic'),
            isNull);
      }
    });

    test('never on web, the real user agent wins', () async {
      final (client, transport) =
          await _start(_web(ua), syntheticUserAgent: true);
      client.sendEvent('a');
      await client.flush();
      expect(attr(transport.logs.single, 'user_agent.original'), ua);
      expect(attr(transport.logs.single, 'app.client.user_agent.synthetic'),
          isNull);
    });
  });
}
