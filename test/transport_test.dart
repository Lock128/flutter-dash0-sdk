import 'dart:convert';

import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('posts JSON with bearer token and dataset to every endpoint', () async {
    final requests = <http.Request>[];
    final transport = HttpDash0Transport(
      const [
        Dash0Endpoint(
          url: 'https://a.example.com/',
          authToken: 'auth_a',
          dataset: 'mobile',
        ),
        Dash0Endpoint(url: 'https://b.example.com/otlp', authToken: 'auth_b'),
      ],
      client: MockClient((r) async {
        requests.add(r);
        return http.Response('', 200);
      }),
    );
    await transport.send('/v1/traces', {'resourceSpans': <Object>[]});

    expect(requests, hasLength(2));
    final a = requests.firstWhere((r) => r.url.host == 'a.example.com');
    expect(a.url.toString(), 'https://a.example.com/v1/traces');
    expect(a.method, 'POST');
    expect(a.headers['Authorization'], 'Bearer auth_a');
    expect(a.headers['Dash0-Dataset'], 'mobile');
    expect(a.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(a.body), {'resourceSpans': <Object>[]});

    final b = requests.firstWhere((r) => r.url.host == 'b.example.com');
    expect(b.url.toString(), 'https://b.example.com/otlp/v1/traces');
    expect(b.headers['Authorization'], 'Bearer auth_b');
    expect(b.headers.containsKey('Dash0-Dataset'), isFalse);
  });

  test('swallows transport failures', () async {
    final transport = HttpDash0Transport(
      const [Dash0Endpoint(url: 'https://a.example.com', authToken: 't')],
      client: MockClient((r) async => throw http.ClientException('down')),
    );
    await transport.send('/v1/logs', {'resourceLogs': <Object>[]});
  });

  test('swallows non success responses', () async {
    final transport = HttpDash0Transport(
      const [Dash0Endpoint(url: 'https://a.example.com', authToken: 't')],
      client: MockClient((r) async => http.Response('no', 401)),
    );
    await transport.send('/v1/logs', {'resourceLogs': <Object>[]});
  });
}
