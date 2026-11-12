import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  group('Dash0Options.validate', () {
    test('accepts a valid configuration', () {
      const Dash0Options(serviceName: 'app', endpoint: testEndpoint).validate();
    });

    test('rejects an empty service name', () {
      expect(
        () => const Dash0Options(serviceName: ' ', endpoint: testEndpoint)
            .validate(),
        throwsArgumentError,
      );
    });

    test('rejects sampling rates outside 0..100', () {
      for (final rate in [-1, 101]) {
        expect(
          () => Dash0Options(
            serviceName: 'app',
            endpoint: testEndpoint,
            sessionSamplingRate: rate,
          ).validate(),
          throwsArgumentError,
        );
      }
    });

    test('requires an endpoint', () {
      expect(
        () => const Dash0Options(serviceName: 'app').validate(),
        throwsArgumentError,
      );
    });

    test('requires absolute urls and a token', () {
      expect(
        () => const Dash0Options(
          serviceName: 'app',
          endpoint: Dash0Endpoint(url: 'not a url', authToken: 'x'),
        ).validate(),
        throwsArgumentError,
      );
      expect(
        () => const Dash0Options(
          serviceName: 'app',
          endpoint: Dash0Endpoint(url: 'https://a.example', authToken: ''),
        ).validate(),
        throwsArgumentError,
      );
    });

    test('combines endpoint and endpoints', () {
      const o = Dash0Options(
        serviceName: 'app',
        endpoint: testEndpoint,
        endpoints: [testEndpoint],
      );
      expect(o.allEndpoints, hasLength(2));
    });
  });

  group('service name', () {
    test('suspicious names fall back', () {
      const o = Dash0Options(
        serviceName: 'x"><script>',
        endpoint: testEndpoint,
      );
      expect(o.effectiveServiceName, 'unknown_service:flutter');
    });

    test('safe names and slashes are kept', () {
      const o = Dash0Options(serviceName: 'team/app', endpoint: testEndpoint);
      expect(o.effectiveServiceName, 'team/app');
    });

    test('check can be disabled', () {
      const o = Dash0Options(
        serviceName: 'a;b',
        endpoint: testEndpoint,
        rejectSuspiciousServiceName: false,
      );
      expect(o.effectiveServiceName, 'a;b');
    });
  });

  test('enabledInstrumentations null enables everything', () {
    const all = Dash0Options(serviceName: 'a', endpoint: testEndpoint);
    expect(all.isEnabled(Dash0Instrumentation.http), isTrue);
    const some = Dash0Options(
      serviceName: 'a',
      endpoint: testEndpoint,
      enabledInstrumentations: {Dash0Instrumentation.error},
    );
    expect(some.isEnabled(Dash0Instrumentation.http), isFalse);
    expect(some.isEnabled(Dash0Instrumentation.error), isTrue);
  });
}
