import '../debug.dart';
import '../options.dart';
import '../otlp.dart';
import 'instruments.dart';

/// Owns all instruments of a client and turns them into OTLP metrics.
class MetricsRegistry {
  MetricsRegistry({
    required this.accepts,
    required this.temporality,
    this.onInstrumentCreated,
  });

  /// Whether values are recorded right now.
  final bool Function() accepts;
  final Dash0AggregationTemporality temporality;
  final void Function()? onInstrumentCreated;

  final Map<String, Dash0Instrument<Object>> _instruments = {};

  T _get<T extends Dash0Instrument<Object>>(
    String kind,
    String name,
    T Function(int nowNanos) create,
  ) {
    final key = '$kind:$name';
    final existing = _instruments[key];
    if (existing is T) return existing;
    if (_instruments.keys.any((k) => k.endsWith(':$name'))) {
      dash0Warn('Metric $name is already registered with a different type.');
    }
    final created = create(nowNanos());
    _instruments[key] = created;
    onInstrumentCreated?.call();
    return created;
  }

  Dash0Counter counter(String name, {String? unit, String? description}) =>
      _get('counter', name,
          (t) => Dash0Counter(name, unit, description, accepts, t));

  Dash0UpDownCounter upDownCounter(String name,
          {String? unit, String? description}) =>
      _get('updown', name,
          (t) => Dash0UpDownCounter(name, unit, description, accepts, t));

  Dash0Histogram histogram(
    String name, {
    String? unit,
    String? description,
    List<double>? boundaries,
  }) =>
      _get(
        'histogram',
        name,
        (t) => Dash0Histogram(
          name,
          unit,
          description,
          accepts,
          t,
          boundaries: boundaries ?? defaultHistogramBoundaries,
        ),
      );

  Dash0Gauge gauge(String name, {String? unit, String? description}) => _get(
      'gauge', name, (t) => Dash0Gauge(name, unit, description, accepts, t));

  /// Collects all metrics with data. For delta temporality this resets the
  /// aggregation.
  List<Map<String, Object?>> collect() {
    final now = nowNanos();
    return [
      for (final i in _instruments.values)
        if (i.collect(temporality, now) case final m?) m,
    ];
  }
}
