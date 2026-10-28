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
    this.fetchFeaturedStory,
    this.fetchActiveCampaigns,
  });

  final Future<List<String>> Function() fetchPublishedIds;

  /// Overrides the Firestore grid reads below. Tests pass lambdas that
  /// return typed models; production uses [createFirebaseCatalogRepository].
  final Future<List<StorySummary>> Function()? fetchPublishedStories;

  /// Override for the featured query below. Tests pass a lambda returning
  /// the single featured model (or null); production uses
  /// [createFirebaseCatalogRepository].
  final Future<StorySummary?> Function()? fetchFeaturedStory;

  /// Overrides the Firestore campaigns read below. Tests pass lambdas that
  /// return typed models; production uses [createFirebaseCatalogRepository].
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

  /// The featured published story. Without an injected fetch, falls back
  /// to the first flagged story in [publishedStories] (swipe-only setups
  /// and tests without a featured fetch use this path). Null when none
  /// is flagged.
  Future<StorySummary?> featuredStory() async {
    final fetch = fetchFeaturedStory;
    if (fetch != null) return fetch();
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
/// Production source:
/// * grid: `stories` with `status == published`, newest `publishedAt`
///   first (`orderBy('publishedAt', descending: true)`, first page of 50);
/// * featured: `stories` with `status == published` and
///   `featured == true`, `limit(1)`;
/// * campaigns: `campaigns` with `active == true`, `limit(20)`.
///
/// The `status` filter doubles as the security-rules guard: `stories` are
/// readable only when published (or by their author), so every stories
/// query carries it. The grid and featured queries need the composite
/// indexes in `firestore.indexes.json`; the campaigns read is a
/// single-field filter and needs none. Firestore sorts missing
/// `publishedAt` values last under a descending order, which preserves
/// the old in-memory fallback behavior for console-written docs.
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
            .orderBy('publishedAt', descending: true)
            .limit(50)
            .get();
        final stories = <StorySummary>[];
        for (final doc in snap.docs) {
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
    fetchFeaturedStory: () async {
      try {
        final snap = await db
            .collection('stories')
            .where('status', isEqualTo: 'published')
            .where('featured', isEqualTo: true)
            .limit(1)
            .get();
        if (snap.docs.isEmpty) return null;
        final doc = snap.docs.first;
        try {
          return StorySummary.fromDoc(doc.id, doc.data());
        } on AppFailure {
          return null;
        }
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
