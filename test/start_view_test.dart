import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(Dash0Client, FakeTransport)> start(
      {UrlScrubber? scrubber, Set<Dash0Instrumentation>? enabled}) async {
    final transport = FakeTransport();
    final client = await Dash0Client.start(
      Dash0Options(
        serviceName: 'test',
        endpoint: testEndpoint,
        batchSize: 1,
        urlScrubber: scrubber,
        enabledInstrumentations: enabled,
      ),
      transport: transport,
      sessionStore: MemoryStore(),
      installErrorHandlers: false,
      observeLifecycle: false,
    );
    return (client, transport);
  }

  test('emits a virtual page view without change_state', () async {
    final (client, transport) = await start();
    client.startView('Settings');
    await client.flush();
    final log = transport.logs.single;
    expect(attr(log, 'event.name'), 'browser.page_view');
    expect(attr(log, 'type'), '1');
    expect(attr(log, 'change_state'), isNull);
    expect(attr(log, 'dash0.web.event.title'), 'Settings');
  });

  test('url override feeds page.url.*', () async {
    final (client, transport) = await start();
    client.startView('A', url: '/settings/profile');
    client.startView('B', url: 'https://example.com/docs?x=1');
    client.startView('C', url: 'app://shell/home');
    await client.flush();
    final a = transport.logs[0], b = transport.logs[1], c = transport.logs[2];
    expect(attr(a, 'page.url.full'), 'app://settings/profile');
    expect(attr(a, 'page.url.path'), '/settings/profile');
    expect(attr(a, 'page.url.domain'), 'test');
    expect(attr(b, 'page.url.full'), 'https://example.com/docs?x=1');
    expect(attr(b, 'page.url.scheme'), 'https');
    expect(attr(b, 'page.url.domain'), 'example.com');
    expect(attr(b, 'page.url.path'), '/docs');
    expect(attr(c, 'page.url.domain'), 'shell');
    expect(attr(c, 'page.url.path'), '/home');
  });

  test('attributes are added last and can override', () async {
    final (client, transport) = await start();
    client.startView('A',
        url: '/a', attributes: {'page.url.path': '/custom', 'x': 'y'});
    await client.flush();
    final log = transport.logs.single;
    expect(attr(log, 'page.url.path'), '/custom');
    expect(attr(log, 'x'), 'y');
  });

  test('does not change the current screen', () async {
    final (client, transport) = await start();
    client.startView('A', url: '/a');
    expect(client.currentScreen, isNull);
    client.startView('B');
    await client.flush();
    expect(attr(transport.logs[1], 'page.url.full'), isNull);
  });

  test('empty names and disabled navigation send nothing', () async {
    final (client, transport) = await start();
    client.startView('');
    final (off, offTransport) =
        await start(enabled: {Dash0Instrumentation.error});
    off.startView('A');
    await client.flush();
    await off.flush();
    expect(transport.logs, isEmpty);
    expect(offTransport.logs, isEmpty);
  });
}
