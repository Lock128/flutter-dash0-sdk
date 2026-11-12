import 'dart:async';

import 'otlp.dart';
import 'semantic_conventions.dart' as sc;

/// A span in progress. Call [end] to send it.
class Dash0Span {
  Dash0Span.internal({
    required this.name,
    required this.traceId,
    required this.spanId,
    required this.parentSpanId,
    required this.kind,
    required this.attributes,
    required void Function(Dash0Span span) onEnd,
    int? startTimeUnixNano,
  })  : startTimeUnixNano = startTimeUnixNano ?? nowNanos(),
        _onEnd = onEnd;

  final String name;
  final String traceId;
  final String spanId;
  final String? parentSpanId;
  final int kind;
  final int startTimeUnixNano;

  /// Mutable span attributes.
  final Attributes attributes;

  final List<Map<String, Object?>> _events = [];
  final void Function(Dash0Span span) _onEnd;
  int _statusCode = sc.spanStatusUnset;
  String? _statusMessage;
  int? _endTimeUnixNano;

  bool get isEnded => _endTimeUnixNano != null;
  int get statusCode => _statusCode;

  void setAttribute(String key, Object? value) {
    if (value == null) {
      attributes.remove(key);
    } else {
      attributes[key] = value;
    }
  }

  void setAttributes(Map<String, Object?> values) =>
      values.forEach(setAttribute);

  void addEvent(String name, {Attributes? attributes, DateTime? time}) {
    _events.add({
      'timeUnixNano': (time != null ? toNanos(time) : nowNanos()).toString(),
      'name': name,
      'attributes': encodeAttributes(attributes),
    });
  }

  /// Records [error] as an `exception` span event and marks the span failed.
  void recordException(Object error, [StackTrace? stackTrace]) {
    final attrs = <String, Object?>{
      sc.exceptionType: error.runtimeType.toString(),
      sc.exceptionMessage: error.toString(),
      if (stackTrace != null) sc.exceptionStacktrace: stackTrace.toString(),
    };
    addEvent(sc.spanEventNameException, attributes: attrs);
    setStatus(sc.spanStatusError, error.toString());
  }

  void setStatus(int code, [String? message]) {
    _statusCode = code;
    _statusMessage = message;
  }

  /// Ends the span and hands it to the transport. Further calls are ignored.
  void end({DateTime? endTime}) {
    if (isEnded) return;
    _endTimeUnixNano = endTime != null ? toNanos(endTime) : nowNanos();
    _onEnd(this);
  }

  /// OTLP/JSON representation. Only valid after [end].
  Map<String, Object?> toJson() => {
        'traceId': traceId,
        'spanId': spanId,
        if (parentSpanId != null) 'parentSpanId': parentSpanId,
        'name': name,
        'kind': kind,
        'startTimeUnixNano': startTimeUnixNano.toString(),
        'endTimeUnixNano': (_endTimeUnixNano ?? nowNanos()).toString(),
        'attributes': encodeAttributes(attributes),
        'events': _events,
        'status': {
          'code': _statusCode,
          if (_statusMessage != null) 'message': _statusMessage,
        },
      };

  static const Object _zoneKey = #dash0CurrentSpan;

  /// The span of the enclosing `Dash0.trace` call, if any.
  static Dash0Span? get current => Zone.current[_zoneKey] as Dash0Span?;

  /// Runs [body] with this span as the current span.
  R runAsCurrent<R>(R Function() body) =>
      runZoned(body, zoneValues: {_zoneKey: this});
}
