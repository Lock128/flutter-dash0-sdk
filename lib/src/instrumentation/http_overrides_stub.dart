import '../client.dart';

/// `dart:io` is not available on this platform, so this does nothing. On
/// web use `Dash0HttpClient` instead.
class Dash0HttpOverrides {
  Dash0HttpOverrides(Dash0Client client, {Object? previous});

  /// Whether HTTP overrides can work on this platform.
  static bool get isSupported => false;

  static bool install(Dash0Client client) => false;

  static void uninstall() {}
}
