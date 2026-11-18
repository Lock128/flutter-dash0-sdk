import 'dart:async';
import 'dart:convert';

import 'package:dash0_flutter_sdk/dash0_flutter_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'test_helpers.dart';

String body(String query, {Object? operationName, Object? variables}) =>
    jsonEncode({
      'query': query,
      if (operationName != null) 'operationName': operationName,
      if (variables != null) 'variables': variables,
    });

Stream<List<int>> chunks(String s, {int size = 1000}) async* {
  final bytes = utf8.encode(s);
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size);
  }
}

Future<(Dash0Client, FakeTransport)> start() async {
  final transport = FakeTransport();
  final client = await Dash0Client.start(
    const Dash0Options(
      serviceName: 'test',
      endpoint: testEndpoint,
      batchSize: 1,
    ),
    transport: transport,
    sessionStore: MemoryStore(),
    installErrorHandlers: false,
    observeLifecycle: false,
  );
  return (client, transport);
}

Map<String, Object?> metricNamed(FakeTransport t, String name) =>
    t.metrics.firstWhere((m) => m['name'] == name);

List<Map<String, Object?>> points(Map<String, Object?> metric) =>
    ((metric['histogram']! as Map)['dataPoints'] as List)
        .cast<Map<String, Object?>>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dash0GraphQLOperation.tryParse', () {
    test('named query, mutation and subscription', () {
      final q = Dash0GraphQLOperation.tryParse(
          body('query GetX(\$id: ID!) { x(id: \$id) { id } }'))!;
      expect((q.name, q.type), ('GetX', 'query'));
      final m = Dash0GraphQLOperation.tryParse(
          body('mutation CreateX { createX { id } }'))!;
      expect((m.name, m.type), ('CreateX', 'mutation'));
      final s = Dash0GraphQLOperation.tryParse(
          body('subscription OnX @live { onX { id } }'))!;
      expect((s.name, s.type), ('OnX', 'subscription'));
    });

    test('anonymous operations', () {
      final a = Dash0GraphQLOperation.tryParse(body('{ x }'))!;
      expect((a.name, a.type), (null, 'query'));
      final b = Dash0GraphQLOperation.tryParse(body('mutation { x }'))!;
      expect((b.name, b.type), (null, 'mutation'));
    });

    test('operationName selects among several operations', () {
      const doc = 'query A { a } mutation B { b }';
      final first = Dash0GraphQLOperation.tryParse(body(doc))!;
      expect(first.name, 'A');
      final picked =
          Dash0GraphQLOperation.tryParse(body(doc, operationName: 'B'))!;
      expect((picked.name, picked.type), ('B', 'mutation'));
    });

    test('operationName without a match is used with the first type', () {
      final op = Dash0GraphQLOperation.tryParse(
          body('mutation { x }', operationName: 'Named'))!;
      expect((op.name, op.type), ('Named', 'mutation'));
    });

    test('comments, strings and fragments are not mistaken for operations', () {
      const doc = '''
# query Commented { a }
fragment query on T { id }
query Real(\$a: String = "mutation Fake { x }") {
  x(arg: """ query Hidden { y } """) { ...query }
}
''';
      final op = Dash0GraphQLOperation.tryParse(body(doc))!;
      expect((op.name, op.type), ('Real', 'query'));
    });

    test('invalid names are dropped', () {
      final long = 'A' * 65;
      final op = Dash0GraphQLOperation.tryParse(
          body('query X { x }', operationName: 'bad name!'))!;
      expect(op.name, isNull);
      expect(op.type, 'query');
      expect(Dash0GraphQLOperation.tryParse(body('query $long { x }'))!.name,
          isNull);
    });

    test('batched, non objects and invalid input return null', () {
      expect(
          Dash0GraphQLOperation.tryParse(
              jsonEncode([jsonDecode(body('query A { a }'))])),
          isNull);
      expect(Dash0GraphQLOperation.tryParse('"query A { a }"'), isNull);
      expect(Dash0GraphQLOperation.tryParse('not json'), isNull);
      expect(Dash0GraphQLOperation.tryParse('{"query": 1}'), isNull);
      expect(Dash0GraphQLOperation.tryParse(body('fragment F on T { a }')),
          isNull);
    });

    test('the result holds no query text or variables', () {
      final op = Dash0GraphQLOperation.tryParse(body(
          'query Secret { user(password: "hunter2") { id } }',
          variables: {'token': 'abc'}))!;
      expect(op.toString(), isNot(contains('hunter2')));
      expect(op.toString(), isNot(contains('abc')));
    });
  });

  group('Dash0GraphQLErrors.tryParse', () {
    test('errorType, extensions.code and the fallback', () {
      final a = Dash0GraphQLErrors.tryParse(
          '{"errors":[{"errorType":"Unauthorized","message":"secret"},{}]}')!;
      expect((a.count, a.type), (2, 'Unauthorized'));
      final b = Dash0GraphQLErrors.tryParse(
          '{"errors":[{"message":"m","extensions":{"code":"BAD_USER_INPUT"}}]}')!;
      expect(b.type, 'BAD_USER_INPUT');
      final c = Dash0GraphQLErrors.tryParse(
          '{"errors":[{"extensions":{"code":"has spaces"}}]}')!;
      expect(c.type, 'GraphQLError');
      final d = Dash0GraphQLErrors.tryParse('{"errors":["x"]}')!;
      expect(d.type, 'GraphQLError');
    });

    test('no errors returns null and no message text is kept', () {
      expect(Dash0GraphQLErrors.tryParse('{"data":{"x":1}}'), isNull);
      expect(Dash0GraphQLErrors.tryParse('{"errors":[]}'), isNull);
      expect(Dash0GraphQLErrors.tryParse('{"errors":null}'), isNull);
      expect(Dash0GraphQLErrors.tryParse('[1]'), isNull);
      expect(Dash0GraphQLErrors.tryParse('nope'), isNull);
      final e = Dash0GraphQLErrors.tryParse(
          '{"errors":[{"message":"secret text"}]}')!;
      expect(e.toString(), isNot(contains('secret')));
    });
  });

  group('bounded readers', () {
    test('request body is parsed', () async {
      final op = await Dash0GraphQL.inspectRequestBody(
          chunks(body('query GetX { x }'), size: 5));
      expect(op?.name, 'GetX');
    });

    test('request body over the limit is skipped and cancelled', () async {
      var cancelled = false;
      final controller =
          StreamController<List<int>>(onCancel: () => cancelled = true);
      final future = Dash0GraphQL.inspectRequestBody(controller.stream);
      controller.add(List.filled(100 * 1024, 32));
      controller.add(List.filled(100 * 1024, 32));
      expect(await future, isNull);
      expect(cancelled, isTrue);
      await controller.close();
    });

    test('non JSON content type is skipped', () async {
      final op = await Dash0GraphQL.inspectRequestBody(
          chunks(body('query A { a }')),
          headers: {'Content-Type': 'text/plain'});
      expect(op, isNull);
    });

    test('another listener of a broadcast copy still gets every byte',
        () async {
      final text = body('query A { a }') + ' ' * 5000;
      final source = chunks(text, size: 100).asBroadcastStream();
      final other = utf8.decodeStream(source);
      final op = await Dash0GraphQL.inspectRequestBody(source);
      expect(op?.name, 'A');
      expect(await other, text);
    });

    test('response errors are read', () async {
      final e = await Dash0GraphQL.inspectResponse(
        chunks('{"data":null,"errors":[{"errorType":"Unauthorized"}]}'),
        headers: {'content-type': 'application/json'},
        statusCode: 200,
      );
      expect((e?.count, e?.type), (1, 'Unauthorized'));
    });

    test('responses are skipped for status, type, length and size', () async {
      const json = '{"errors":[{"errorType":"X"}]}';
      expect(await Dash0GraphQL.inspectResponse(chunks(json), statusCode: 500),
          isNull);
      expect(
          await Dash0GraphQL.inspectResponse(chunks(json),
              headers: {'content-type': 'text/event-stream'}),
          isNull);
      expect(
          await Dash0GraphQL.inspectResponse(chunks(json), headers: {
            'content-type': 'application/json',
            'content-length': '${300 * 1024}',
          }),
          isNull);
      final big = '{"errors":[{"errorType":"X"}],"pad":"${'a' * 300000}"}';
      expect(
          await Dash0GraphQL.inspectResponse(chunks(big, size: 50000)), isNull);
    });

    test('a response that never completes times out', () async {
      final controller = StreamController<List<int>>();
      final result = await Dash0GraphQL.inspectResponse(controller.stream);
      expect(result, isNull);
      await controller.close();
    });
  });

  group('span integration', () {
    test('operation attributes, span name and no query text', () async {
      final (client, transport) = await start();
      final span = Dash0HttpSpan.start(
          client, 'POST', 'https://api.example.com/graphql')!;
      span.setGraphQLOperation(Dash0GraphQLOperation.tryParse(body(
          'query GetX { x(secret: "hunter2") }',
          variables: {'p': 'v4lue'})));
      span.setResponse(200);
      span.finish();
      await client.flush();

      final s = transport.spans.single;
      expect(s['name'], 'HTTP POST GetX');
      expect(attr(s, 'graphql.operation.name'), 'GetX');
      expect(attr(s, 'graphql.operation.type'), 'query');
      final dump = jsonEncode(transport.sent.map((e) => e.body).toList());
      expect(dump, isNot(contains('hunter2')));
      expect(dump, isNot(contains('v4lue')));
      expect(dump, isNot(contains('x(secret')));
      await client.shutdown();
    });

    test('unnamed operations keep the span name', () async {
      final (client, transport) = await start();
      final span = Dash0HttpSpan.start(
          client, 'POST', 'https://api.example.com/graphql')!;
      span.setGraphQLOperation(Dash0GraphQLOperation.tryParse(body('{ x }')));
      span.finish();
      await client.flush();
      final s = transport.spans.single;
      expect(s['name'], 'HTTP POST');
      expect(attr(s, 'graphql.operation.name'), isNull);
      expect(attr(s, 'graphql.operation.type'), 'query');
      await client.shutdown();
    });

    test('errors in a 200 response fail the span without message text',
        () async {
      final (client, transport) = await start();
      final span = Dash0HttpSpan.start(
          client, 'POST', 'https://api.example.com/graphql')!;
      span.setGraphQLOperation(
          Dash0GraphQLOperation.tryParse(body('query GetX { x }')));
      span.setResponse(200);
      span.setGraphQLErrors(Dash0GraphQLErrors.tryParse(
          '{"errors":[{"errorType":"Unauthorized","message":"secret"}]}'));
      span.finish();
      await client.flush();

      final s = transport.spans.single;
      final status = s['status']! as Map;
      expect(status['code'], 2);
      expect(status['message'],
          'GraphQL response contained 1 error(s): Unauthorized');
      expect(attr(s, 'error.type'), 'Unauthorized');
      expect(jsonEncode(transport.sent.map((e) => e.body).toList()),
          isNot(contains('secret')));

      final http =
          points(metricNamed(transport, 'http.client.request.duration'));
      expect(attr(http.single, 'error.type'), 'Unauthorized');
      await client.shutdown();
    });

    test('records graphql.client.operation.duration next to the http metric',
        () async {
      final (client, transport) = await start();
      Dash0HttpSpan.start(client, 'POST', 'https://api.example.com/graphql')!
        ..setGraphQLOperation(
            Dash0GraphQLOperation.tryParse(body('mutation Save { x }')))
        ..setResponse(200)
        ..setGraphQLErrors(const Dash0GraphQLErrors(count: 2, type: 'Boom'))
        ..finish();
      await client.flush();

      final p =
          points(metricNamed(transport, 'graphql.client.operation.duration'))
              .single;
      expect(attr(p, 'graphql.operation.name'), 'Save');
      expect(attr(p, 'graphql.operation.type'), 'mutation');
      expect(attr(p, 'error.type'), 'Boom');
      expect(attr(p, 'server.address'), 'api.example.com');
      expect(attr(p, 'graphql.query'), isNull);
      expect(points(metricNamed(transport, 'http.client.request.duration')),
          hasLength(1));
      await client.shutdown();
    });

    test('no graphql metric for plain requests', () async {
      final (client, transport) = await start();
      Dash0HttpSpan.start(client, 'GET', 'https://api.example.com/')!
        ..setResponse(200)
        ..finish();
      await client.flush();
      expect(transport.metrics.map((m) => m['name']),
          isNot(contains('graphql.client.operation.duration')));
      await client.shutdown();
    });

    test('distinct names are capped at 100, the rest is _OTHER', () async {
      final (client, transport) = await start();
      for (var i = 0; i < 105; i++) {
        Dash0HttpSpan.start(client, 'POST', 'https://api.example.com/graphql')!
          ..setGraphQLOperation(
              Dash0GraphQLOperation(name: 'Op$i', type: 'query'))
          ..setResponse(200)
          ..finish();
      }
      await client.flush();
      final pts =
          points(metricNamed(transport, 'graphql.client.operation.duration'));
      final names = pts.map((p) => attr(p, 'graphql.operation.name')).toSet();
      expect(pts, hasLength(101));
      expect(names, contains('_OTHER'));
      expect(names, contains('Op0'));
      expect(names, isNot(contains('Op104')));
      await client.shutdown();
    });

    test('setters never throw and ignore null', () async {
      final (client, _) = await start();
      final span = Dash0HttpSpan.start(
          client, 'POST', 'https://api.example.com/graphql')!;
      span.finish();
      span.setGraphQLOperation(null);
      span.setGraphQLErrors(null);
      span.setGraphQLOperation(Dash0GraphQLOperation.tryParse(body('{ x }')));
      await client.shutdown();
    });
  });

  group('Dash0HttpClient', () {
    Future<Map<String, Object?>> post(
      http.Request request,
    ) async {
      final (client, transport) = await start();
      final c = Dash0HttpClient(
          client, MockClient((r) async => http.Response('{}', 200)));
      await c.send(request);
      await client.flush();
      await client.shutdown();
      return transport.spans.single;
    }

    test('names JSON POST operations', () async {
      final s = await post(
          http.Request('POST', Uri.parse('https://api.example.com/graphql'))
            ..headers['content-type'] = 'application/json'
            ..body = body('query GetX { x }'));
      expect(s['name'], 'HTTP POST GetX');
      expect(attr(s, 'graphql.operation.type'), 'query');
    });

    test('ignores non JSON, GET and huge bodies', () async {
      final text =
          http.Request('POST', Uri.parse('https://api.example.com/graphql'))
            ..headers['content-type'] = 'text/plain'
            ..body = body('query GetX { x }');
      expect((await post(text))['name'], 'HTTP POST');

      final get = http.Request('GET', Uri.parse('https://api.example.com/g'))
        ..headers['content-type'] = 'application/json'
        ..body = body('query GetX { x }');
      expect((await post(get))['name'], 'HTTP GET');

      final huge =
          http.Request('POST', Uri.parse('https://api.example.com/graphql'))
            ..headers['content-type'] = 'application/json'
            ..body = body('query GetX { x }', variables: 'a' * 200000);
      expect((await post(huge))['name'], 'HTTP POST');
    });
  });
}
