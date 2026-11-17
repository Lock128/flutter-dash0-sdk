import 'dart:async';

import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:dash0_flutter_sdk/src/instrumentation/navigation.dart'
    show trackScreenView;
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

class StatisticsScreen extends StatelessWidget {
  const StatisticsScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('statistics'));
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('home'));
}

Future<(Dash0Client, FakeTransport)> start({
  bool enabled = true,
  bool nameUnnamedRoutes = true,
  bool trackPopupRoutes = false,
  int Function()? nowMillis,
}) async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      batchSize: 1,
      enabled: enabled,
      nameUnnamedRoutes: nameUnnamedRoutes,
      trackPopupRoutes: trackPopupRoutes,
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
    nowMillis: nowMillis,
  );
  return (client, transport);
}

Widget app(NavigatorObserver observer, {Widget home = const HomeScreen()}) =>
    MaterialApp(navigatorObservers: [observer], home: home);

List<Object?> screens(FakeTransport t) =>
    t.logs.map((l) => attr(l, 'app.screen.name')).toList();

void main() {
  testWidgets('initial page view is sent when a disabled client is enabled',
      (tester) async {
    final (client, transport) = await start(enabled: false);
    await tester.pumpWidget(app(
      Dash0NavigatorObserver(client),
      home: const StatisticsScreen(),
    ));
    await tester.pump();
    trackScreenView(client, '/start', changeState: 'push');
    await client.flush();
    expect(transport.logs, isEmpty);
    expect(client.currentScreen, isNull);

    client.enabled = true;
    await client.flush();
    expect(screens(transport), ['/start']);
    expect(attr(transport.logs.single, 'type'), '0');

    // Enabling again or tracking the same screen does not repeat it.
    client.enabled = false;
    client.enabled = true;
    trackScreenView(client, '/start');
    await client.flush();
    expect(transport.logs, hasLength(1));
  });

  testWidgets('only the latest screen seen while disabled is sent',
      (tester) async {
    final (client, transport) = await start(enabled: false);
    trackScreenView(client, '/a');
    trackScreenView(client, '/b');
    client.enabled = true;
    await client.flush();
    expect(screens(transport), ['/b']);
    expect(attr(transport.logs.single, 'type'), '0');
  });

  testWidgets('unnamed routes are named after the page widget', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app(Dash0NavigatorObserver(client)));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
        MaterialPageRoute<void>(builder: (_) => const StatisticsScreen()));
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    await client.flush();
    expect(screens(transport), ['/', '/StatisticsScreen', '/']);
  });

  testWidgets('nameUnnamedRoutes false ignores unnamed routes', (tester) async {
    final (client, transport) = await start(nameUnnamedRoutes: false);
    await tester.pumpWidget(app(Dash0NavigatorObserver(client)));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
        MaterialPageRoute<void>(builder: (_) => const StatisticsScreen()));
    await tester.pumpAndSettle();
    await client.flush();
    expect(screens(transport), ['/']);
  });

  testWidgets('a named route takes precedence over the widget name',
      (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app(Dash0NavigatorObserver(client)));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/stats'),
      builder: (_) => const StatisticsScreen(),
    ));
    await tester.pumpAndSettle();
    await client.flush();
    expect(screens(transport), ['/', '/stats']);
  });

  testWidgets('query strings are stripped from route names', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app(Dash0NavigatorObserver(client)));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/stats?range=7d#top'),
      builder: (_) => const StatisticsScreen(),
    ));
    await tester.pumpAndSettle();
    navigator.pushReplacement(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/stats?range=30d'),
      builder: (_) => const StatisticsScreen(),
    ));
    await tester.pumpAndSettle();
    await client.flush();
    expect(screens(transport), ['/', '/stats']);
  });

  testWidgets('popup routes are ignored by default', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(app(
      Dash0NavigatorObserver(client),
      home: const Scaffold(),
    ));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/page'),
      builder: (_) => const StatisticsScreen(),
    ));
    await tester.pumpAndSettle();
    unawaited(showDialog<void>(
      context: navigator.context,
      routeSettings: const RouteSettings(name: '/dialog'),
      builder: (_) => const AlertDialog(title: Text('hi')),
    ));
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    await client.flush();
    expect(screens(transport), ['/', '/page']);
  });

  testWidgets('trackPopupRoutes reports named and unnamed popups',
      (tester) async {
    final (client, transport) = await start(trackPopupRoutes: true);
    await tester.pumpWidget(app(
      Dash0NavigatorObserver(client),
      home: const Scaffold(),
    ));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/page'),
      builder: (_) => const StatisticsScreen(),
    ));
    await tester.pumpAndSettle();
    unawaited(showDialog<void>(
      context: navigator.context,
      routeSettings: const RouteSettings(name: '/named-dialog'),
      builder: (_) => const AlertDialog(title: Text('hi')),
    ));
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    unawaited(showDialog<void>(
      context: navigator.context,
      builder: (_) => const AlertDialog(title: Text('hi')),
    ));
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    await client.flush();
    expect(screens(transport), [
      '/',
      '/page',
      '/named-dialog',
      '/page',
      '/popup/AlertDialog',
      '/page',
    ]);
  });

  testWidgets('previous screen duration is reported', (tester) async {
    var now = 1000;
    final (client, transport) = await start(nowMillis: () => now);
    trackScreenView(client, '/a');
    now += 2500;
    trackScreenView(client, '/b');
    now += 40;
    trackScreenView(client, '/c');
    await client.flush();
    expect(attr(transport.logs[0], 'app.screen.previous.duration_ms'), isNull);
    expect(attr(transport.logs[1], 'app.screen.previous.duration_ms'), '2500');
    expect(attr(transport.logs[2], 'app.screen.previous.duration_ms'), '40');
  });

  testWidgets('createNavigatorObserver returns independent observers',
      (tester) async {
    final a = Dash0.createNavigatorObserver();
    final b = Dash0.createNavigatorObserver();
    expect(identical(a, b), isFalse);
    expect(identical(a, Dash0.navigatorObserver), isFalse);
  });

  testWidgets('a throwing resolver never reaches the app', (tester) async {
    final transport = FakeTransport();
    final client = await Dash0Client.start(
      Dash0Options(
        serviceName: 'test',
        endpoint: testEndpoint,
        batchSize: 1,
        screenNameResolver: (_) => throw StateError('boom'),
      ),
      transport: transport,
      sessionStore: MemoryStore(),
      installErrorHandlers: false,
      observeLifecycle: false,
    );
    await tester.pumpWidget(app(Dash0NavigatorObserver(client)));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
        MaterialPageRoute<void>(builder: (_) => const StatisticsScreen()));
    await tester.pumpAndSettle();
    await client.flush();
    expect(tester.takeException(), isNull);
    expect(screens(transport), ['/', '/StatisticsScreen']);
  });
}
