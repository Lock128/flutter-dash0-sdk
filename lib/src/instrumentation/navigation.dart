import 'package:flutter/widgets.dart';

import '../client.dart';
import '../dash0.dart';
import '../options.dart';
import '../semantic_conventions.dart' as sc;

/// A page view that was requested while the client was disabled.
class PendingScreenView {
  PendingScreenView(this.screenName, this.changeState, this.attributes);

  final String screenName;
  final String? changeState;
  final Map<String, Object?>? attributes;
}

/// A [NavigatorObserver] that sends an `app.page_view` event whenever the
/// visible screen changes. Works with `Navigator`, `MaterialApp` and
/// `go_router` (`GoRouter(observers: [observer])`).
///
/// A route is named by, in this order, `Dash0Options.screenNameResolver`,
/// `RouteSettings.name` and, unless `Dash0Options.nameUnnamedRoutes` is false,
/// the type of the page widget it shows (`/StatisticsScreen`). Query strings
/// are removed from names.
///
/// A `NavigatorObserver` can only observe one `Navigator`. Create one
/// observer per navigator with `Dash0.createNavigatorObserver()`.
class Dash0NavigatorObserver extends NavigatorObserver {
  /// Creates an observer. Without [client] the client created by
  /// `Dash0.init` is used, so the observer may be created before init.
  Dash0NavigatorObserver([this._explicitClient]);

  final Dash0Client? _explicitClient;

  /// Names derived from the widget tree, so that popping back to an unnamed
  /// route reports the same name as when it was pushed.
  final Expando<String> _derivedNames = Expando<String>('dash0 route names');

  Dash0Client? get _client => _explicitClient ?? Dash0.client;

  /// The screen name of the most recent page view.
  String? get currentScreen => _client?.currentScreen;

  /// The name of [route] without trying to derive one from the widget tree.
  String? _explicitName(Route<dynamic> route, Dash0Client client) {
    if (route is PopupRoute && !client.options.trackPopupRoutes) return null;
    String? name;
    try {
      name = client.options.screenNameResolver?.call(route);
    } catch (_) {
      name = null;
    }
    return normalizeScreenName(name ?? route.settings.name);
  }

  /// The name of [route], deriving it from the widget tree if it is
  /// currently built. Returns null if it has no name (yet).
  String? _nameOf(Route<dynamic>? route) {
    final client = _client;
    if (route == null || client == null) return null;
    try {
      final explicit = _explicitName(route, client);
      if (explicit != null) return explicit;
      if (!_canDerive(route, client)) return null;
      return _derivedNames[route] ?? _derive(route);
    } catch (_) {
      return null;
    }
  }

  bool _canDerive(Route<dynamic> route, Dash0Client client) =>
      client.options.nameUnnamedRoutes &&
      route is ModalRoute &&
      (route is! PopupRoute || client.options.trackPopupRoutes);

  String? _derive(Route<dynamic> route) {
    final context = (route as ModalRoute<dynamic>).subtreeContext;
    final type = context == null ? null : pageWidgetTypeName(context);
    if (type == null) return null;
    final name = route is PopupRoute ? '/popup/$type' : '/$type';
    _derivedNames[route] = name;
    return name;
  }

  void _trackNew(Route<dynamic>? route, String change) {
    final client = _client;
    if (route == null || client == null) return;
    final name = _nameOf(route);
    if (name != null) {
      _track(name, change);
      return;
    }
    if (_explicitName(route, client) != null || !_canDerive(route, client)) {
      return;
    }
    // The page widget is only known once the route has been built.
    _deriveLater(route, change, 2);
  }

