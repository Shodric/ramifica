import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/models/app_failure.dart';

/// Read-only follow state for Explore. The client writes follows only
/// from Profile (`follows/{uid}/authors/{authorId}`); this repository
/// never writes.
class FollowRepository {
  FollowRepository({required this.fetchAuthorIds});

  final Future<Set<String>> Function(String uid) fetchAuthorIds;

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
}

/// Production source: the `follows/{uid}/authors` subcollection, whose
/// doc ids are the followed author ids.
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
  );
}
