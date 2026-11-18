import 'client_probe_stub.dart' show ViewportProbe, WebProbe;

/// Access to the browser objects the probe needs. Each getter may throw; the
/// readers below guard every read on its own, so one failing read (for
/// example `navigator.userAgentData` in a locked down browser) cannot drop
/// the others, in particular not `navigator.userAgent`.
abstract class NavigatorSource {
  String? get userAgent;
  int? get maxTouchPoints;
  bool? get uaDataMobile;
  String? get uaDataPlatform;
  List<String>? get uaDataBrands;
  int? get innerWidth;
  int? get innerHeight;
  String? get connectionEffectiveType;
}

T? _guard<T>(T? Function() read) {
  try {
    return read();
  } catch (_) {
    return null;
  }
}

/// Builds a [WebProbe]. Never throws, every field is read independently.
WebProbe readWebProbe(NavigatorSource nav) {
  return WebProbe(
    userAgent: _guard(() => nav.userAgent),
    maxTouchPoints: _guard(() => nav.maxTouchPoints) ?? 0,
    uaDataMobile: _guard(() => nav.uaDataMobile),
    uaDataPlatform: _guard(() => nav.uaDataPlatform),
    brands: _guard(() => nav.uaDataBrands) ?? const [],
  );
}

/// Builds a [ViewportProbe]. Never throws.
ViewportProbe readViewportProbe(NavigatorSource nav) {
  return ViewportProbe(
    width: _guard(() => nav.innerWidth),
    height: _guard(() => nav.innerHeight),
    connectionType: _guard(() => nav.connectionEffectiveType),
  );
}
