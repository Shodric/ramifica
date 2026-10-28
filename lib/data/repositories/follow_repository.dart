import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/story_summary.dart';

/// One `stories` doc fetched for the Following feed: doc id plus raw data.
///
/// The repository sorts raw docs by `publishedAt` before mapping them to
/// [StorySummary] (which carries no timestamp), mirroring the grid reads in
/// `CatalogRepository`.
class FollowStoryDoc {
  const FollowStoryDoc(this.id, this.data);

  final String id;
  final Map<String, dynamic> data;
}

/// Read-mostly follow state for Explore and Profile. Reads come from
/// `follows/{uid}/authors`; writes go to the same path, but only from
/// Profile (follow/unfollow an author the viewer is looking at).
class FollowRepository {
  FollowRepository({
    required this.fetchAuthorIds,
    this.fetchStoryDocs,
    this.writeFollow,
    this.removeFollow,
  });

  final Future<Set<String>> Function(String uid) fetchAuthorIds;

  /// Writes `follows/{uid}/authors/{authorId}`. Null in setups that
  /// never follow from Profile (feed/explore-only tests).
  final Future<void> Function(String uid, String authorId)? writeFollow;

  /// Deletes `follows/{uid}/authors/{authorId}`. Null alongside
  /// [writeFollow].
  final Future<void> Function(String uid, String authorId)? removeFollow;

  /// Reads one batch of `stories` docs whose `authorId` is in [authorIds].
  /// Never called with an empty list or more than [authorBatchSize] ids.
  /// Null in setups that never show the Following feed (swipe-only tests).
  final Future<List<FollowStoryDoc>> Function(List<String> authorIds)?
      fetchStoryDocs;


  /// Firestore `in` accepts at most 10 values per query.
  static const int authorBatchSize = 10;

  /// At most this many batches are read; only the first
  /// `authorBatchSize * maxAuthorBatches` followed authors (sorted for
  /// determinism) contribute to the feed. Follows are a small set in
  /// practice; the cap keeps a pathological follow list from fanning out
  /// into unbounded reads.
  static const int maxAuthorBatches = 10;

  /// Ids of the authors [uid] follows. Blank uids (signed out) follow
  /// nobody and never touch the network.
  Future<Set<String>> followingIds(String uid) {
    final id = uid.trim();
    if (id.isEmpty) return Future.value(const <String>{});
    return fetchAuthorIds(id);
  }

  /// Whether [uid] follows [authorId]. Blank ids are never following.
  Future<bool> isFollowing({
    required String uid,
    required String authorId,
  }) async {
    final author = authorId.trim();
    if (uid.trim().isEmpty || author.isEmpty) return false;
    final ids = await fetchAuthorIds(uid.trim());
    return ids.contains(author);
  }

  /// Follows [authorId] as [uid] by creating
  /// `follows/{uid}/authors/{authorId}`. Blank ids are a no-op and never
  /// touch the network; a missing writer is also a no-op (read-only
  /// setups). Failures throw [AppFailure]; the bloc shows its phrase.
  Future<void> follow({required String uid, required String authorId}) {
    final user = uid.trim();
    final author = authorId.trim();
    if (user.isEmpty || author.isEmpty) return Future.value();
    final write = writeFollow;
    if (write == null) return Future.value();
    return write(user, author);
  }

  /// Unfollows [authorId] as [uid] by deleting
  /// `follows/{uid}/authors/{authorId}`. Same no-op contract as [follow].
  Future<void> unfollow({required String uid, required String authorId}) {
    final user = uid.trim();
    final author = authorId.trim();
    if (user.isEmpty || author.isEmpty) return Future.value();
    final remove = removeFollow;
    if (remove == null) return Future.value();
    return remove(user, author);
  }

