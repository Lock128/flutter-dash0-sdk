/// Browser data, see `client_probe_web.dart`.
class WebProbe {
  const WebProbe({
    this.userAgent,
    this.uaDataMobile,
    this.uaDataPlatform,
    this.brands = const [],
    this.maxTouchPoints = 0,
  });

  /// `navigator.userAgent`.
  final String? userAgent;

  /// `navigator.userAgentData.mobile`, null in Safari and Firefox.
  final bool? uaDataMobile;

  /// `navigator.userAgentData.platform`.
  final String? uaDataPlatform;

  /// Brand names of `navigator.userAgentData.brands`.
  final List<String> brands;

  /// `navigator.maxTouchPoints`.
  final int maxTouchPoints;
}

/// Window size and connection type, read at emission time.
class ViewportProbe {
  const ViewportProbe({this.width, this.height, this.connectionType});

  /// `window.innerWidth`.
  final int? width;

  /// `window.innerHeight`.
  final int? height;

  /// `navigator.connection.effectiveType` (`4g`, `3g`, ...).
  final String? connectionType;
}

/// Reads `navigator`. There is no browser here.
WebProbe? probeWeb() => null;

/// Reads the window size. There is no browser here.
ViewportProbe? probeViewport() => null;
