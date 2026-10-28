import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:ramifica/core/functions_client.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/campaign_summary.dart';
import 'package:ramifica/data/models/story_summary.dart';

/// Published stories and active campaigns for Explore. The swipe draw in
/// [publishedStoryIds] stays; the grids read the typed lists below.
class CatalogRepository {
  CatalogRepository({
    required this.fetchPublishedIds,
    this.fetchPublishedStories,
    this.fetchActiveCampaigns,
  });

  final Future<List<String>> Function() fetchPublishedIds;

  /// Overrides the Firestore grid reads below. Tests pass lambdas that
  /// return typed models; production uses [createFirebaseCatalogRepository].
  final Future<List<StorySummary>> Function()? fetchPublishedStories;
  final Future<List<CampaignSummary>> Function()? fetchActiveCampaigns;

  Future<List<String>> publishedStoryIds() => fetchPublishedIds();

  /// Every published story. Without an injected fetch, falls back to the
  /// id list with minimal summaries (swipe-only setups never call this).
  Future<List<StorySummary>> publishedStories() async {
    final fetch = fetchPublishedStories;
    if (fetch != null) return fetch();
    final ids = await fetchPublishedIds();
    return [
      for (final id in ids) StorySummary(storyId: id, title: id),
    ];
  }

  /// The featured published story, picked in memory like `startRun` does,
  /// so no composite index is needed. Null when none is flagged.
  Future<StorySummary?> featuredStory() async {
    final stories = await publishedStories();
    for (final story in stories) {
      if (story.featured) return story;
    }
    return null;
  }

  /// Active campaigns. Empty without an injected fetch.
  Future<List<CampaignSummary>> activeCampaigns() async {
    final fetch = fetchActiveCampaigns;
    if (fetch != null) return fetch();
    return const [];
  }
}

/// Production source: `stories` with `status == published`, and
/// `campaigns` with `active == true`. Both are single-field equality
/// filters, so no composite index is needed; grids sort in memory.
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
    fetchPublishedStories: () async {
      try {
        final snap = await db
            .collection('stories')
            .where('status', isEqualTo: 'published')
            .limit(50)
            .get();
        final docs = snap.docs.toList()
          ..sort(
            (a, b) => _publishedRank(b.data()).compareTo(
              _publishedRank(a.data()),
            ),
          );
        final stories = <StorySummary>[];
        for (final doc in docs) {
          try {
            stories.add(StorySummary.fromDoc(doc.id, doc.data()));
          } on AppFailure {
            continue;
          }
        }
        return stories;
      } on FirebaseException catch (error) {
        throw AppFailure(appFailureCodeFor(error.code), cause: error);
      } catch (error) {
        throw AppFailure(.failed, cause: error);
      }
    },
    fetchActiveCampaigns: () async {
      try {
        final snap = await db
            .collection('campaigns')
            .where('active', isEqualTo: true)
            .limit(20)
            .get();
        final campaigns = <CampaignSummary>[];
        for (final doc in snap.docs) {
          try {
            campaigns.add(CampaignSummary.fromDoc(doc.id, doc.data()));
          } on AppFailure {
            continue;
          }
        }
        return campaigns;
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