  /// Published stories by the authors [uid] follows, newest first.
  ///
  /// Reads the followed ids, then one `authorId in (...)` query per batch
  /// of [authorBatchSize] ids. Batches merge here and sort in memory by
  /// `publishedAt` desc: `in` plus `orderBy` would need a composite index
  /// for no read-cost saving (every batch is read whole anyway), so the
  /// server query stays two equality filters (`authorId in`, `status ==`)
  /// and the ordering stays client-side. Docs without `publishedAt` sort
  /// last; malformed docs are skipped.
  ///
  /// Blank uids and empty follow lists return empty without any network
  /// call. A failing batch is skipped; it never kills the other batches.
  Future<List<StorySummary>> followingStories(String uid) async {
    final id = uid.trim();
    if (id.isEmpty) return const [];
    final ids = await fetchAuthorIds(id);
    if (ids.isEmpty) return const [];
    final fetch = fetchStoryDocs;
    if (fetch == null) return const [];
    final authors = ids.toList()..sort();
    final capped = authors.take(authorBatchSize * maxAuthorBatches).toList();
    final docs = <FollowStoryDoc>[];
    for (var i = 0; i < capped.length; i += authorBatchSize) {
      final batch = capped.sublist(i, min(i + authorBatchSize, capped.length));
      try {
        docs.addAll(await fetch(batch));
      } on Exception {
        continue;
      }
    }
    docs.sort(
      (a, b) => _publishedRank(b.data).compareTo(_publishedRank(a.data)),
    );
    final stories = <StorySummary>[];
    for (final doc in docs) {
      try {
        stories.add(StorySummary.fromDoc(doc.id, doc.data));
      } on AppFailure {
        continue;
      }
    }
    return stories;
  }
}

/// Production source: the `follows/{uid}/authors` subcollection, whose
/// doc ids are the followed author ids, plus batched `stories` reads.
///
/// The story query pairs `authorId in (batch)` with `status ==
/// 'published'`: the status filter is load-bearing, not just an
/// optimization — without it the query matches drafts the reader may not
/// see (firestore.rules only opens drafts to their author) and Firestore
/// fails the whole query. The pair needs a composite index on
/// `stories(authorId, status)` (see firestore.indexes.json).
FollowRepository createFirebaseFollowRepository([
  FirebaseFirestore? firestore,
]) {
  final db = firestore ?? FirebaseFirestore.instance;
  return FollowRepository(
    fetchAuthorIds: (uid) async {
      try {
        final snap = await db
            .collection('follows')
            .doc(uid)
            .collection('authors')
            .get();
        return {for (final doc in snap.docs) doc.id};
      } on FirebaseException catch (error) {
        throw AppFailure(appFailureCodeFor(error.code), cause: error);
      } catch (error) {
        throw AppFailure(.failed, cause: error);
      }
    },
    fetchStoryDocs: (authorIds) async {
      try {
        final snap = await db
            .collection('stories')
            .where('authorId', whereIn: authorIds)
            .where('status', isEqualTo: 'published')
            .get();
        return [
          for (final doc in snap.docs) FollowStoryDoc(doc.id, doc.data()),
        ];
      } on FirebaseException catch (error) {
        throw AppFailure(appFailureCodeFor(error.code), cause: error);
      } catch (error) {
        throw AppFailure(.failed, cause: error);
      }
    },
    // Writes land on the same `follows/{uid}/authors/{authorId}` docs
    // the reads mirror. firestore.rules allows read and write exactly
    // when the signed-in uid owns the parent, so no new backend was
    // needed for #39.
    writeFollow: (uid, authorId) async {
      try {
        await db
            .collection('follows')
            .doc(uid)
            .collection('authors')
            .doc(authorId)
            .set({'createdAt': FieldValue.serverTimestamp()});
      } on FirebaseException catch (error) {
        throw AppFailure(appFailureCodeFor(error.code), cause: error);
      } catch (error) {
        throw AppFailure(.failed, cause: error);
      }
    },
    removeFollow: (uid, authorId) async {
      try {
        await db
            .collection('follows')
            .doc(uid)
            .collection('authors')
            .doc(authorId)
            .delete();
      } on FirebaseException catch (error) {
        throw AppFailure(appFailureCodeFor(error.code), cause: error);
      } catch (error) {
        throw AppFailure(.failed, cause: error);
      }
    },
  );
}

/// Newest `publishedAt` first; docs without one sort last. Accepts the
/// Timestamp, numeric epoch, and ISO-string shapes the console writes.
/// Duplicates the grid helper in `CatalogRepository` (exclusive file
/// ownership); extract to a shared parser if a third reader appears.
int _publishedRank(Map<String, dynamic> data) {
  final value = data['publishedAt'];
  if (value is Timestamp) return value.millisecondsSinceEpoch;
  if (value is num) return value.toInt();
  if (value is String) {
    final parsed = DateTime.tryParse(value.trim());
    if (parsed != null) return parsed.millisecondsSinceEpoch;
  }
  return -1;
}
