import 'package:ramifica/data/models/campaign_summary.dart';
import 'package:ramifica/data/models/story_summary.dart';

enum ExplorePhase { loading, loaded, failed }

enum ExploreTab { forYou, following }

class ExploreState {
  const ExploreState({
    this.phase = ExplorePhase.loading,
    this.tab = ExploreTab.forYou,
    this.stories = const [],
    this.featuredStory,
    this.campaigns = const [],
    this.followingIds = const {},
    this.query = '',
    this.failure,
    this.pendingStoryId,
  });

  final ExplorePhase phase;
  final ExploreTab tab;
  final List<StorySummary> stories;
  final StorySummary? featuredStory;
  final List<CampaignSummary> campaigns;
  final Set<String> followingIds;
  final String query;
  final String? failure;
  final String? pendingStoryId;

  /// Stories for the active tab. The Following tab keeps only stories
  /// whose author is followed. The query never filters here; search
  /// behavior is a later slice.
  List<StorySummary> get tabStories {
    if (tab == ExploreTab.following) {
      return [
        for (final story in stories)
          if (story.authorId != null &&
              followingIds.contains(story.authorId)) story,
      ];
    }
    return stories;
  }

  bool isFollowing(String? authorId) =>
      authorId != null && followingIds.contains(authorId);

  ExploreState copy({
    ExplorePhase Function()? phase,
    ExploreTab? tab,
    List<StorySummary>? stories,
    StorySummary? Function()? featuredStory,
    List<CampaignSummary>? campaigns,
    Set<String>? followingIds,
    String? query,
    String? Function()? failure,
    String? Function()? pendingStoryId,
  }) {
    return ExploreState(
      phase: phase == null ? this.phase : phase(),
      tab: tab ?? this.tab,
      stories: stories ?? this.stories,
      featuredStory: featuredStory == null
          ? this.featuredStory
          : featuredStory(),
      campaigns: campaigns ?? this.campaigns,
      followingIds: followingIds ?? this.followingIds,
      query: query ?? this.query,
      failure: failure == null ? this.failure : failure(),
      pendingStoryId: pendingStoryId == null
          ? this.pendingStoryId
          : pendingStoryId(),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ExploreState &&
        other.phase == phase &&
        other.tab == tab &&
        _sameStories(other.stories, stories) &&
        other.featuredStory == featuredStory &&
        _sameCampaigns(other.campaigns, campaigns) &&
        _sameIds(other.followingIds, followingIds) &&
        other.query == query &&
        other.failure == failure &&
        other.pendingStoryId == pendingStoryId;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    tab,
    Object.hashAll(stories),
    featuredStory,
    Object.hashAll(campaigns),
    Object.hashAll(followingIds),
    query,
    failure,
    pendingStoryId,
  );
}

bool _sameStories(List<StorySummary> a, List<StorySummary> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameCampaigns(List<CampaignSummary> a, List<CampaignSummary> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameIds(Set<String> a, Set<String> b) {
  if (a.length != b.length) return false;
  for (final id in a) {
    if (!b.contains(id)) return false;
  }
  return true;
}
