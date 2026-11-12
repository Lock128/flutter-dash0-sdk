import '../debug.dart';
import '../options.dart';
import '../otlp.dart';

/// Maximum number of distinct attribute sets per instrument. Further sets are
/// dropped to protect against unbounded memory growth.
const maxSeriesPerInstrument = 2000;

/// Default histogram bucket bounds, suited for durations in seconds.
const defaultHistogramBoundaries = <double>[
  0.005,
  0.01,
  0.025,
  0.05,
  0.075,
  0.1,
  0.25,
  0.5,
  0.75,
  1,
  2.5,
  5,
  7.5,
  10,
];

String _seriesKey(Attributes? attributes) {
  if (attributes == null || attributes.isEmpty) return '';
  final keys = attributes.keys.toList()..sort();
  return [for (final k in keys) '$k=${attributes[k]}'].join('\u0000');
}

Map<String, Object?> _number(num value) =>
    value is int ? {'asInt': value.toString()} : {'asDouble': value.toDouble()};

int _temporalityValue(Dash0AggregationTemporality t) =>
    t == Dash0AggregationTemporality.delta ? 1 : 2;

/// Base of all instruments. Instruments are created through `Dash0.counter`,
/// `Dash0.histogram` and friends.
abstract class Dash0Instrument<S> {
  Dash0Instrument(
    this.name,
    this.unit,
    this.description,
    this._accepts,
    this._creationNanos,
  );

  final String name;
  final String? unit;
  final String? description;
  final bool Function() _accepts;
  final int _creationNanos;
  final Map<String, S> _series = {};
  bool _overflowLogged = false;

  S newSeries(Attributes attributes, int nowNanos);

  /// Returns the series for [attributes], or null when recording is off or
  /// the cardinality limit is reached.
  S? seriesFor(Attributes? attributes) {
    if (!_accepts()) return null;
    final key = _seriesKey(attributes);
    final existing = _series[key];
    if (existing != null) return existing;
    if (_series.length >= maxSeriesPerInstrument) {
      if (!_overflowLogged) {
        _overflowLogged = true;
        dash0Debug('Metric $name reached the limit of $maxSeriesPerInstrument '
            'attribute sets, dropping new ones.');
      }
      return null;
    }
    final series = newSeries(
      {...?attributes}..removeWhere((k, v) => v == null),
      nowNanos(),
    );
    _series[key] = series;
    return series;
  }

  /// Number of tracked attribute sets.
  int get seriesCount => _series.length;

  /// OTLP metric, or null when there is nothing to export.
  Map<String, Object?>? collect(
    Dash0AggregationTemporality temporality,
    int nowNanos,
  );

  Map<String, Object?> _base() => {
        'name': name,
        if (unit != null) 'unit': unit,
        if (description != null) 'description': description,
      };
}

class MetricSumSeries {
  MetricSumSeries(this.attributes, this.startNanos);
  final Attributes attributes;
  int startNanos;
  num value = 0;
  bool dirty = false;
}

class _SumInstrument extends Dash0Instrument<MetricSumSeries> {
  _SumInstrument(
    super.name,
    super.unit,
    super.description,
    super._accepts,
    super._creationNanos, {
    required this.monotonic,
  });

  final bool monotonic;

  @override
  MetricSumSeries newSeries(Attributes attributes, int nowNanos) =>
      MetricSumSeries(attributes, nowNanos);

  void _add(num value, Attributes? attributes) {
    if (value.isNaN || value.isInfinite) return;
    final series = seriesFor(attributes);
    if (series == null) return;
    series.value += value;
    series.dirty = true;
  }

  @override
  Map<String, Object?>? collect(
    Dash0AggregationTemporality temporality,
    int nowNanos,
  ) {
    final delta = temporality == Dash0AggregationTemporality.delta;
    final points = <Map<String, Object?>>[];
    for (final s in _series.values) {
      if (delta && !s.dirty) continue;
      points.add({
        'attributes': encodeAttributes(s.attributes),
        'startTimeUnixNano': (delta ? s.startNanos : _creationNanos).toString(),
        'timeUnixNano': nowNanos.toString(),
        ..._number(s.value),
      });
      if (delta) {
        s.value = 0;
        s.startNanos = nowNanos;
      }
      s.dirty = false;
    }
    if (points.isEmpty) return null;
    return {
      ..._base(),
      'sum': {
        'dataPoints': points,
        'aggregationTemporality': _temporalityValue(temporality),
        'isMonotonic': monotonic,
      },
    };
  }
}

/// A value that only increases, for example the number of requests.
class Dash0Counter extends _SumInstrument {
  Dash0Counter(
    super.name,
    super.unit,
    super.description,
    super._accepts,
    super._creationNanos,
  ) : super(monotonic: true);

  /// A counter that records nothing.
  Dash0Counter.noop(String name) : this(name, null, null, () => false, 0);

