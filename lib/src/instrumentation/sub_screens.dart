import 'package:flutter/widgets.dart';

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

/// Sends a page view whenever the selected tab of a tab controller changes.
///
/// Wrap the screen's `TabBar`/`TabBarView` with it. It is not tied to one
/// controller class, so it works with the Flutter `TabController`, the
/// `material_ui` one and `DefaultTabController.of(context)`:
///
/// ```dart
/// Dash0TabObserver(
///   parent: '/admin',
///   tabs: ['Overview', 'Failed Payments', 'Disputes'],
///   controller: _tabController,
///   index: () => _tabController.index,
///   isChanging: () => _tabController.indexIsChanging,
///   child: Column(children: [TabBar(...), Expanded(child: TabBarView(...))]),
/// )
/// ```
///
/// Taps, `animateTo` and swipes are all reported. A change is reported once
/// it has settled: not while the tab is animating towards its new index
/// ([isChanging] is true) and not when the index did not change.
///
/// Tab `i` is reported as `subScreenPath(parent, tabs[i])`. [parent] must be
/// the name of the route that shows the tabs, so that the tab names extend
/// the route's own page view. With [firstTabIsParent] (the default) the
/// first tab is reported as [parent] itself, which is what the navigator
/// observer already sent when the route was pushed. The initial tab is then
/// not sent twice. Set it to false to report `<parent>/<tabs[0]>` as well.
/// A controller that starts at another index than 0 reports its initial tab.
class Dash0TabObserver extends StatefulWidget {
  const Dash0TabObserver({
    super.key,
    required this.parent,
    required this.tabs,
    required this.controller,
    required this.index,
    required this.child,
    this.isChanging,
    this.firstTabIsParent = true,
    this.client,
  });

  /// Page name of the screen that shows the tabs, for example `/admin`.
  final String parent;

  /// Fixed human readable tab names, one per tab, in tab order.
  final List<String> tabs;

  /// The tab controller. It notifies when the index or the animation changes.
  final Listenable controller;

  /// Returns the selected tab index, `controller.index`.
  final int Function() index;

  /// Returns whether the controller is animating to a new tab,
  /// `controller.indexIsChanging`. Defaults to never.
  final bool Function()? isChanging;

  /// Report the first tab as [parent] instead of `<parent>/<tabs[0]>`.
  final bool firstTabIsParent;

  /// Client to report to. Defaults to the client of `Dash0.init`.
  final Dash0Client? client;

  final Widget child;

  @override
  State<Dash0TabObserver> createState() => _Dash0TabObserverState();
}

class _Dash0TabObserverState extends State<Dash0TabObserver> {
  int? _lastReported;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    // The route page view covers the first tab.
    _lastReported = widget.firstTabIsParent ? 0 : null;
    _report();
  }

  @override
  void didUpdateWidget(Dash0TabObserver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
      _lastReported = widget.firstTabIsParent ? 0 : null;
      _report();
    }
  }

  void _onChange() => _report();

  void _report() {
    try {
      if (widget.isChanging?.call() ?? false) return;
      final index = widget.index();
      if (index == _lastReported) return;
      _lastReported = index;
      if (index < 0 || index >= widget.tabs.length) return;
      final client = widget.client ?? Dash0.client;
      if (client == null) return;
      final name = index == 0 && widget.firstTabIsParent
          ? widget.parent
          : subScreenPath(widget.parent, widget.tabs[index]);
      trackScreenView(client, name, changeState: 'tab');
    } catch (_) {}
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
