import 'dart:js_interop';

import 'client_probe_reader.dart';
import 'client_probe_stub.dart' show ViewportProbe, WebProbe;

export 'client_probe_stub.dart' show ViewportProbe, WebProbe;

@JS('navigator')
external _Navigator? get _navigator;

@JS('innerWidth')
external JSNumber? get _innerWidth;

@JS('innerHeight')
external JSNumber? get _innerHeight;

extension type _Navigator._(JSObject _) implements JSObject {
  external JSString? get userAgent;
  external JSNumber? get maxTouchPoints;
  external _UserAgentData? get userAgentData;
  external _Connection? get connection;
}

extension type _UserAgentData._(JSObject _) implements JSObject {
  external JSBoolean? get mobile;
  external JSString? get platform;
  external JSArray<_Brand>? get brands;
}

extension type _Brand._(JSObject _) implements JSObject {
  external JSString? get brand;
}

extension type _Connection._(JSObject _) implements JSObject {
  external JSString? get effectiveType;
}

/// Each getter throws or returns null on its own, [readWebProbe] and
/// [readViewportProbe] guard every one separately.
class _JsNavigatorSource implements NavigatorSource {
  @override
  String? get userAgent => _navigator?.userAgent?.toDart;

  @override
  int? get maxTouchPoints => _navigator?.maxTouchPoints?.toDartInt;

  @override
  bool? get uaDataMobile => _navigator?.userAgentData?.mobile?.toDart;

  @override
  String? get uaDataPlatform => _navigator?.userAgentData?.platform?.toDart;

  @override
  List<String>? get uaDataBrands => [
        for (final b
            in _navigator?.userAgentData?.brands?.toDart ?? const <_Brand>[])
          if (b.brand != null) b.brand!.toDart,
      ];

  @override
  int? get innerWidth => _innerWidth?.toDartInt;

  @override
  int? get innerHeight => _innerHeight?.toDartInt;

  @override
  String? get connectionEffectiveType =>
      _navigator?.connection?.effectiveType?.toDart;
}

final _source = _JsNavigatorSource();

/// Reads `navigator`. Never throws.
WebProbe? probeWeb() {
  try {
    return readWebProbe(_source);
  } catch (_) {
    return null;
  }
}

/// Reads the window size and connection type. Never throws.
ViewportProbe? probeViewport() {
  try {
    return readViewportProbe(_source);
  } catch (_) {
    return null;
  }
}
