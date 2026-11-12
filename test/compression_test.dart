import 'dart:convert';
import 'dart:io';

import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const endpoint = [Dash0Endpoint(url: 'https://a.example.com', authToken: 't')];

void main() {
  final big = {'text': 'x' * 5000};

  test('gzips large bodies and sets Content-Encoding', () async {
    late http.Request request;
    final transport = HttpDash0Transport(
      endpoint,
      client: MockClient((r) async {
        request = r;
        return http.Response('', 200);
      }),
    );
    await transport.send('/v1/logs', big);
    expect(request.headers['Content-Encoding'], 'gzip');
    expect(request.bodyBytes.length, lessThan(500));
    expect(jsonDecode(utf8.decode(gzip.decode(request.bodyBytes))), big);
  });

  test('skips compression for small bodies', () async {
    late http.Request request;
    final transport = HttpDash0Transport(
      endpoint,
      client: MockClient((r) async {
        request = r;
        return http.Response('', 200);
      }),
    );
    await transport.send('/v1/logs', {'a': 1});
    expect(request.headers.containsKey('Content-Encoding'), isFalse);
    expect(jsonDecode(request.body), {'a': 1});
  });

  test('compression none never compresses', () async {
    late http.Request request;
    final transport = HttpDash0Transport(
      endpoint,
      compression: Dash0Compression.none,
      client: MockClient((r) async {
        request = r;
        return http.Response('', 200);
      }),
    );
    await transport.send('/v1/logs', big);
    expect(request.headers.containsKey('Content-Encoding'), isFalse);
    expect(jsonDecode(request.body), big);
  });
}
