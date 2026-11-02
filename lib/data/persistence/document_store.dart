import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ramifica/data/models/app_failure.dart';

typedef Json = Map<String, dynamic>;
typedef StoredDoc = MapEntry<String, Json>;

/// A server timestamp, resolved by the production adapter at commit time.
class CommitTime {
  const CommitTime();
}

const commitTime = CommitTime();

class DocumentWrite {
  const DocumentWrite(this.path, this.data, {this.merge = false});
  final String path;
  final Json data;
  final bool merge;
}

/// Small injectable Firestore surface. Business logic runs in Dart on both
/// the production adapter and the in-memory test adapter.
abstract interface class DocumentStore {
  String newId(String collection);
  Future<Json?> get(String path, {bool server = false});
  Future<List<StoredDoc>> list(
    String collection, {
    Map<String, Object?> equals = const {},
    String? orderBy,
    bool descending = false,
    int? limit,
    bool server = false,
  });
  Stream<List<StoredDoc>> watch(String collection);
  Future<T> transaction<T>(Future<T> Function(DocumentTransaction tx) action);
  Future<void> batch(List<DocumentWrite> writes);
}

abstract interface class DocumentTransaction {
  Future<Json?> get(String path);
  void set(String path, Json data, {bool merge = false});
  void delete(String path);
}

Json jsonMap(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : <String, dynamic>{};

Never invalid(String message) => throw AppFailure(.invalid, detail: message);

String documentId(String value) {
  final id = value.trim();
  if (id.isEmpty || id.contains('/') || id == '.' || id == '..') {
    invalid('Invalid document id.');
  }
  return id;
}

int revisionOf(Json story) => (story['revision'] as num?)?.toInt() ?? 0;

void advanceRevision(DocumentTransaction tx, String storyId, Json story) {
  tx.set('stories/$storyId', {
    'revision': revisionOf(story) + 1,
    'updatedAt': commitTime,
  }, merge: true);
}

class FirestoreDocumentStore implements DocumentStore {
  FirestoreDocumentStore(this.firestore);
  final FirebaseFirestore firestore;

  @override
  String newId(String collection) => firestore.collection(collection).doc().id;

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AppFailure {
      rethrow;
    } on FirebaseException catch (error) {
      throw AppFailure(
        switch (error.code) {
          'permission-denied' || 'unauthenticated' => .denied,
          'unavailable' || 'deadline-exceeded' => .offline,
          'not-found' || 'failed-precondition' || 'aborted' => .invalid,
          _ => .failed,
        },
        cause: error,
        detail: error.message,
      );
    }
  }

  @override
  Future<Json?> get(String path, {bool server = false}) => _guard(() async {
    final snapshot = await firestore
        .doc(path)
        .get(
          GetOptions(source: server ? Source.server : Source.serverAndCache),
        );
    return snapshot.data();
  });

  @override
  Future<List<StoredDoc>> list(
    String collection, {
    Map<String, Object?> equals = const {},
    String? orderBy,
    bool descending = false,
    int? limit,
    bool server = false,
  }) => _guard(() async {
    Query<Json> query = firestore.collection(collection);
    for (final entry in equals.entries) {
      query = query.where(entry.key, isEqualTo: entry.value);
    }
    if (orderBy != null) {
      query = query.orderBy(orderBy, descending: descending);
    }
    if (limit != null) query = query.limit(limit);
    final snapshot = await query.get(
      GetOptions(source: server ? Source.server : Source.serverAndCache),
    );
    return [for (final doc in snapshot.docs) MapEntry(doc.id, doc.data())];
  });

  @override
  Stream<List<StoredDoc>> watch(String collection) => firestore
      .collection(collection)
      .snapshots()
      .map(
        (snapshot) => [
          for (final doc in snapshot.docs) MapEntry(doc.id, doc.data()),
        ],
      );

  @override
  Future<T> transaction<T>(Future<T> Function(DocumentTransaction tx) action) =>
      _guard(
        () => firestore.runTransaction(
          (tx) => action(_FirestoreTransaction(firestore, tx)),
        ),
      );

  @override
  Future<void> batch(List<DocumentWrite> writes) => _guard(() async {
    final batch = firestore.batch();
    for (final write in writes) {
      batch.set(
        firestore.doc(write.path),
        _encode(write.data),
        SetOptions(merge: write.merge),
      );
    }
    await batch.commit();
  });
}

Json _encode(Json data) =>
    data.map((key, value) => MapEntry(key, _value(value)));
Object? _value(Object? value) => switch (value) {
  CommitTime() => FieldValue.serverTimestamp(),
  Map() => _encode(jsonMap(value)),
  List() => [for (final item in value) _value(item)],
  _ => value,
};

class _FirestoreTransaction implements DocumentTransaction {
  _FirestoreTransaction(this.firestore, this.tx);
  final FirebaseFirestore firestore;
  final Transaction tx;

  @override
  Future<Json?> get(String path) async =>
      (await tx.get(firestore.doc(path))).data();

  @override
  void set(String path, Json data, {bool merge = false}) =>
      tx.set(firestore.doc(path), _encode(data), SetOptions(merge: merge));

  @override
  void delete(String path) => tx.delete(firestore.doc(path));
}
