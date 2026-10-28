import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/core/widgets/author_row.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/core/widgets/story_card.dart';
import 'package:ramifica/data/models/campaign_summary.dart';
import 'package:ramifica/data/models/story_summary.dart';
import 'package:ramifica/data/repositories/catalog_repository.dart';
import 'package:ramifica/data/repositories/follow_repository.dart';
import 'package:ramifica/features/explore/campaign_card.dart';
import 'package:ramifica/features/explore/explore_bloc.dart';
import 'package:ramifica/features/explore/explore_event.dart';
import 'package:ramifica/features/explore/explore_state.dart';

/// Explore tab: scrolling column of cards drawn from [ExploreBloc] state.
/// Creates its own bloc; tests inject [bloc]. Story taps send
/// [StoryStartRequested] and leave through [onStoryOpen]; the view never
/// calls a repository or the router directly.
class ExploreView extends StatefulWidget {
  const ExploreView({
    super.key,
    this.bloc,
    this.uid,
    this.onStoryOpen,
    this.onAuthorOpen,
  });

  final ExploreBloc? bloc;

  /// The signed-in user, or null while signed out. Signed out still browses
  /// the catalog; the follow set stays empty.
  final String? uid;
  final void Function(String storyId)? onStoryOpen;
  final void Function(String authorId)? onAuthorOpen;

  @override
  State<ExploreView> createState() => _ExploreViewState();
}

class _ExploreViewState extends State<ExploreView> {
  ExploreBloc? _bloc;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bloc != null) return;
    _bloc =
        widget.bloc ??
              ExploreBloc(
                catalog: createFirebaseCatalogRepository(),
                follows: createFirebaseFollowRepository(),
                uid: widget.uid,
              )
          ..add(const CatalogRequested());
  }

  @override
  void dispose() {
    if (widget.bloc == null) _bloc?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bloc = _bloc;
    if (bloc == null) {
      return const Scaffold(body: SizedBox.shrink());
    }
    return BlocProvider.value(
      value: bloc,
      child: Builder(
        builder: (context) => BlocBuilder<ExploreBloc, ExploreState>(
          builder: (context, state) {
            return Scaffold(
              body: Semantics(
                label: 'Explore',
                child: SafeArea(child: _body(context, state)),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ExploreState state) {
    if (state.phase == .loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.phase == .failed) {
      return Center(
        child: FailureText(
          message: state.failure ?? 'Something failed',
          onRetry: () => _reload(context),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => _reload(context),
      child: ListView(
        padding: const .all(16),
        children: [
          TextField(
            key: const Key('exploreSearch'),
            decoration: const InputDecoration(
              hintText: 'Search',
              prefixIcon: Icon(Icons.search),
            ),
            textInputAction: .search,
            onChanged: (query) =>
                context.read<ExploreBloc>().add(QueryChanged(query)),
          ),
          const SizedBox(height: 12),
          SegmentedButton<ExploreTab>(
            segments: const [
              ButtonSegment(value: .forYou, label: Text('For you')),
              ButtonSegment(value: .following, label: Text('Following')),
            ],
            selected: {state.tab},
            onSelectionChanged: (tabs) => context.read<ExploreBloc>().add(
              CatalogTabSelected(tabs.single),
            ),
          ),
          const SizedBox(height: 16),
          if (state.tab == .following)
            _following(context, state)
          else
            _forYou(context, state),
        ],
      ),
    );
  }

  Widget _forYou(BuildContext context, ExploreState state) {
    final featured = state.featuredStory;
    final campaigns = state.campaigns;
    final stories = state.tabStories;
    if (featured == null && campaigns.isEmpty && stories.isEmpty) {
      return const Center(
        child: EmptyState(message: 'No stories yet. Check back soon.'),
      );
    }
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        if (featured != null) ...[
          StoryCard(
            title: featured.title,
            authorName: _authorLabel(featured.authorName, featured.authorId),
            coverUrl: featured.coverUrl,
            campaignLabel: featured.campaignLabel,
            onOpen: () => _openStory(context, featured.storyId),
          ),
          const SizedBox(height: 16),
        ],
        for (final campaign in campaigns) ...[
          _campaignCard(context, state, campaign),
          const SizedBox(height: 16),
        ],
        for (final story in stories) ...[
          StoryCard(
            title: story.title,
            authorName: _authorLabel(story.authorName, story.authorId),
            coverUrl: story.coverUrl,
            campaignLabel: story.campaignLabel,
            onOpen: () => _openStory(context, story.storyId),
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  /// A campaign carries the brand plus whatever the story payload has; the
  /// author name rides the matching story. The reward is never shown.
  Widget _campaignCard(
    BuildContext context,
    ExploreState state,
    CampaignSummary campaign,
  ) {
    StorySummary? story;
    for (final candidate in state.stories) {
      if (candidate.storyId == campaign.storyId) story = candidate;
    }
    return CampaignCard(
      title: campaign.title ?? story?.title ?? '',
      authorName: _authorLabel(story?.authorName, story?.authorId),
      brandLabel: campaign.brandLabel,
      coverUrl: campaign.coverUrl ?? story?.coverUrl,
      onOpen: () => _openStory(context, campaign.storyId),
    );
  }

  /// Following tab: one row per author behind the tab-filtered stories.
  /// Follow state is read-only display from [ExploreState.followingIds].
  Widget _following(BuildContext context, ExploreState state) {
    final seen = <String>{};
    final rows = <AuthorRow>[];
    for (final story in state.tabStories) {
      final authorId = story.authorId?.trim() ?? '';
      if (authorId.isEmpty || !seen.add(authorId)) continue;
      rows.add(
        AuthorRow(
          name: (story.authorName?.trim().isNotEmpty ?? false)
              ? story.authorName!.trim()
              : authorId,
          handle: '@$authorId',
          isFollowing: state.followingIds.contains(authorId),
          onOpen: () => _openAuthor(authorId),
        ),
      );
    }
    if (rows.isEmpty) {
      return const Center(
        child: EmptyState(
          message: 'Stories from people you follow show up here.',
        ),
      );
    }
    return Column(
      mainAxisSize: .min,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          rows[i],
          if (i != rows.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }

  String _authorLabel(String? authorName, String? authorId) {
    final name = authorName?.trim() ?? '';
    if (name.isNotEmpty) return name;
    return (authorId?.trim().isEmpty ?? true) ? '' : authorId!.trim();
  }

  void _reload(BuildContext context) {
    context.read<ExploreBloc>().add(const CatalogRequested());
  }

  void _openStory(BuildContext context, String storyId) {
    context.read<ExploreBloc>().add(StoryStartRequested(storyId));
    final open = widget.onStoryOpen;
    if (open != null) {
      open(storyId);
      return;
    }
    try {
      AppNavigation.read(context)
          .go(AppRoutes.storyPath(Uri.encodeComponent(storyId)));
    } on FlutterError {
      // Widget tests mount ExploreView without the router.
    }
  }

  void _openAuthor(String authorId) {
    widget.onAuthorOpen?.call(authorId);
  }
}
