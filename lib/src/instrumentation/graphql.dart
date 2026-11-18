import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;

/// Largest request body that is inspected for a GraphQL operation.
const maxGraphQLRequestBytes = 128 * 1024;

/// Largest response body that is inspected for GraphQL errors.
const maxGraphQLResponseBytes = 256 * 1024;

/// Longest time spent reading a response body for GraphQL errors.
const graphQLResponseTimeout = Duration(seconds: 2);

final _nameRe = RegExp(r'^[_A-Za-z][_0-9A-Za-z]{0,63}$');
final _codeRe = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');

/// The error type used when a GraphQL error has no usable code.
const graphQLDefaultErrorType = 'GraphQLError';

/// The operation of a GraphQL request: its name and type.
///
/// Only the name and the type are kept, never the query text or variables.
class Dash0GraphQLOperation {
  const Dash0GraphQLOperation({this.name, required this.type});

  /// The operation name, or null for anonymous operations and names that are
  /// not valid GraphQL names.
  final String? name;

  /// `query`, `mutation` or `subscription`.
  final String type;

  /// Reads the operation from a GraphQL over HTTP JSON request body.
  ///
  /// Returns null if [body] is not a JSON object with a string `query`, for
  /// example batched requests (JSON arrays). Never throws.
  static Dash0GraphQLOperation? tryParse(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final query = json['query'];
      if (query is! String) return null;
      final defs = _definitions(query);
      if (defs.isEmpty) return null;
      final requested = json['operationName'];
      if (requested is String && requested.isNotEmpty) {
        for (final d in defs) {
          if (d.name == requested) return _validated(d.name, d.type);
        }
        return _validated(requested, defs.first.type);
      }
      return _validated(defs.first.name, defs.first.type);
    } catch (_) {
      return null;
    }
  }

  static Dash0GraphQLOperation _validated(String? name, String type) =>
      Dash0GraphQLOperation(
        name: name != null && _nameRe.hasMatch(name) ? name : null,
        type: type,
      );

  @override
  String toString() => 'Dash0GraphQLOperation($type, $name)';
}

typedef _Definition = ({String type, String? name});

const _operationTypes = {'query', 'mutation', 'subscription'};

/// Operation definitions of a GraphQL document, in document order.
List<_Definition> _definitions(String document) {
  final s = _stripNoise(document);
  final defs = <_Definition>[];
  var depth = 0;
  var inHeader = false;
  var i = 0;
  String? readWord() {
    while (i < s.length && s[i].trim().isEmpty) {
      i++;
    }
    final start = i;
    while (i < s.length && RegExp(r'[_0-9A-Za-z]').hasMatch(s[i])) {
      i++;
    }
    return i > start ? s.substring(start, i) : null;
  }

  while (i < s.length) {
    final c = s[i];
    if (c == '{' || c == '(' || c == '[') {
      if (c == '{' && depth == 0 && !inHeader) {
        defs.add((type: 'query', name: null));
      }
      if (c == '{' && depth == 0) inHeader = false;
      depth++;
      i++;
    } else if (c == '}' || c == ')' || c == ']') {
      if (depth > 0) depth--;
      i++;
    } else if (depth == 0 && RegExp(r'[_A-Za-z]').hasMatch(c)) {
      final word = readWord()!;
      if (_operationTypes.contains(word) && !inHeader) {
        inHeader = true;
        final save = i;
        final next = readWord();
        if (next != null) {
          defs.add((type: word, name: next));
        } else {
          i = save;
          defs.add((type: word, name: null));
        }
      } else if (word == 'fragment' && !inHeader) {
        inHeader = true;
        readWord();
      }
    } else {
      i++;
    }
  }
  return defs;
}