  /// Adds [value] (must not be negative).
  void add(num value, {Attributes? attributes}) {
    if (value < 0) {
      dash0Debug('Counter $name ignores negative value $value');
      return;
    }
    _add(value, attributes);
  }
}

/// A value that can go up and down, for example the number of open
/// connections.
class Dash0UpDownCounter extends _SumInstrument {
  Dash0UpDownCounter(
    super.name,
    super.unit,
    super.description,
    super._accepts,
    super._creationNanos,
  ) : super(monotonic: false);

  Dash0UpDownCounter.noop(String name) : this(name, null, null, () => false, 0);

  void add(num value, {Attributes? attributes}) => _add(value, attributes);
}

class MetricHistogramSeries {
  MetricHistogramSeries(this.attributes, this.startNanos, int buckets)
      : counts = List<int>.filled(buckets, 0);
  final Attributes attributes;
  int startNanos;
  final List<int> counts;
  int count = 0;
  double sum = 0;
  double min = double.infinity;
  double max = double.negativeInfinity;
}

/// Distribution of values, for example request durations.
class Dash0Histogram extends Dash0Instrument<MetricHistogramSeries> {
  Dash0Histogram(
    super.name,
    super.unit,
    super.description,
    super._accepts,
    super._creationNanos, {
    List<double> boundaries = defaultHistogramBoundaries,
  }) : boundaries = List.unmodifiable(boundaries.toList()..sort());

  Dash0Histogram.noop(String name) : this(name, null, null, () => false, 0);

  /// Upper bounds of the buckets, ascending.
  final List<double> boundaries;

  @override
  MetricHistogramSeries newSeries(Attributes attributes, int nowNanos) =>
      MetricHistogramSeries(attributes, nowNanos, boundaries.length + 1);

  /// Records one observation.
  void record(num value, {Attributes? attributes}) {
    if (value.isNaN || value.isInfinite) return;
    final series = seriesFor(attributes);
    if (series == null) return;
    final v = value.toDouble();
    var i = 0;
    while (i < boundaries.length && v > boundaries[i]) {
      i++;
    }
    series.counts[i]++;
    series.count++;
    series.sum += v;
    if (v < series.min) series.min = v;
    if (v > series.max) series.max = v;
  }

  @override
  Map<String, Object?>? collect(
    Dash0AggregationTemporality temporality,
    int nowNanos,
  ) {
    final delta = temporality == Dash0AggregationTemporality.delta;
    final points = <Map<String, Object?>>[];
    for (final s in _series.values) {
      if (s.count == 0) continue;
      points.add({
        'attributes': encodeAttributes(s.attributes),
        'startTimeUnixNano': (delta ? s.startNanos : _creationNanos).toString(),
        'timeUnixNano': nowNanos.toString(),
        'count': s.count.toString(),
        'sum': s.sum,
        'min': s.min,
        'max': s.max,
        'bucketCounts': [for (final c in s.counts) c.toString()],
        'explicitBounds': boundaries,
      });
      if (delta) {
        s.counts.fillRange(0, s.counts.length, 0);
        s.count = 0;
        s.sum = 0;
        s.min = double.infinity;
        s.max = double.negativeInfinity;
        s.startNanos = nowNanos;
      }
    }
    if (points.isEmpty) return null;
    return {
      ..._base(),
      'histogram': {
        'dataPoints': points,
        'aggregationTemporality': _temporalityValue(temporality),
      },
    };
  }
}

class MetricGaugeSeries {
  MetricGaugeSeries(this.attributes);
  final Attributes attributes;
  num value = 0;
  int timeNanos = 0;
  bool dirty = false;
}

/// The latest value of something, for example the free memory.
class Dash0Gauge extends Dash0Instrument<MetricGaugeSeries> {
  Dash0Gauge(
    super.name,
    super.unit,
    super.description,
    super._accepts,
    super._creationNanos,
  );

  Dash0Gauge.noop(String name) : this(name, null, null, () => false, 0);

  @override
  MetricGaugeSeries newSeries(Attributes attributes, int nowNanos) =>
      MetricGaugeSeries(attributes);

  /// Sets the current value.
  void record(num value, {Attributes? attributes}) {
    if (value.isNaN || value.isInfinite) return;
    final series = seriesFor(attributes);
    if (series == null) return;
    series.value = value;
    series.timeNanos = nowNanos();
    series.dirty = true;
  }

  @override
  Map<String, Object?>? collect(
    Dash0AggregationTemporality temporality,
    int nowNanos,
  ) {
    final points = <Map<String, Object?>>[];
    for (final s in _series.values) {
      if (!s.dirty) continue;
      points.add({
        'attributes': encodeAttributes(s.attributes),
        'timeUnixNano': s.timeNanos.toString(),
        ..._number(s.value),
      });
      s.dirty = false;
    }
    if (points.isEmpty) return null;
    return {
      ..._base(),
      'gauge': {'dataPoints': points},
    };
  }
}
