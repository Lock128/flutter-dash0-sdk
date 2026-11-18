import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:dash0_flutter_sdk/src/propagation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const traceId = '4efaaf4d1e8720b39541901950019ee5';
  const spanId = '0123456789abcdef';

  test('formats a W3C traceparent', () {
    expect(formatTraceparent(traceId, spanId), '00-$traceId-$spanId-01');
  });

  test('parses valid traceparents and rejects invalid ones', () {
    final parsed = parseTraceparent('00-$traceId-$spanId-01');
    expect(parsed?.traceId, traceId);
    expect(parsed?.spanId, spanId);
    expect(parseTraceparent('garbage'), isNull);
    expect(parseTraceparent('00-${'0' * 32}-$spanId-01'), isNull);
    expect(parseTraceparent('00-$traceId-${'0' * 16}-01'), isNull);
  });

  test('formats an X-Ray header', () {
    expect(
      formatXRayHeader(traceId, spanId),
      'Root=1-4efaaf4d-1e8720b39541901950019ee5;Parent=$spanId;Sampled=1',
    );
  });

  test('selects propagators by url', () {
    final propagators = [
      Dash0Propagator.traceparent([RegExp(r'^https://api\.example\.com')]),
      Dash0Propagator(
        type: Dash0PropagatorType.xray,
        match: [RegExp(r'amazonaws\.com')],
      ),
    ];
    expect(
      determinePropagatorTypes(propagators, 'https://api.example.com/x'),
      [Dash0PropagatorType.traceparent],
    );
    expect(
      determinePropagatorTypes(propagators, 'https://x.amazonaws.com/y'),
      [Dash0PropagatorType.xray],
    );
    expect(determinePropagatorTypes(propagators, 'https://other.io'), isEmpty);
  });

  test('builds headers for each type', () {
    final headers = traceContextHeaders(
      [Dash0PropagatorType.traceparent, Dash0PropagatorType.xray],
      traceId,
      spanId,
    );
    expect(headers['traceparent'], '00-$traceId-$spanId-01');
    expect(headers['X-Amzn-Trace-Id'], contains('Parent=$spanId'));
  });

  test('propagator match accepts strings and regular expressions', () {
    final propagators = [
      Dash0Propagator.traceparent(['api.example.com', RegExp(r'\.internal/')]),
    ];
    expect(
      determinePropagatorTypes(propagators, 'https://api.example.com/x'),
      [Dash0PropagatorType.traceparent],
    );
    expect(
      determinePropagatorTypes(propagators, 'https://a.internal/x'),
      [Dash0PropagatorType.traceparent],
    );
    expect(determinePropagatorTypes(propagators, 'https://other.io'), isEmpty);
  });

  group('same origin on web', () {
    final propagators = [
      Dash0Propagator(
        type: Dash0PropagatorType.xray,
        match: [RegExp(r'amazonaws\.com')],
      ),
    ];

    test('adds traceparent and all configured types', () {
      expect(
        determinePropagatorTypes(
          propagators,
          'https://app.example.com/api/items',
          pageOrigin: 'https://app.example.com',
        ),
        [Dash0PropagatorType.traceparent, Dash0PropagatorType.xray],
      );
    });

    test('other origins use the match rules', () {
      expect(
        determinePropagatorTypes(
          propagators,
          'https://other.example.com/api',
          pageOrigin: 'https://app.example.com',
        ),
        isEmpty,
      );
      expect(
        determinePropagatorTypes(
          propagators,
          'http://app.example.com/api',
          pageOrigin: 'https://app.example.com',
        ),
        isEmpty,
      );
    });

    test('default ports are the same origin', () {
      expect(
          originOf('https://App.example.com:443/x'), 'https://app.example.com');
      expect(
        determinePropagatorTypes(
          const [],
          'https://app.example.com:443/x',
          pageOrigin: 'https://app.example.com',
        ),
        [Dash0PropagatorType.traceparent],
      );
    });

    test('relative urls and other schemes get no same-origin headers', () {
      expect(originOf('/api/items'), isNull);
      expect(originOf('ftp://app.example.com/x'), isNull);
      expect(
        determinePropagatorTypes(
          const [],
          '/api/items',
          pageOrigin: 'https://app.example.com',
        ),
        isEmpty,
      );
    });

    test('without a page origin nothing changes', () {
      expect(determinePropagatorTypes(const [], 'https://app.example.com/x'),
          isEmpty);
    });
  });
}
