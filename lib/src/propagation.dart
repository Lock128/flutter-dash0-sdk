import 'ignore_rules.dart';
import 'options.dart';

/// Header value for a W3C `traceparent` header.
///
/// See https://www.w3.org/TR/trace-context/#traceparent-header. Only the
/// sampled flag is set.
String formatTraceparent(String traceId, String spanId) =>
    '00-$traceId-$spanId-01';

/// Header value for an AWS X-Ray `X-Amzn-Trace-Id` header. The 32 character
/// trace id is split into a time part (8) and a unique part (24).
String formatXRayHeader(String traceId, String spanId) {
  final timestamp = traceId.substring(0, 8);
  final unique = traceId.substring(8, 32);
  return 'Root=1-$timestamp-$unique;Parent=$spanId;Sampled=1';
}

final RegExp _traceparentPattern =
    RegExp(r'^00-([a-f0-9]{32})-([a-f0-9]{16})-[a-f0-9]{2}$');

/// Parses a W3C traceparent value. Returns null if invalid or all zero.
({String traceId, String spanId})? parseTraceparent(String traceparent) {
  final m = _traceparentPattern.firstMatch(traceparent.trim());
  if (m == null) return null;
  final traceId = m.group(1)!;
  final spanId = m.group(2)!;
  final zeros = RegExp(r'^0+$');
  if (zeros.hasMatch(traceId) || zeros.hasMatch(spanId)) return null;
  return (traceId: traceId, spanId: spanId);
}

/// Propagator types that apply to [url].
List<Dash0PropagatorType> determinePropagatorTypes(
  List<Dash0Propagator> propagators,
  String url,
) {
  final types = <Dash0PropagatorType>[];
  for (final p in propagators) {
    if (matchesAny(p.match, url) && !types.contains(p.type)) {
      types.add(p.type);
    }
  }
  return types;
}

/// Trace context headers to send for the given [types].
Map<String, String> traceContextHeaders(
  List<Dash0PropagatorType> types,
  String traceId,
  String spanId,
) {
  return {
    for (final t in types)
      if (t == Dash0PropagatorType.traceparent)
        'traceparent': formatTraceparent(traceId, spanId)
      else
        'X-Amzn-Trace-Id': formatXRayHeader(traceId, spanId),
  };
}
