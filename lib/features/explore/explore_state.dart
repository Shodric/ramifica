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

  /// Stories by followed authors, regardless of the active tab. Empty
  /// while signed out (no follow set) or when nobody followed has a
  /// published story in the loaded catalog.
  List<StorySummary> get followingStories {
    return [
      for (final story in stories)
        if (story.authorId != null &&
            followingIds.contains(story.authorId))
          story,
    ];
  }

  /// Whether any loaded story is by a followed author (ignores the
  /// query). The Following tab's follow-empty state (with its author
  /// button) shows when this is false and no search is active.
  bool get hasFollowedStories => followingStories.isNotEmpty;

  /// Stories for the active tab, before the search query. The Following
  /// tab keeps only followed authors; For you keeps the whole catalog.
  List<StorySummary> get tabStories {
    if (tab == ExploreTab.following) return followingStories;
    return stories;
  }

  /// Whether [query] narrows the visible list. Blank queries match
  /// everything (tab filter only).
  bool get isSearching => query.trim().isNotEmpty;

  /// What the grids show: the active tab's stories narrowed in memory
  /// by the search query (case-insensitive substring over title,
  /// synopsis, and tags). Empty queries skip matching and return the
  /// tab list as-is. Campaigns and [featuredStory] are promos/hero
  /// slots and stay unfiltered. Never refetches; [QueryChanged] only
  /// re-slices this list.
  List<StorySummary> get filteredStories {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return tabStories;
    return [
      for (final story in tabStories)
        if (_matchesQuery(story, needle)) story,
    ];
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

/// Case-insensitive substring match over a story's title, synopsis, and
/// tags. The needle must already be trimmed and lowercased.
bool _matchesQuery(StorySummary story, String needle) {
  if (story.title.toLowerCase().contains(needle)) return true;
  final synopsis = story.synopsis;
  if (synopsis != null && synopsis.toLowerCase().contains(needle)) {
    return true;
  }
  for (final tag in story.tags) {
    if (tag.toLowerCase().contains(needle)) return true;
  }
  return false;
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
