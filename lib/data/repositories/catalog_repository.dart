import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/models/app_failure.dart';

/// Published story ids for the swipe draw. Phase 1 draws in memory from
/// this list; a later slice draws on the server.
class CatalogRepository {
  CatalogRepository({required this.fetchPublishedIds});

  final Future<List<String>> Function() fetchPublishedIds;

  Future<List<String>> publishedStoryIds() => fetchPublishedIds();
}

/// Production source: `stories` with `status == published`. Ids only, so no
/// composite index is needed (Explore's ordered grids are a later slice).
CatalogRepository createFirebaseCatalogRepository([
  FirebaseFirestore? firestore,
]) {
  final db = firestore ?? FirebaseFirestore.instance;
  return CatalogRepository(
    fetchPublishedIds: () async {
      try {
        final snap = await db
            .collection('stories')
            .where('status', isEqualTo: 'published')
            .get();
        return [for (final doc in snap.docs) doc.id];
      } on FirebaseException catch (error) {
        throw AppFailure(appFailureCodeFor(error.code), cause: error);
      } catch (error) {
        throw AppFailure(.failed, cause: error);
      }
    },
  );
}
