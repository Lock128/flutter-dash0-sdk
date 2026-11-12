import 'package:dash0_flutter_sdk/src/ignore_rules.dart';
import 'package:dash0_flutter_sdk/src/rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  final rules = IgnoreRules(
    ignoreUrls: [RegExp(r'/health$'), RegExp(r'analytics\.example\.com')],
    ignoreErrorMessages: [RegExp('ResizeObserver')],
    endpoints: [testEndpoint],
  );

  test('ignores empty, data and transport urls', () {
    expect(rules.isUrlIgnored(null), isTrue);
    expect(rules.isUrlIgnored(''), isTrue);
    expect(rules.isUrlIgnored('DATA:text/plain;base64,AAAA'), isTrue);
    expect(
      rules.isUrlIgnored('https://ingress.example.dash0.com/v1/traces'),
      isTrue,
    );
  });

  test('ignores configured url patterns only', () {
    expect(rules.isUrlIgnored('https://api.example.com/health'), isTrue);
    expect(rules.isUrlIgnored('https://analytics.example.com/x'), isTrue);
    expect(rules.isUrlIgnored('https://api.example.com/items'), isFalse);
  });

  test('ignores configured error messages', () {
    expect(rules.isErrorIgnored('ResizeObserver loop limit'), isTrue);
    expect(rules.isErrorIgnored('Something else'), isFalse);
  });

  group('RateLimiter', () {
    test('limits calls per ten seconds and resets', () {
      var now = DateTime(2024);
      final limiter = RateLimiter(
        maxCallsPerTenSeconds: 3,
        maxCallsPerTenMinutes: 100,
        clock: () => now,
      );
      expect(limiter.isExcessiveUsage(), isFalse);
      expect(limiter.isExcessiveUsage(), isFalse);
      expect(limiter.isExcessiveUsage(), isFalse);
      expect(limiter.isExcessiveUsage(), isTrue);
      now = now.add(const Duration(seconds: 10));
      expect(limiter.isExcessiveUsage(), isFalse);
    });

    test('limits calls per ten minutes', () {
      var now = DateTime(2024);
      final limiter = RateLimiter(
        maxCallsPerTenSeconds: 100,
        maxCallsPerTenMinutes: 2,
        clock: () => now,
      );
      expect(limiter.isExcessiveUsage(), isFalse);
      now = now.add(const Duration(seconds: 30));
      expect(limiter.isExcessiveUsage(), isFalse);
      now = now.add(const Duration(seconds: 30));
      expect(limiter.isExcessiveUsage(), isTrue);
      now = now.add(const Duration(minutes: 10));
      expect(limiter.isExcessiveUsage(), isFalse);
    });
  });
}
