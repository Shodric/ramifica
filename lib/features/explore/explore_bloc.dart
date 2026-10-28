import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/story_summary.dart';
import 'package:ramifica/data/repositories/catalog_repository.dart';
import 'package:ramifica/data/repositories/follow_repository.dart';
import 'package:ramifica/features/explore/explore_event.dart';
import 'package:ramifica/features/explore/explore_state.dart';

class ExploreBloc extends Bloc<ExploreEvent, ExploreState> {
  ExploreBloc({
    required this.catalog,
    required this.follows,
    this.uid,
  }) : super(const ExploreState()) {
    on<CatalogRequested>(_onRequested, transformer: restartable());
    on<CatalogTabSelected>(_onTabSelected);
    on<QueryChanged>(_onQueryChanged);
    on<StoryStartRequested>(_onStoryStart);
  }

  final CatalogRepository catalog;
  final FollowRepository follows;

  /// The signed-in user, or null while signed out. Signed out still
  /// browses the catalog; the follow set stays empty.
  final String? uid;

  Future<void> _onRequested(
    CatalogRequested event,
    Emitter<ExploreState> emit,
  ) async {
    emit(state.copy(phase: () => .loading, failure: () => null));
    try {
      final stories = await catalog.publishedStories();
      if (emit.isDone) return;
      final campaigns = await catalog.activeCampaigns();
      if (emit.isDone) return;
      var following = state.followingIds;
      final uid = this.uid;
      if (uid != null && uid.trim().isNotEmpty) {
        following = await follows.followingIds(uid);
        if (emit.isDone) return;
      }
      // In-memory picks only: the hero reuses the loaded grid (the
      // dedicated featured query stays a fallback for setups without a
      // grid), and the Following tab filters these same stories by
      // followed author, so no followingStories fetch is needed here.
      StorySummary? featured;
      for (final story in stories) {
        if (story.featured) {
          featured = story;
          break;
        }
      }
      emit(
        state.copy(
          phase: () => .loaded,
          stories: stories,
          featuredStory: () => featured,
          campaigns: campaigns,
          followingIds: following,
          failure: () => null,
        ),
      );
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(state.copy(phase: () => .failed, failure: () => error.phrase));
    }
  }

  void _onTabSelected(CatalogTabSelected event, Emitter<ExploreState> emit) {
    if (event.tab == state.tab) return;
    emit(state.copy(tab: event.tab));
  }

  void _onQueryChanged(QueryChanged event, Emitter<ExploreState> emit) {
    if (event.query == state.query) return;
    emit(state.copy(query: event.query));
  }

  void _onStoryStart(StoryStartRequested event, Emitter<ExploreState> emit) {
    final storyId = event.storyId.trim();
    emit(
      state.copy(pendingStoryId: () => storyId.isEmpty ? null : storyId),
    );
  }
}
