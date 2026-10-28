import 'package:ramifica/features/explore/explore_state.dart';

sealed class ExploreEvent {
  const ExploreEvent();
}

/// Loads both lists, the featured story, and the follow set.
/// Restartable: opening Explore again refetches.
final class CatalogRequested extends ExploreEvent {
  const CatalogRequested();
}

/// Switches the For you / Following tab. No fetch.
final class CatalogTabSelected extends ExploreEvent {
  const CatalogTabSelected(this.tab);

  final ExploreTab tab;
}

/// Holds the search text. Search behavior is a later slice; the bloc
/// only stores the query.
final class QueryChanged extends ExploreEvent {
  const QueryChanged(this.query);

  final String query;
}

/// Records the tapped story. The view navigates through its `onOpen`
/// callback; the bloc starts no run.
final class StoryStartRequested extends ExploreEvent {
  const StoryStartRequested(this.storyId);

  final String storyId;
}
