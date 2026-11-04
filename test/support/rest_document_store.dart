import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ramifica/data/persistence/document_store.dart';

/// Emulator-only REST adapter. Runs the production Dart writers against real
/// Firestore transactions and security rules without Firebase platform plugins.
class RestDocumentStore implements DocumentStore {
  RestDocumentStore(String host, this.uid)
    : base = 'http://$host/v1/projects/demo-ramifica-plan/databases/(default)' {
    if (!RegExp(r'^127\.0\.0\.1:\d+$').hasMatch(host)) {
      throw ArgumentError('Emulator localhost required');
    }
  }
  final String base, uid;
  final client = HttpClient();
  int _id = 0;
  String get token {
    if (uid == 'owner') return 'owner';
    String part(Object data) =>
        base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final claims = <String, Object?>{
      'iss': 'https://securetoken.google.com/demo-ramifica-plan',
      'aud': 'demo-ramifica-plan',
      'sub': uid,
      'user_id': uid,
      'iat': now,
      'exp': now + 3600,
      'firebase': {'sign_in_provider': 'custom', 'identities': {}},
    };
    // The author token matches whatever creator() was stamped with.
    if (uid == 'author') {
      final email = _creatorEmail();
      if (email != null) {
        claims['email'] = email;
        claims['email_verified'] = true;
      }
    }
    return '${part({'alg': 'none', 'typ': 'JWT'})}.${part(claims)}.';
  }

  String? _creatorEmail() {
    final rules = File('firestore.rules').readAsStringSync();
    final match = RegExp(
      "request\\.auth\\.token\\.email\\.lower\\(\\) == '([^']*)'",
    ).firstMatch(rules);
    final email = match?.group(1);
    if (email == null || email.isEmpty) return null;
    return email;
  }

  String name(String path) =>
      '${base.substring(base.indexOf('/projects/') + 1)}/documents/$path';
  Future<dynamic> request(String method, String url, [Object? body]) async {
    final req = await client.openUrl(method, Uri.parse(url));
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.contentType = ContentType.json;
    if (body != null) req.write(jsonEncode(body));
    final response = await req.close().timeout(const Duration(seconds: 10));
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 300) {
      throw HttpException('${response.statusCode}: $text');
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  Future<Json?> read(String path, [String? tx]) async {
    final dynamic data;
    if (tx == null) {
      data = await request('GET', '$base/documents/$path');
    } else {
      final rows = await request('POST', '$base/documents:batchGet', {
        'documents': [name(path)],
        'transaction': tx,
      });
      data = (rows as List).first['found'];
    }
    return data == null ? null : _fields(data['fields']);
  }

  @override
  String newId(String collection) =>
      '${uid}_${DateTime.now().microsecondsSinceEpoch}_${++_id}';
  @override
  Future<Json?> get(String path, {bool server = false}) => read(path);
  @override
  Future<List<StoredDoc>> list(
    String collection, {
    Map<String, Object?> equals = const {},
    String? orderBy,
    bool descending = false,
    int? limit,
    bool server = false,
  }) async {
    final split = collection.lastIndexOf('/');
    final parent = split < 0 ? '' : '/${collection.substring(0, split)}';
    final filters = [
      for (final entry in equals.entries)
        {
          'fieldFilter': {
            'field': {'fieldPath': entry.key},
            'op': 'EQUAL',
            'value': _value(entry.value),
          },
        },
    ];
    final result = await request('POST', '$base/documents$parent:runQuery', {
      'structuredQuery': {
        'from': [
          {'collectionId': collection.substring(split + 1)},
        ],
        if (filters.length == 1) 'where': filters.single,
        if (filters.length > 1)
          'where': {
            'compositeFilter': {'op': 'AND', 'filters': filters},
          },
        if (orderBy != null)
          'orderBy': [
            {
              'field': {'fieldPath': orderBy},
              'direction': descending ? 'DESCENDING' : 'ASCENDING',
            },
          ],
        'limit': ?limit,
      },
    });
    return [
      for (final row in result as List)
        if (row['document'] != null)
          MapEntry(
            (row['document']['name'] as String).split('/').last,
            _fields(row['document']['fields']),
          ),
    ];
  }

  @override
  Stream<List<StoredDoc>> watch(String collection) => const Stream.empty();
  @override
  Future<void> batch(List<DocumentWrite> writes) async {
    await request('POST', '$base/documents:commit', {
      'writes': [for (final w in writes) write(w)],
    });
  }

  Json write(DocumentWrite w) => {
    'update': {
      'name': name(w.path),
      'fields': {for (final e in w.data.entries) e.key: _value(e.value)},
    },
    if (w.merge) 'updateMask': {'fieldPaths': w.data.keys.toList()},
  };
  @override
  Future<T> transaction<T>(
    Future<T> Function(DocumentTransaction tx) action,
  ) async {
    final begin = await request('POST', '$base/documents:beginTransaction', {
      'options': {'readWrite': {}},
    });
    final tx = _RestTransaction(this, begin['transaction'] as String);
    try {
      final result = await action(tx);
      await request('POST', '$base/documents:commit', {
        'transaction': tx.id,
        'writes': tx.writes,
      });
      return result;
    } catch (_) {
      await request('POST', '$base/documents:rollback', {'transaction': tx.id});
      rethrow;
    }
  }

  void close() => client.close(force: true);
}

class _RestTransaction implements DocumentTransaction {
  _RestTransaction(this.store, this.id);
  final RestDocumentStore store;
  final String id;
  final writes = <Json>[];
  @override
  Future<Json?> get(String path) => store.read(path, id);
  @override
  void set(String path, Json data, {bool merge = false}) =>
      writes.add(store.write(DocumentWrite(path, data, merge: merge)));
  @override
  void delete(String path) => writes.add({'delete': store.name(path)});
}

Json _fields(Object? fields) =>
    jsonMap(fields).map((key, value) => MapEntry(key, _decode(jsonMap(value))));
dynamic _decode(Json value) {
  if (value.containsKey('nullValue')) return null;
  if (value.containsKey('mapValue')) {
    return _fields(jsonMap(value['mapValue'])['fields']);
  }
  if (value.containsKey('arrayValue')) {
    return [
      for (final v in jsonMap(value['arrayValue'])['values'] as List? ?? [])
        _decode(jsonMap(v)),
    ];
  }
  if (value.containsKey('integerValue')) {
    return int.parse(value['integerValue'].toString());
  }
  if (value.containsKey('doubleValue')) {
    return (value['doubleValue'] as num).toDouble();
  }
  return value.values.firstOrNull;
}

Json _value(Object? v) => switch (v) {
  null => {'nullValue': null},
  bool() => {'booleanValue': v},
  int() => {'integerValue': '$v'},
  num() => {'doubleValue': v},
  CommitTime() => {'timestampValue': DateTime.now().toUtc().toIso8601String()},
  Map() => {
    'mapValue': {
      'fields': {for (final e in v.entries) e.key: _value(e.value)},
    },
  },
  List() => {
    'arrayValue': {'values': v.map(_value).toList()},
  },
  _ => {'stringValue': v},
};
