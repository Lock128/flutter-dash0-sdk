import 'package:flutter/widgets.dart';

import '../client.dart';
import '../dash0.dart';
import '../options.dart';
import '../semantic_conventions.dart' as sc;

/// A [NavigatorObserver] that sends an `app.page_view` event whenever the
/// visible screen changes. Works with `Navigator`, `MaterialApp` and
/// `go_router` (`GoRouter(observers: [observer])`).
///
/// Routes need a name (`RouteSettings.name`) to be useful. Provide
/// `Dash0Options.screenNameResolver` for other schemes.
class Dash0NavigatorObserver extends NavigatorObserver {
  /// Creates an observer. Without [client] the client created by
  /// `Dash0.init` is used, so the observer may be created before init.
  Dash0NavigatorObserver([this._explicitClient]);

  final Dash0Client? _explicitClient;

  Dash0Client? get _client => _explicitClient ?? Dash0.client;

  /// The screen name of the most recent page view.
  String? get currentScreen => _client?.currentScreen;

  String? _nameOf(Route<dynamic>? route) {
    final client = _client;
    if (route == null || client == null) return null;
    // Dialogs, bottom sheets and menus are not screens.
    if (route is PopupRoute) return null;
    final resolver = client.options.screenNameResolver;
    if (resolver != null) {
      final resolved = resolver(route);
      if (resolved != null) return resolved;
    }
    return route.settings.name;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _track(_nameOf(route), 'push');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _track(_nameOf(newRoute), 'replace');

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

/// Sends a page view for [screenName] and makes it the current screen.
///
/// Consecutive views of the same screen are ignored.
void trackScreenView(
  Dash0Client client,
  String screenName, {
  String? changeState,
  Map<String, Object?>? attributes,
}) {
  if (!client.options.isEnabled(Dash0Instrumentation.navigation)) return;
  final previous = client.currentScreen;
  if (previous == screenName) return;
  client.vitals?.onScreenChange();
  client.currentScreen = screenName;
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