/// Replaces comments and string literals so they cannot be mistaken for
/// syntax.
String _stripNoise(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == '#') {
      while (i < s.length && s[i] != '\n' && s[i] != '\r') {
        i++;
      }
    } else if (s.startsWith('"""', i)) {
      i += 3;
      while (i < s.length && !s.startsWith('"""', i)) {
        i += s.startsWith(r'\"""', i) ? 4 : 1;
      }
      i += 3;
      out.write(' ');
    } else if (c == '"') {
      i++;
      while (i < s.length && s[i] != '"' && s[i] != '\n') {
        i += s[i] == r'\' ? 2 : 1;
      }
      i++;
      out.write(' ');
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// The errors of a GraphQL response: how many and the type of the first one.
///
/// Error messages are never kept because servers can echo user input in them.
class Dash0GraphQLErrors {
  const Dash0GraphQLErrors({required this.count, required this.type});

  /// Number of entries in the `errors` array.
  final int count;

  /// `errorType` of the first error (AppSync), else its `extensions.code`,
  /// else `GraphQLError`.
  final String type;

  /// Reads the errors from a GraphQL JSON response body. Returns null if the
  /// body has no non-empty `errors` array. Never throws.
  static Dash0GraphQLErrors? tryParse(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final errors = json['errors'];
      if (errors is! List || errors.isEmpty) return null;
      var type = graphQLDefaultErrorType;
      final first = errors.first;
      if (first is Map) {
        final errorType = first['errorType'];
        final extensions = first['extensions'];
        final code = extensions is Map ? extensions['code'] : null;
        if (errorType is String && _codeRe.hasMatch(errorType)) {
          type = errorType;
        } else if (code is String && _codeRe.hasMatch(code)) {
          type = code;
        }
      }
      return Dash0GraphQLErrors(count: errors.length, type: type);
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'Dash0GraphQLErrors($count, $type)';
}

/// Bounded readers that inspect HTTP bodies without keeping them.
///
/// Pass a copy of the body stream (for example from `split()`), so the app
/// still gets the whole body.
class Dash0GraphQL {
  Dash0GraphQL._();

  /// Reads at most [maxGraphQLRequestBytes] from [body] and returns the
  /// operation, or null. Bodies over the limit are cancelled and skipped.
  /// With [headers] given, only JSON content is read. Never throws.
  static Future<Dash0GraphQLOperation?> inspectRequestBody(
    Stream<List<int>> body, {
    Map<String, String>? headers,
  }) async {
    try {
      if (headers != null && !_isJson(headers)) return null;
      final text = await _readBounded(body, maxGraphQLRequestBytes, null);
      return text == null ? null : Dash0GraphQLOperation.tryParse(text);
    } catch (_) {
      return null;
    }
  }

  /// Reads a response body and returns its GraphQL errors, or null.
  ///
  /// Skips non 2xx responses (when [statusCode] is given), non JSON content,
  /// a `content-length` over [maxGraphQLResponseBytes] and bodies that are
  /// larger than that or take longer than [graphQLResponseTimeout]. Never
  /// throws.
  static Future<Dash0GraphQLErrors?> inspectResponse(
    Stream<List<int>> body, {
    Map<String, String>? headers,
    int? statusCode,
  }) async {
    try {
      if (statusCode != null && (statusCode < 200 || statusCode > 299)) {
        return null;
      }
      if (headers != null) {
        if (!_isJson(headers)) return null;
        final length = int.tryParse(_header(headers, 'content-length') ?? '');
        if (length != null && length > maxGraphQLResponseBytes) return null;
      }
      final text = await _readBounded(
          body, maxGraphQLResponseBytes, graphQLResponseTimeout);
      if (text == null || !text.contains('"errors"')) return null;
      return Dash0GraphQLErrors.tryParse(text);
    } catch (_) {
      return null;
    }
  }

  static String? _header(Map<String, String> headers, String name) {
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == name) return e.value;
    }
    return null;
  }

  static bool _isJson(Map<String, String> headers) {
    final type = _header(headers, 'content-type')?.toLowerCase();
    return type != null && type.contains('json');
  }

  /// Decodes [body] as UTF-8. Returns null if it is longer than [limit]
  /// bytes, fails, or takes longer than [timeout]. Cancels the
  /// subscription in those cases.
  static Future<String?> _readBounded(
    Stream<List<int>> body,
    int limit,
    Duration? timeout,
  ) {
    final completer = Completer<String?>();
    final bytes = BytesBuilder(copy: false);
    StreamSubscription<List<int>>? sub;
    Timer? timer;
    void done(String? value) {
      timer?.cancel();
      if (!completer.isCompleted) completer.complete(value);
      sub?.cancel().catchError((_) {});
    }

    sub = body.listen(
      (chunk) {
        if (completer.isCompleted) return;
        if (bytes.length + chunk.length > limit) {
          done(null);
          return;
        }
        bytes.add(chunk);
      },
      onError: (Object _) => done(null),
      onDone: () {
        try {
          done(utf8.decode(bytes.takeBytes(), allowMalformed: true));
        } catch (_) {
          done(null);
        }
      },
      cancelOnError: true,
    );
    if (timeout != null) timer = Timer(timeout, () => done(null));
    return completer.future;
  }
}
