// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import '../client.dart';
import '../dash0.dart';
import 'navigation.dart';

/// Builds the page name of a sub screen: `subScreenPath('/admin',
/// 'Failed Payments')` is `/admin/failed-payments`.
///
/// [sub] is lower-cased and every run of characters other than letters and
/// digits becomes one `-`. An empty [sub] returns [parent]. Use fixed,
/// human readable names. Never pass ids or user data.
String subScreenPath(String parent, String sub) {
  final slug = sub
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final base = parent.length > 1 && parent.endsWith('/')
      ? parent.substring(0, parent.length - 1)
      : parent;
  if (slug.isEmpty) return base;
  return base == '/' ? '/$slug' : '$base/$slug';
}

/// Sends a page view for [sub] below [parent] (see [subScreenPath]) with the
/// client of `Dash0.init`, or [client] when given. Use for in screen
/// navigation that has no `TabController`, such as a `PageView` or a
/// custom switcher. Consecutive views of the same page are ignored.
///
/// Does nothing while the SDK is not initialized or disabled and never
/// throws.
void trackSubScreen(String parent, String sub, {Dash0Client? client}) {
  try {
    final c = client ?? Dash0.client;
    if (c == null) return;
    trackScreenView(c, subScreenPath(parent, sub), changeState: 'tab');
  } catch (_) {}
}

/// Sends a page view whenever the selected tab of a [TabController] changes.
///
/// Wrap the screen's `TabBar`/`TabBarView` with it. The controller is
/// [controller] or the nearest `DefaultTabController`. Taps,
/// `TabController.animateTo` and swipes are all reported. A change is
/// reported once it has settled: not while the tab is animating towards its
/// new index and not when the index did not change.
///
/// Tab `i` is reported as `subScreenPath(parent, tabs[i])`. [parent] must be
/// the name of the route that shows the tabs, so that the tab names extend
/// the route's own page view. With [firstTabIsParent] (the default) the
/// first tab is reported as [parent] itself, which is what the navigator
/// observer already sent when the route was pushed. The initial tab is then
/// not sent twice. Set it to false to report `<parent>/<tabs[0]>` as well.
/// A controller that starts at another index than 0 reports its initial tab.
///
/// ```dart
/// Dash0TabObserver(
///   parent: '/admin',
///   tabs: ['Overview', 'Failed Payments', 'Disputes'],
///   controller: _tabController,
///   child: Column(children: [TabBar(...), Expanded(child: TabBarView(...))]),
/// )
/// ```
class Dash0TabObserver extends StatefulWidget {
  const Dash0TabObserver({
    super.key,
    required this.parent,
    required this.tabs,
    required this.child,
    this.controller,
    this.firstTabIsParent = true,
    this.client,
  });

  /// Page name of the screen that shows the tabs, for example `/admin`.
  final String parent;

  /// Fixed human readable tab names, one per tab, in tab order.
  final List<String> tabs;

  /// The tab controller. Defaults to the nearest `DefaultTabController`.
  final TabController? controller;

  /// Report the first tab as [parent] instead of `<parent>/<tabs[0]>`.
  final bool firstTabIsParent;

  /// Client to report to. Defaults to the client of `Dash0.init`.
  final Dash0Client? client;

  final Widget child;

  @override
  State<Dash0TabObserver> createState() => _Dash0TabObserverState();
}

class _Dash0TabObserverState extends State<Dash0TabObserver> {
  TabController? _attached;
  int? _lastReported;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attach();
  }

  @override
  void didUpdateWidget(Dash0TabObserver oldWidget) {
    super.didUpdateWidget(oldWidget);
    _attach();
  }

  void _attach() {
    TabController? next;
    try {
      next = widget.controller ?? DefaultTabController.maybeOf(context);
    } catch (_) {
      next = null;
    }
    if (identical(next, _attached)) return;
    _attached?.removeListener(_onChange);
    _attached = next;
    _lastReported = null;
    if (next == null) return;
    next.addListener(_onChange);
    // The route page view covers the first tab.
    _lastReported = widget.firstTabIsParent ? 0 : null;
    _report(next);
  }

  void _onChange() {
    final controller = _attached;
    if (controller == null) return;
    _report(controller);
  }

  void _report(TabController controller) {
    try {
      if (controller.indexIsChanging) return;
      final index = controller.index;
      if (index == _lastReported) return;
      _lastReported = index;
      if (index < 0 || index >= widget.tabs.length) return;
      final parent = widget.parent;
      final name = index == 0 && widget.firstTabIsParent
          ? parent
          : subScreenPath(parent, widget.tabs[index]);
      final client = widget.client ?? Dash0.client;
      if (client == null) return;
      trackScreenView(client, name, changeState: 'tab');
    } catch (_) {}
  }

  @override
  void dispose() {
    _attached?.removeListener(_onChange);
    _attached = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
