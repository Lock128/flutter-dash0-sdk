/// Helpers to build OTLP/JSON structures.
library;

/// An OTLP attribute map before encoding. Values may be `String`, `bool`,
/// `int`, `double`, `List` or `Map<String, Object?>`.
typedef Attributes = Map<String, Object?>;

/// Converts a Dart value to an OTLP `AnyValue`. Returns null for null.
Map<String, Object?>? toAnyValue(Object? value) {
  if (value == null) return null;
  if (value is String) return {'stringValue': value};
  if (value is bool) return {'boolValue': value};
  if (value is int) return {'intValue': value.toString()};
  if (value is num) return {'doubleValue': value.toDouble()};
  if (value is Iterable) {
    return {
      'arrayValue': {
        'values': [
          for (final e in value)
            if (e != null) toAnyValue(e),
        ],
      },
    };
  }
  if (value is Map) {
    return {
      'kvlistValue': {
        'values': [
          for (final e in value.entries)
            if (e.value != null) toKeyValue(e.key.toString(), e.value),
        ],
      },
    };
  }
  return {'stringValue': value.toString()};
}

/// Converts a key and value to an OTLP `KeyValue`.
Map<String, Object?> toKeyValue(String key, Object? value) {
  return {'key': key, 'value': toAnyValue(value)};
}

/// Encodes an attribute map as a list of OTLP `KeyValue`s. Null values and
/// empty keys are skipped.
List<Map<String, Object?>> encodeAttributes(Attributes? attributes) {
  if (attributes == null) return [];
  return [
    for (final e in attributes.entries)
      if (e.key.isNotEmpty && e.value != null) toKeyValue(e.key, e.value),
  ];
}

/// Converts a time to nanoseconds since the Unix epoch.
int toNanos(DateTime time) => time.microsecondsSinceEpoch * 1000;

/// Current time in nanoseconds since the Unix epoch.
int nowNanos() => toNanos(DateTime.now());
