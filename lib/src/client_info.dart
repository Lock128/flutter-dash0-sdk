import 'package:flutter/foundation.dart';

import 'client_probe.dart';
import 'semantic_conventions.dart' as sc;

export 'client_probe.dart' show WebProbe;

/// Where the app runs. Reported as `app.client.type`.
enum Dash0ClientType {
  /// Flutter web in a desktop browser.
  webDesktop('web-desktop'),

  /// Flutter web in a mobile or tablet browser (iOS Safari, Android Chrome,
  /// iPadOS Safari in desktop mode, ...).
  webMobile('web-mobile'),
  ios('ios'),
  android('android'),
  macos('macos'),
  windows('windows'),
  linux('linux'),
  fuchsia('fuchsia');

  const Dash0ClientType(this.value);

  /// The attribute value.
  final String value;
}

/// What the SDK knows about the client the app runs on.
@immutable
class Dash0ClientInfo {
  const Dash0ClientInfo({
    required this.type,
    required this.osName,
    this.browserMobile,
    this.browserPlatform,
    this.browserBrands = const [],
    this.userAgent,
  });

  final Dash0ClientType type;

  /// `os.name`: `iOS`, `Android`, `macOS`, `Windows`, `Linux`, `ChromeOS`,
  /// `Fuchsia`, or null when a web client reveals nothing.
  final String? osName;

  /// `browser.mobile`, web only.
  final bool? browserMobile;

  /// `browser.platform` (the OS as seen by the browser), web only.
  final String? browserPlatform;

  /// `browser.brands` (brand names without versions), web only. Empty when
  /// the browser has no `navigator.userAgentData` (Safari, Firefox).
  final List<String> browserBrands;

  /// `user_agent.original`, web only, and null when not collected.
  final String? userAgent;

  bool get isWeb =>
      type == Dash0ClientType.webDesktop || type == Dash0ClientType.webMobile;

  /// `app.runtime`.
  String get runtime => isWeb ? 'flutter-web' : 'flutter-native';

  /// Low cardinality attributes for the resource, which also covers metrics.
  /// Never contains the raw user agent.
  Map<String, Object?> resourceAttributes() => {
        sc.appClientType: type.value,
        sc.appRuntime: runtime,
        if (osName != null) sc.osName: osName,
        if (browserMobile != null) sc.browserMobile: browserMobile,
        if (browserPlatform != null) sc.browserPlatform: browserPlatform,
        if (browserBrands.isNotEmpty) sc.browserBrands: browserBrands,
      };

  /// Attributes for events, spans and logs. Metrics do not get these.
  Map<String, Object?> signalAttributes({bool includeUserAgent = true}) => {
        sc.appClientType: type.value,
        if (includeUserAgent && userAgent != null)
          sc.userAgentOriginal: userAgent,
      };
}

final _mobileUa =
    RegExp(r'Android|iPhone|iPad|iPod|Mobile', caseSensitive: false);
final _brandNoise = RegExp(r'not.?a.?brand', caseSensitive: false);

/// Classifies the client. Pure: everything is passed in, so it can be tested
/// for any platform.
///
/// On the web, [probe] carries `navigator` data. Mobile is decided by
/// `navigator.userAgentData.mobile` when present, otherwise by the user agent
/// (`Android|iPhone|iPad|iPod|Mobile`). iPadOS Safari in desktop mode sends a
/// macOS user agent, so `Macintosh` with more than one touch point counts as
/// an iPad. Anything running on Android or iOS is mobile, which makes tablets
/// `web-mobile`.
Dash0ClientInfo classifyClient({
  required bool isWeb,
  TargetPlatform? platform,
  WebProbe? probe,
  bool collectUserAgent = true,
}) {
  if (!isWeb) {
    final p = platform ?? TargetPlatform.android;
    return Dash0ClientInfo(
      type: switch (p) {
        TargetPlatform.iOS => Dash0ClientType.ios,
        TargetPlatform.android => Dash0ClientType.android,
        TargetPlatform.macOS => Dash0ClientType.macos,
        TargetPlatform.windows => Dash0ClientType.windows,
        TargetPlatform.linux => Dash0ClientType.linux,
        TargetPlatform.fuchsia => Dash0ClientType.fuchsia,
      },
      osName: switch (p) {
        TargetPlatform.iOS => 'iOS',
        TargetPlatform.android => 'Android',
        TargetPlatform.macOS => 'macOS',
        TargetPlatform.windows => 'Windows',
        TargetPlatform.linux => 'Linux',
        TargetPlatform.fuchsia => 'Fuchsia',
      },
    );
  }

  final ua = probe?.userAgent ?? '';
  final os = _webOsName(ua, probe);
  final mobile = os == 'iOS' ||
      os == 'Android' ||
      (probe?.uaDataMobile ?? _mobileUa.hasMatch(ua));
  final brands = <String>[
    for (final b in probe?.brands ?? const <String>[])
      if (b.isNotEmpty && !_brandNoise.hasMatch(b)) b,
  ];
  return Dash0ClientInfo(
    type: mobile ? Dash0ClientType.webMobile : Dash0ClientType.webDesktop,
    osName: os,
    browserMobile: mobile,
    browserPlatform: os,
    browserBrands: brands,
    userAgent: collectUserAgent && ua.isNotEmpty ? ua : null,
  );
}

String? _webOsName(String ua, WebProbe? probe) {
  // Client hints are more reliable than the frozen user agent.
  switch (probe?.uaDataPlatform?.toLowerCase()) {
    case 'android':
      return 'Android';
    case 'ios':
      return 'iOS';
    case 'macos':
      return 'macOS';
    case 'windows':
      return 'Windows';
    case 'chrome os' || 'chromeos':
      return 'ChromeOS';
    case 'linux':
      return 'Linux';
  }
  if (RegExp(r'iPhone|iPad|iPod').hasMatch(ua)) return 'iOS';
  if (ua.contains('Android')) return 'Android';
  if (ua.contains('CrOS')) return 'ChromeOS';
  if (ua.contains('Macintosh') || ua.contains('Mac OS X')) {
    // iPadOS 13+ Safari in desktop mode.
    return (probe?.maxTouchPoints ?? 0) > 1 ? 'iOS' : 'macOS';
  }
  if (ua.contains('Windows')) return 'Windows';
  if (ua.contains('Linux') || ua.contains('X11')) return 'Linux';
  return null;
}

/// Detects the client of the running app. Never throws.
Dash0ClientInfo detectClientInfo({bool collectUserAgent = true}) {
  try {
    return classifyClient(
      isWeb: kIsWeb,
      platform: kIsWeb ? null : defaultTargetPlatform,
      probe: kIsWeb ? probeWeb() : null,
      collectUserAgent: collectUserAgent,
    );
  } catch (_) {
    return const Dash0ClientInfo(
      type: kIsWeb ? Dash0ClientType.webDesktop : Dash0ClientType.android,
      osName: null,
    );
  }
}
