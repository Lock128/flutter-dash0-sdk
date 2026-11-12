import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Future<(Dash0Client, FakeTransport)> start({
  Dash0PageViewMeta? Function(String)? meta,
  Set<Dash0Instrumentation>? enabled,
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      batchSize: 1,
      generatePageViewMetadata: meta,
      enabledInstrumentations: enabled,
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
  );
  return (client, transport);
}

Widget app(NavigatorObserver observer) => Directionality(
      textDirection: TextDirection.ltr,
      child: Navigator(
        observers: [observer],
        initialRoute: '/',
        onGenerateRoute: (settings) => PageRouteBuilder<void>(
          settings: settings,
          pageBuilder: (context, _, __) => settings.name == '/'
              ? GestureDetector(
                  onTap: () => Navigator.of(context).pushNamed('/details'),
                  child: const Text('go'),
                )
              : const Text('details'),
        ),
      ),
    );

void main() {
  testWidgets('sends page views for push and pop', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app(Dash0NavigatorObserver(client)));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();
    await client.flush();

    final logs = transport.logs;
    expect(logs.map((l) => attr(l, 'app.screen.name')), ['/', '/details', '/']);
    expect(attr(logs[0], 'event.name'), 'app.page_view');
    expect(attr(logs[0], 'type'), '0');
    expect(attr(logs[1], 'type'), '1');
    expect(attr(logs[1], 'change_state'), 'push');
    expect(attr(logs[1], 'app.screen.referrer'), '/');
    expect(attr(logs[2], 'change_state'), 'pop');
    expect(attr(logs[1], 'dash0.app.event.title'), '/details');
  });

  testWidgets('custom metadata overrides the title', (tester) async {
    final (client, transport) = await start(
      meta: (screen) => Dash0PageViewMeta(
        title: 'Screen $screen',
        attributes: const {'section': 'main'},
      ),
    );
    await tester.pumpWidget(app(Dash0NavigatorObserver(client)));
    await client.flush();
    final log = transport.logs.first;
    expect(attr(log, 'dash0.app.event.title'), 'Screen /');
    expect(attr(log, 'section'), 'main');
  });

  testWidgets('does nothing when navigation is disabled', (tester) async {
    final (client, transport) =
        await start(enabled: {Dash0Instrumentation.error});
    await tester.pumpWidget(app(Dash0NavigatorObserver(client)));
    await client.flush();
    expect(transport.logs, isEmpty);
  });

  testWidgets('screen name is added to later signals', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app(Dash0NavigatorObserver(client)));
    client.sendEvent('tap');
    await client.flush();
    final tap = transport.logs.last;
    expect(attr(tap, 'event.name'), 'tap');
    expect(attr(tap, 'app.screen.name'), '/');
  });

  test('trackScreen sends a manual page view and skips repeats', () async {
    final (client, transport) = await start();
    trackScreenForTest(client, 'home');
    trackScreenForTest(client, 'home');
    trackScreenForTest(client, 'settings');
    await client.flush();
    expect(transport.logs, hasLength(2));
  });
}

void trackScreenForTest(Dash0Client client, String name) {
  // Uses the same code path as Dash0.trackScreen.
  Dash0NavigatorObserver(client).didPush(
    PageRouteBuilder<void>(
      settings: RouteSettings(name: name),
      pageBuilder: (_, __, ___) => const SizedBox(),
    ),
    null,
  );
}
