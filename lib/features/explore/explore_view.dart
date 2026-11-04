import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/core/widgets/author_row.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/features/explore/explore_hero.dart';
import 'package:ramifica/features/explore/explore_story_tile.dart';
import 'package:ramifica/data/models/campaign_summary.dart';
import 'package:ramifica/data/models/story_summary.dart';
import 'package:ramifica/data/repositories/catalog_repository.dart';
import 'package:ramifica/data/repositories/follow_repository.dart';
import 'package:ramifica/features/explore/campaign_card.dart';
import 'package:ramifica/features/explore/explore_bloc.dart';
import 'package:ramifica/features/explore/explore_event.dart';
import 'package:ramifica/features/explore/explore_state.dart';

/// Explore tab: scrolling column of cards drawn from [ExploreBloc] state.
/// Creates its own bloc; tests inject [bloc]. Story taps record
/// [StoryStartRequested] and leave through [onStoryOpen] (or the story
/// route when no callback is set); the view never calls a repository or
/// startRun — playback starts in Feed.
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
  final TextEditingController _queryController = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bloc != null) return;
    final injected = widget.bloc;
    if (injected != null) {
      _bloc = injected..add(const CatalogRequested());
      return;
    }
    // Widget tests mount the shell without Firebase: stay on a static
    // page instead of throwing. Production initializes Firebase in main
    // before this tab builds, like ProfileView.
    try {
      _bloc = ExploreBloc(
        catalog: createFirebaseCatalogRepository(),
        follows: createFirebaseFollowRepository(),
        uid: widget.uid,
      )..add(const CatalogRequested());
    } catch (_) {
      _bloc = null;
    }
  }

  @override
  void dispose() {
    if (widget.bloc == null) _bloc?.close();
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bloc = _bloc;
    if (bloc == null) {
      return const Scaffold(body: SafeArea(child: _Unavailable()));
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
    if (_queryController.text != state.query) {
      _queryController.text = state.query;
    }
    return RefreshIndicator(
      onRefresh: () async => _reload(context),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('exploreSearch'),
            controller: _queryController,
            decoration: InputDecoration(
              hintText: 'Search stories, sagas, creators, or universes',
              hintStyle: const TextStyle(
                color: RamificaColors.textSecondary,
                fontSize: 14,
              ),
              prefixIcon: const Icon(
                Icons.search,
                color: RamificaColors.textSecondary,
                size: 20,
              ),
              filled: true,
              fillColor: RamificaColors.containerHigh,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            style: const TextStyle(
              color: RamificaColors.textPrimary,
              fontSize: 14,
            ),
            textInputAction: TextInputAction.search,
            onChanged: (query) =>
                context.read<ExploreBloc>().add(QueryChanged(query)),
          ),
          const SizedBox(height: 12),
          _TabBar(
            tab: state.tab,
            onSelected: (tab) =>
                context.read<ExploreBloc>().add(CatalogTabSelected(tab)),
          ),
          const SizedBox(height: 12),
          if (state.tab == ExploreTab.forYou)
            _TopicPills(
              query: state.query,
              onSelected: (value) =>
                  context.read<ExploreBloc>().add(QueryChanged(value)),
            ),
          if (state.tab == ExploreTab.forYou) const SizedBox(height: 16),
          if (state.tab == ExploreTab.following)
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
    final stories = state.filteredStories;
    if (featured == null && campaigns.isEmpty && stories.isEmpty) {
      if (state.isSearching) {
        return const Center(
          child: EmptyState(
            message: 'No stories match your search. Try another search.',
          ),
        );
      }
      return const Center(
        child: EmptyState(message: 'No stories yet. Check back soon.'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (featured != null) ...[
          ExploreHero(
            title: featured.title,
            creatorLabel: _creatorLabel(featured.authorName, featured.authorId),
            synopsis: featured.synopsis,
            coverUrl: featured.coverUrl,
            onOpen: () => _openStory(context, featured.storyId),
          ),
          const SizedBox(height: 20),
        ],
        if (campaigns.isNotEmpty) ...[
          const _SectionHeader(
            icon: Icons.verified,
            iconColor: RamificaColors.rewardGold,
            title: 'Sponsored Experiences',
            trailing: 'Interactive',
          ),
          const SizedBox(height: 12),
          for (final campaign in campaigns) ...[
            _campaignCard(context, state, campaign),
            const SizedBox(height: 16),
          ],
        ],
        if (stories.isNotEmpty) ...[
          const _SectionHeader(
            icon: Icons.hub,
            iconColor: RamificaColors.nodeActive,
            title: 'Trending Routes',
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 16,
              mainAxisExtent: 400,
            ),
            itemCount: stories.length,
            itemBuilder: (context, index) {
              final story = stories[index];
              return ExploreStoryTile(
                title: story.title,
                authorName:
                    '@${_authorLabel(story.authorName, story.authorId)}',
                coverUrl: story.coverUrl,
                onOpen: () => _openStory(context, story.storyId),
              );
            },
          ),
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

  /// Following tab: one row per author behind the query-filtered stories.
  /// Follow state is read-only display from [ExploreState.followingIds].
  /// Empty while not searching and nobody followed offers a button back
  /// to the For you tab (author browse); empty from a search shows the
  /// no-results state instead.
  Widget _following(BuildContext context, ExploreState state) {
    final seen = <String>{};
    final rows = <AuthorRow>[];
    for (final story in state.filteredStories) {
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
      if (!state.isSearching && !state.hasFollowedStories) {
        return Center(
          child: EmptyState(
            message: 'Stories from people you follow show up here.',
            actionLabel: 'Browse stories',
            onAction: () => context.read<ExploreBloc>().add(
              const CatalogTabSelected(ExploreTab.forYou),
            ),
          ),
        );
      }
      return const Center(
        child: EmptyState(
          message: 'No stories match your search. Try another search.',
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

  String _creatorLabel(String? authorName, String? authorId) {
    final id = authorId?.trim() ?? '';
    final name = authorName?.trim() ?? '';
    if (id.isNotEmpty && name.isNotEmpty) return '@$id • $name';
    if (id.isNotEmpty) return '@$id';
    return name;
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

/// For you / Following tabs, Stitch-style: the active label carries a cyan
/// underline, inactive labels are dimmed. No animation.
class _TabBar extends StatelessWidget {
  const _TabBar({required this.tab, required this.onSelected});

  final ExploreTab tab;
  final void Function(ExploreTab tab) onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _TabButton(
          label: 'For you',
          selected: tab == ExploreTab.forYou,
          onTap: () => onSelected(ExploreTab.forYou),
        ),
        const SizedBox(width: 24),
        _TabButton(
          label: 'Following',
          selected: tab == ExploreTab.following,
          onTap: () => onSelected(ExploreTab.following),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? RamificaColors.hotspot : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: RamificaText.label.copyWith(
            color: selected
                ? RamificaColors.textPrimary
                : RamificaColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Genre shortcuts. Tapping a pill narrows the in-memory catalog by
/// dispatching the existing [QueryChanged] event; Featured clears it.
/// Selection is derived from the query only. No animation.
class _TopicPills extends StatelessWidget {
  const _TopicPills({required this.query, required this.onSelected});

  final String query;
  final void Function(String value) onSelected;

  static const _pills = <String, String>{
    'Featured': '',
    'Sci-Fi': 'sci-fi',
    'Escape Room': 'escape',
    'Mythic Adventure': 'mythic',
    'Mystery & Suspense': 'mystery',
  };

  @override
  Widget build(BuildContext context) {
    final active = query.trim().toLowerCase();
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _pills.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final entry = _pills.entries.elementAt(index);
          final selected = active == entry.value.toLowerCase();
          return GestureDetector(
            onTap: () => onSelected(entry.value),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected
                    ? RamificaColors.hotspot
                    : RamificaColors.containerHigh,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                entry.key,
                style: RamificaText.labelSM.copyWith(
                  color: selected
                      ? RamificaColors.onSecondary
                      : RamificaColors.textPrimary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Section header: leading icon, title, optional trailing label.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.trailing,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: iconColor),
        const SizedBox(width: 6),
        Expanded(child: Text(title, style: RamificaText.headlineSM)),
        if (trailing != null) Text(trailing!, style: RamificaText.meta),
      ],
    );
  }
}

/// Static page when no bloc exists: widget tests mount the shell without
/// Firebase, so the factories throw and the tab keeps its title.
class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const .all(16),
      children: const [
        Text('Explore', style: RamificaText.screenTitle),
        SizedBox(height: 16),
        EmptyState(message: 'Explore is unavailable right now.'),
      ],
    );
  }
}