  void _deriveLater(Route<dynamic> route, String change, int attemptsLeft) {
    try {
      final binding = WidgetsBinding.instance;
      binding.addPostFrameCallback((_) {
        try {
          if (!route.isCurrent) return;
          final name = _nameOf(route);
          if (name != null) {
            _track(name, change);
          } else if (attemptsLeft > 1) {
            _deriveLater(route, change, attemptsLeft - 1);
          }
        } catch (_) {
          // Telemetry must never throw into the app.
        }
      });
      binding.scheduleFrame();
    } catch (_) {
      // Telemetry must never throw into the app.
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _trackNew(route, 'push');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _trackNew(newRoute, 'replace');

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _track(_nameOf(previousRoute), 'pop');

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _track(_nameOf(previousRoute), 'remove');

  void _track(String? name, String change) {
    final client = _client;
    if (name == null || name.isEmpty || client == null) return;
    trackScreenView(client, name, changeState: change);
  }
}

/// Removes the query string and fragment from a route name. Returns null for
/// empty names.
String? normalizeScreenName(String? name) {
  if (name == null) return null;
  var end = name.length;
  for (final separator in const ['?', '#']) {
    final i = name.indexOf(separator);
    if (i >= 0 && i < end) end = i;
  }
  final result = name.substring(0, end);
  return result.isEmpty ? null : result;
}

/// Widgets of the framework that wrap the page of a route.
const _frameworkWrappers = {
  'Builder',
  'StatefulBuilder',
  'LayoutBuilder',
  'RestorationScope',
  'UnmanagedRestorationScope',
  'FocusScope',
  'FocusTraversalGroup',
  'Focus',
  'Actions',
  'Shortcuts',
  'PageStorage',
  'Theme',
  'AnimatedTheme',
  'Material',
  'MediaQuery',
  'Directionality',
  'DefaultTextStyle',
  'AnimatedBuilder',
  'ListenableBuilder',
  'ValueListenableBuilder',
  'Semantics',
  'Offstage',
  'TickerMode',
  'IgnorePointer',
  'AbsorbPointer',
  'Visibility',
  'KeyedSubtree',
  'RepaintBoundary',
  'ModalBarrier',
  'AnimatedModalBarrier',
  'SafeArea',
  'Center',
  'Align',
  'Padding',
  'ConstrainedBox',
  'DisplayFeatureSubScreen',
  'Dialog',
};

/// Name of the type of the first widget below [context] that is not a
/// framework wrapper or private, usually the page widget of a route.
String? pageWidgetTypeName(BuildContext context) {
  String? found;
  var visited = 0;
  bool visit(Element element) {
    if (++visited > 60) return true;
    final widget = element.widget;
    if (widget is StatelessWidget || widget is StatefulWidget) {
      final type = widget.runtimeType.toString();
      if (!type.startsWith('_') && !_frameworkWrappers.contains(type)) {
        found = type.split('<').first;
        return true;
      }
    }
    var done = false;
    element.visitChildren((child) {
      if (!done) done = visit(child);
    });
    return done;
  }

  context.visitChildElements((child) => visit(child));
  return found;
}

/// Sends a page view for [screenName] and makes it the current screen.
///
/// Consecutive views of the same screen are ignored. While the client is
/// disabled nothing is sent and the screen is not marked as seen. The latest
/// such view is sent once the client is enabled.
void trackScreenView(
  Dash0Client client,
  String screenName, {
  String? changeState,
  Map<String, Object?>? attributes,
}) {
  if (!client.options.isEnabled(Dash0Instrumentation.navigation)) return;
  if (!client.isEnabled) {
    client.pendingScreenView =
        PendingScreenView(screenName, changeState, attributes);
    return;
  }
  client.pendingScreenView = null;
  final previous = client.currentScreen;
  if (previous == screenName) return;
  final now = client.nowMillisSinceEpoch();
  final shownAt = client.screenShownAtMillis;
  client.vitals?.onScreenChange();
  client.currentScreen = screenName;
  client.screenShownAtMillis = now;
  client.replay?.onNavigation(screenName, changeState);

  final meta = _safeMeta(client, screenName);
  client.emitEvent(
    client.names.pageView,
    title: meta?.title ?? screenName,
    attributes: {
      sc.pageViewType:
          previous == null ? sc.pageViewTypeInitial : sc.pageViewTypeVirtual,
      if (changeState != null) sc.pageViewChangeState: changeState,
      if (previous != null) sc.pageViewReferrer: previous,
      if (previous != null && shownAt != null && now >= shownAt)
        sc.pageViewPreviousDuration: now - shownAt,
      ...meta?.attributes ?? const {},
      ...attributes ?? const {},
    },
  );
}

Dash0PageViewMeta? _safeMeta(Dash0Client client, String screenName) {
  try {
    return client.options.generatePageViewMetadata?.call(screenName);
  } catch (_) {
    return null;
  }
}
