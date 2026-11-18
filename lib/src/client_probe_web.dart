import 'dart:js_interop';

import 'client_probe_stub.dart' show WebProbe;

export 'client_probe_stub.dart' show WebProbe;

@JS('navigator')
external _Navigator? get _navigator;

extension type _Navigator._(JSObject _) implements JSObject {
  external JSString? get userAgent;
  external JSNumber? get maxTouchPoints;
  external _UserAgentData? get userAgentData;
}

extension type _UserAgentData._(JSObject _) implements JSObject {
  external JSBoolean? get mobile;
  external JSString? get platform;
  external JSArray<_Brand>? get brands;
}

extension type _Brand._(JSObject _) implements JSObject {
  external JSString? get brand;
}

/// Reads `navigator`. Never throws.
WebProbe? probeWeb() {
  try {
    final nav = _navigator;
    if (nav == null) return null;
    final data = nav.userAgentData;
    return WebProbe(
      userAgent: nav.userAgent?.toDart,
      maxTouchPoints: nav.maxTouchPoints?.toDartInt ?? 0,
      uaDataMobile: data?.mobile?.toDart,
      uaDataPlatform: data?.platform?.toDart,
      brands: [
        for (final b in data?.brands?.toDart ?? const <_Brand>[])
          if (b.brand != null) b.brand!.toDart,
      ],
    );
  } catch (_) {
    return null;
  }
}
