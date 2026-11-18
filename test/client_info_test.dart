import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

const chromeDesktop =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const safariMac =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15';
const safariIphone =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1';
// iPadOS 13+ Safari in "Request Desktop Website" mode (the default on iPad).
const safariIpadDesktopMode = safariMac;
const chromeAndroid =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
const chromeAndroidTablet =
    'Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
const firefoxLinux =
    'Mozilla/5.0 (X11; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0';
const firefoxAndroid =
    'Mozilla/5.0 (Android 14; Mobile; rv:125.0) Gecko/125.0 Firefox/125.0';
const edgeWindows =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0';
const chromeOs =
    'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

Dash0ClientInfo web(String ua, {WebProbe? probe}) => classifyClient(
      isWeb: true,
      probe: probe ?? WebProbe(userAgent: ua),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('web classification from the user agent', () {
    void expectWeb(String ua, Dash0ClientType type, String? os,
        {int touch = 0}) {
      final info =
          web(ua, probe: WebProbe(userAgent: ua, maxTouchPoints: touch));
      expect(info.type, type, reason: ua);
      expect(info.osName, os, reason: ua);
      expect(info.runtime, 'flutter-web');
      expect(info.browserMobile, type == Dash0ClientType.webMobile);
      expect(info.browserPlatform, os);
      expect(info.userAgent, ua);
    }

    test('Chrome on Windows', () {
      expectWeb(chromeDesktop, Dash0ClientType.webDesktop, 'Windows');
    });
    test('Safari on macOS (no touch)', () {
      expectWeb(safariMac, Dash0ClientType.webDesktop, 'macOS');
    });
    test('Safari on iPhone', () {
      expectWeb(safariIphone, Dash0ClientType.webMobile, 'iOS');
    });
    test('Safari on iPad in desktop mode is recognized by touch points', () {
      expectWeb(safariIpadDesktopMode, Dash0ClientType.webMobile, 'iOS',
          touch: 5);
    });
    test('Chrome on Android phone', () {
      expectWeb(chromeAndroid, Dash0ClientType.webMobile, 'Android');
    });
    test('Chrome on Android tablet (no Mobile token) is web-mobile', () {
      expectWeb(chromeAndroidTablet, Dash0ClientType.webMobile, 'Android');
    });
    test('Firefox on Linux', () {
      expectWeb(firefoxLinux, Dash0ClientType.webDesktop, 'Linux');
    });
    test('Firefox on Android', () {
      expectWeb(firefoxAndroid, Dash0ClientType.webMobile, 'Android');
    });
    test('Edge on Windows', () {
      expectWeb(edgeWindows, Dash0ClientType.webDesktop, 'Windows');
    });
    test('ChromeOS', () {
      expectWeb(chromeOs, Dash0ClientType.webDesktop, 'ChromeOS');
    });
    test('unknown or missing user agent is web-desktop without os', () {
      final info = classifyClient(isWeb: true, probe: null);
      expect(info.type, Dash0ClientType.webDesktop);
      expect(info.osName, isNull);
      expect(info.userAgent, isNull);
    });
  });

  group('client hints', () {
    test('userAgentData.mobile wins over the user agent', () {
      final info = web(
        chromeDesktop,
        probe: const WebProbe(userAgent: chromeDesktop, uaDataMobile: true),
      );
      expect(info.type, Dash0ClientType.webMobile);
    });

    test('userAgentData.platform and brands are used, noise brands dropped',
        () {
      final info = web(
        chromeAndroid,
        probe: const WebProbe(
          userAgent: chromeAndroid,
          uaDataMobile: true,
          uaDataPlatform: 'Android',
          brands: ['Not/A)Brand', 'Chromium', 'Google Chrome'],
        ),
      );
      expect(info.type, Dash0ClientType.webMobile);
      expect(info.osName, 'Android');
      expect(info.browserBrands, ['Chromium', 'Google Chrome']);
      expect(info.resourceAttributes()['browser.brands'],
          ['Chromium', 'Google Chrome']);
    });

    test('desktop client hints with a macOS platform stay desktop', () {
      final info = web(
        safariMac,
        probe: const WebProbe(
          userAgent: safariMac,
          uaDataMobile: false,
          uaDataPlatform: 'macOS',
        ),
      );
      expect(info.type, Dash0ClientType.webDesktop);
      expect(info.osName, 'macOS');
    });
  });

  group('native classification', () {
    final expected = {
      TargetPlatform.iOS: ('ios', 'iOS'),
      TargetPlatform.android: ('android', 'Android'),
      TargetPlatform.macOS: ('macos', 'macOS'),
      TargetPlatform.windows: ('windows', 'Windows'),
      TargetPlatform.linux: ('linux', 'Linux'),
      TargetPlatform.fuchsia: ('fuchsia', 'Fuchsia'),
    };
    for (final e in expected.entries) {
      test(e.key.name, () {
        final info = classifyClient(isWeb: false, platform: e.key);
        expect(info.type.value, e.value.$1);
        expect(info.osName, e.value.$2);
        expect(info.runtime, 'flutter-native');
        expect(info.userAgent, isNull);
        expect(info.browserMobile, isNull);
        expect(info.signalAttributes(), {'app.client.type': e.value.$1});
      });
    }
  });

  group('attributes', () {
    test('user agent can be left out', () {
      final info = classifyClient(
        isWeb: true,
        probe: const WebProbe(userAgent: chromeDesktop),
        collectUserAgent: false,
      );
      expect(info.signalAttributes(), {'app.client.type': 'web-desktop'});
      expect(info.resourceAttributes().containsKey('user_agent.original'),
          isFalse);
    });

    test('the resource never contains the raw user agent', () {
      final info = web(safariIphone);
      expect(info.resourceAttributes(), {
        'app.client.type': 'web-mobile',
        'app.runtime': 'flutter-web',
        'os.name': 'iOS',
        'browser.mobile': true,
        'browser.platform': 'iOS',
      });
      expect(info.signalAttributes(), {
        'app.client.type': 'web-mobile',
        'user_agent.original': safariIphone,
      });
    });
  });

  group('client wiring', () {
    Future<(Dash0Client, FakeTransport)> start(
      Dash0ClientInfo info, {
      bool collectUserAgent = true,
      Map<String, Object?> resourceAttributes = const {},
    }) async {
      final transport = FakeTransport();
      final client = await Dash0Client.start(
        Dash0Options(
          serviceName: 'test-app',
          endpoint: testEndpoint,
          batchSize: 1,
          collectUserAgent: collectUserAgent,
          resourceAttributes: resourceAttributes,
        ),
        transport: transport,
        sessionStore: MemoryStore(),
        installErrorHandlers: false,
        observeLifecycle: false,
        clientInfo: info,
      );
      return (client, transport);
    }

    Map<String, Object?> logResource(FakeTransport t) =>
        ((t.sent.firstWhere((s) => s.path == '/v1/logs').body['resourceLogs']!
                as List)
            .single as Map)['resource'] as Map<String, Object?>;

    test('events, spans and the resource carry the client type', () async {
      final (client, transport) = await start(web(safariIphone));
      client.sendEvent('my.event');
      client.startSpan('work').end();
      await client.flush();

      final log = transport.logs.single;
      expect(attr(log, 'app.client.type'), 'web-mobile');
      expect(attr(log, 'user_agent.original'), safariIphone);
      final span = transport.spans.single;
      expect(attr(span, 'app.client.type'), 'web-mobile');
      expect(attr(span, 'user_agent.original'), safariIphone);
      final res = logResource(transport);
      expect(attr(res, 'app.client.type'), 'web-mobile');
      expect(attr(res, 'app.runtime'), 'flutter-web');
      expect(attr(res, 'os.name'), 'iOS');
      expect(attr(res, 'user_agent.original'), isNull);
    });

    test('metrics get the client type from the resource, not the user agent',
        () async {
      final (client, transport) = await start(web(safariIphone));
      client.counter('x').add(1);
      await client.flush();

      final metricsSend =
          transport.sent.firstWhere((s) => s.path == '/v1/metrics');
      final res = ((metricsSend.body['resourceMetrics']! as List).single
          as Map)['resource'] as Map<String, Object?>;
      expect(attr(res, 'app.client.type'), 'web-mobile');
      final point =
          (((transport.metrics.single['sum']! as Map)['dataPoints'] as List)
              .single as Map<String, Object?>);
      expect(point['attributes'] ?? const [], isNot(contains(anything)),
          reason: 'no per data point client attributes');
      expect(metricsSend.body.toString(), isNot(contains('user_agent')));
    });

    test('collectUserAgent false drops only the user agent', () async {
      final (client, transport) =
          await start(web(chromeDesktop), collectUserAgent: false);
      client.sendEvent('my.event');
      await client.flush();
      final log = transport.logs.single;
      expect(attr(log, 'app.client.type'), 'web-desktop');
      expect(attr(log, 'user_agent.original'), isNull);
    });

    test('resourceAttributes from options override the detected values',
        () async {
      final (client, transport) = await start(
        classifyClient(isWeb: false, platform: TargetPlatform.iOS),
        resourceAttributes: const {
          'os.name': 'iPadOS',
          'device.model.identifier': 'iPad13,4',
        },
      );
      client.sendEvent('my.event');
      await client.flush();
      final res = logResource(transport);
      expect(attr(res, 'os.name'), 'iPadOS');
      expect(attr(res, 'device.model.identifier'), 'iPad13,4');
      expect(attr(res, 'app.client.type'), 'ios');
      expect(attr(res, 'app.runtime'), 'flutter-native');
    });

    test('the default client is detected without an override', () async {
      final transport = FakeTransport();
      final client = await Dash0Client.start(
        const Dash0Options(
            serviceName: 'test-app', endpoint: testEndpoint, batchSize: 1),
        transport: transport,
        sessionStore: MemoryStore(),
        installErrorHandlers: false,
        observeLifecycle: false,
      );
      // The VM test runner reports the host platform, never a web client.
      expect(client.clientInfo.isWeb, isFalse);
      expect(client.clientInfo.runtime, 'flutter-native');
    });
  });
}
