import 'dart:async';

import 'package:ramifica/data/persistence/document_store.dart';

/// Atomic, rollback-capable adapter running the real Dart business logic.
class MemoryDocumentStore implements DocumentStore {
  final documents = <String, Json>{};
  final reads = <String>[];
  final lists = <String>[];
  final _changes = StreamController<void>.broadcast(sync: true);
  int commits = 0, _id = 0;
  Future<void> Function()? beforeCommit;
  Future<void> Function(List<DocumentWrite>)? beforeBatch;
  Future<void> Function(String)? beforeRead;
  Future<void> Function(String)? beforeList;
  Future<void> _tail = Future.value();
  @override
  String newId(String collection) => 'id${++_id}';
  @override
  Future<Json?> get(String path, {bool server = false}) async {
    reads.add(path);
    await beforeRead?.call(path);
    final doc = documents[path];
    return doc == null ? null : _copy(doc);
  }

  @override
  Future<List<StoredDoc>> list(
    String collection, {
    Map<String, Object?> equals = const {},
    String? orderBy,
    bool descending = false,
    int? limit,
    bool server = false,
  }) async {
    lists.add(collection);
    await beforeList?.call(collection);
    final result = documents.entries
        .where(
          (d) =>
              d.key.startsWith('$collection/') &&
              !d.key.substring(collection.length + 1).contains('/') &&
              equals.entries.every((e) => d.value[e.key] == e.value),
        )
        .map((d) => MapEntry(d.key.split('/').last, _copy(d.value)))
        .toList();
    if (orderBy != null) {
      result.sort((a, b) {
        final order = (a.value[orderBy]?.toString() ?? '').compareTo(
          b.value[orderBy]?.toString() ?? '',
        );
        return descending ? -order : order;
      });
    }
    return limit == null ? result : result.take(limit).toList();
  }

  @override
  Stream<List<StoredDoc>> watch(String collection) {
    List<StoredDoc> snapshot() => [
      for (final d in documents.entries)
        if (d.key.startsWith('$collection/') &&
            !d.key.substring(collection.length + 1).contains('/'))
          MapEntry(d.key.split('/').last, _copy(d.value)),
    ];
    late StreamController<List<StoredDoc>> output;
    StreamSubscription<void>? subscription;
    output = StreamController<List<StoredDoc>>(
      sync: true,
      onListen: () {
        output.add(snapshot());
        subscription = _changes.stream.listen((_) {
          output.add(snapshot());
        });
      },
      onCancel: () => subscription?.cancel(),
    );
    return output.stream;
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DocumentTransaction tx) action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      final tx = _MemoryTransaction(this);
      try {
        final value = await action(tx);
        await beforeCommit?.call();
        tx.commit();
        result.complete(value);
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  @override
  Future<void> batch(List<DocumentWrite> writes) async {
    await beforeBatch?.call(writes);
    for (final write in writes) {
      documents[write.path] = {
        ...(write.merge ? documents[write.path] ?? {} : {}),
        ..._copy(write.data),
      };
    }
    commits++;
    _changes.add(null);
  }

  void close() {
    _changes.close();
  }
}

class _MemoryTransaction implements DocumentTransaction {
  _MemoryTransaction(this.store);
  final MemoryDocumentStore store;
  final writes = <DocumentWrite>[];
  final deleted = <String>[];
  @override
  Future<Json?> get(String path) {
    if (writes.isNotEmpty || deleted.isNotEmpty) {
      throw StateError('Firestore requires all reads before writes.');
    }
    return store.get(path);
  }

  @override
  void set(String path, Json data, {bool merge = false}) {
    writes.add(DocumentWrite(path, data, merge: merge));
  }

  @override
  void delete(String path) {
    deleted.add(path);
  }

  void commit() {
    for (final path in deleted) {
      store.documents.remove(path);
    }
    for (final write in writes) {
      store.documents[write.path] = {
        ...(write.merge ? store.documents[write.path] ?? {} : {}),
        ..._copy(write.data),
      };
    }
    if (writes.isNotEmpty || deleted.isNotEmpty) {
      store.commits++;
      store._changes.add(null);
    }
  }
}

Json _copy(Json data) => data.map((key, value) => MapEntry(key, _value(value)));
dynamic _value(dynamic value) => switch (value) {
  CommitTime() => DateTime.now().toUtc().toIso8601String(),
  Map() => _copy(jsonMap(value)),
  List() => value.map(_value).toList(),
  _ => value,
};
