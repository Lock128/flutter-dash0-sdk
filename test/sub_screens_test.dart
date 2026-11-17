import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

Future<(Dash0Client, FakeTransport)> start() async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    const Dash0Options(
        serviceName: 'test', endpoint: testEndpoint, batchSize: 1),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
  );
  return (client, transport);
}

const names = ['Overview', 'Failed Payments', 'Feature Flags'];

class Host extends StatefulWidget {
  const Host(
      {super.key,
      required this.client,
      this.firstTabIsParent = true,
      this.initialIndex = 0,
      this.useDefault = false});
  final Dash0Client? client;
  final bool firstTabIsParent;
  final int initialIndex;
  final bool useDefault;
  @override
  State<Host> createState() => HostState();
}

class HostState extends State<Host> with SingleTickerProviderStateMixin {
  late final TabController controller =
      TabController(length: 3, vsync: this, initialIndex: widget.initialIndex);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Widget body(TabController? c) => Column(children: [
        TabBar(controller: c, tabs: [for (final n in names) Tab(text: n)]),
        Expanded(
            child: TabBarView(
                controller: c,
                children: [for (final n in names) Text('v $n')])),
      ]);

  @override
  Widget build(BuildContext context) {
    final child = widget.useDefault
        ? DefaultTabController(
            length: 3,
            child: Builder(builder: (_) {
              return Dash0TabObserver(
                  parent: '/admin',
                  tabs: names,
                  client: widget.client,
                  firstTabIsParent: widget.firstTabIsParent,
                  child: body(null));
            }))
        : Dash0TabObserver(
            parent: '/admin',
            tabs: names,
            controller: controller,
            client: widget.client,
            firstTabIsParent: widget.firstTabIsParent,
            child: body(controller));
    return MaterialApp(home: Scaffold(body: child));
  }
}

List<Object?> screens(FakeTransport t) =>
    t.logs.map((l) => attr(l, 'app.screen.name')).toList();

void main() {
  test('subScreenPath slugs names', () {
    expect(
        subScreenPath('/admin', 'Failed Payments'), '/admin/failed-payments');
    expect(subScreenPath('/admin/', ' API  Tokens! '), '/admin/api-tokens');
    expect(subScreenPath('/', 'Home'), '/home');
    expect(subScreenPath('/admin', ''), '/admin');
  });

  testWidgets('reports taps, animateTo and swipes once each', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(Host(client: client));
    await client.flush();
    expect(screens(transport), isEmpty); // first tab is the route's view

    await tester.tap(find.text('Failed Payments').first);
    await tester.pumpAndSettle();
    final state = tester.state<HostState>(find.byType(Host));
    state.controller.animateTo(2);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(TabBarView), const Offset(500, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(TabBarView), const Offset(500, 0));
    await tester.pumpAndSettle();
    await client.flush();

    expect(screens(transport), [
      '/admin/failed-payments',
      '/admin/feature-flags',
      '/admin/failed-payments',
      '/admin'
    ]);
    expect(attr(transport.logs[0], 'change_state'), 'tab');
  });

  testWidgets('does not report mid animation', (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(Host(client: client));
    final state = tester.state<HostState>(find.byType(Host));
    state.controller.animateTo(1);
    await tester.pump(const Duration(milliseconds: 100));
    await client.flush();
    expect(state.controller.indexIsChanging, isTrue);
    expect(screens(transport), isEmpty);
    await tester.pumpAndSettle();
    await client.flush();
    expect(screens(transport), ['/admin/failed-payments']);
  });

  testWidgets(
      'reports a non zero initial tab and works with DefaultTabController',
      (tester) async {
    final (client, transport) = await start();
    await tester.pumpWidget(Host(client: client, initialIndex: 2));
    await client.flush();
    expect(screens(transport), ['/admin/feature-flags']);

    final (c2, t2) = await start();
    await tester.pumpWidget(Host(
        key: UniqueKey(),
        client: c2,
        useDefault: true,
        firstTabIsParent: false));
    await tester.pump();
    await tester.tap(find.text('Feature Flags').first);
    await tester.pumpAndSettle();
    await c2.flush();
    expect(screens(t2), ['/admin/overview', '/admin/feature-flags']);
  });

  testWidgets('is a no-op without a client', (tester) async {
    await tester.pumpWidget(const Host(client: null));
    await tester.tap(find.text('Feature Flags').first);
    final state = tester.state<HostState>(find.byType(Host));
    state.controller.animateTo(1);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    trackSubScreen('/x', 'y'); // not initialized, must not throw
  });

  testWidgets('does nothing while the client is disabled', (tester) async {
    final (client, transport) = await start();
    client.enabled = false;
    await tester.pumpWidget(Host(client: client));
    final state = tester.state<HostState>(find.byType(Host));
    state.controller.animateTo(1);
    await tester.pumpAndSettle();
    await client.flush();
    expect(screens(transport), isEmpty);
  });

  test('trackSubScreen sends a page view', () async {
    final (client, transport) = await start();
    trackSubScreen('/onboarding', 'Platform Features', client: client);
    trackSubScreen('/onboarding', 'Platform Features', client: client);
    await client.flush();
    expect(screens(transport), ['/onboarding/platform-features']);
  });
}
