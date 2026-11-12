import 'package:dash0_flutter_sdk/src/otlp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encodes primitives with OTLP value kinds', () {
    expect(toAnyValue('a'), {'stringValue': 'a'});
    expect(toAnyValue(true), {'boolValue': true});
    expect(toAnyValue(3), {'intValue': '3'});
    expect(toAnyValue(1.5), {'doubleValue': 1.5});
    expect(toAnyValue(null), isNull);
  });

  test('encodes arrays and maps', () {
    expect(toAnyValue(['a', 1]), {
      'arrayValue': {
        'values': [
          {'stringValue': 'a'},
          {'intValue': '1'},
        ],
      },
    });
    expect(toAnyValue({'k': 'v'}), {
      'kvlistValue': {
        'values': [
          {
            'key': 'k',
            'value': {'stringValue': 'v'},
          },
        ],
      },
    });
  });

  test('encodeAttributes skips null values and empty keys', () {
    final encoded = encodeAttributes({'a': 'x', 'b': null, '': 'y'});
    expect(encoded, [
      {
        'key': 'a',
        'value': {'stringValue': 'x'},
      },
    ]);
  });

  test('toNanos converts to nanoseconds', () {
    final t = DateTime.utc(2024, 1, 1);
    expect(toNanos(t), t.millisecondsSinceEpoch * 1000000);
  });
}
