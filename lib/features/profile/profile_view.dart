import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/data/models/draft_story.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/data/repositories/firebase_auth_gateway.dart';
import 'package:ramifica/data/repositories/follow_repository.dart';
import 'package:ramifica/features/profile/ending_list.dart';
import 'package:ramifica/features/profile/profile_bloc.dart';
import 'package:ramifica/features/profile/profile_event.dart';
import 'package:ramifica/features/profile/profile_header.dart';
import 'package:ramifica/features/profile/profile_state.dart';
import 'package:ramifica/features/profile/saga_list.dart';

/// Profile tab: title AppBar with edit/sign-out icons, install banner,
/// then the header or editor drawn from [ProfileBloc]. Creates its own
/// bloc like Explore; tests
/// inject [bloc] and read recorded events instead of touching Firebase.
/// A foreign profile passes its id in [authorId]; null means the
/// signed-in person's own profile. Edit mode and dismissal are local
/// view state; everything else arrives as bloc state and leaves as an
/// event. Sign out ends the bloc in `signedOut`; the shell owns the trip
/// back to Access.
class ProfileView extends StatefulWidget {
  const ProfileView({
    super.key,
    this.bloc,
    this.authorId,
    this.showInstallGuide,
    this.unlockedEndings = const [],
    this.onEndingOpen,
    this.sagaStories = const [],
    this.onSagaOpen,
    this.fetchAuthorStories,
    this.onDraftOpen,
    this.initialTab = 0,
  });

  final ProfileBloc? bloc;

  /// The viewed author, or null for the signed-in person.
  final String? authorId;

  /// Test seam for the install banner. Production uses the platform check.
  final bool Function()? showInstallGuide;

  /// Unlocked endings to list. Profile state carries no endings today, so
  /// the owner passes them in until a readable source exists (see
  /// [UnlockedEnding]; wiring gap noted for the reviewer).
  final List<UnlockedEnding> unlockedEndings;

  /// Test seam for ending taps. Null navigates to the graph route.
  final void Function(String storyId)? onEndingOpen;

  /// Ordered saga stories to list. Profile state carries no saga progress
  /// today, so the owner passes them in until a readable source exists
  /// (see [SagaStory]: `unlocked` is true for the entry story or when
  /// that story's `sagaUnlocked` flag is set; locked entries stay
  /// title-free).
  final List<SagaStory> sagaStories;

  /// Test seam for saga story taps. Null navigates to the story route.
  final void Function(String storyId)? onSagaOpen;

  /// Lists the signed-in user's own stories for the Creations tab.
  /// Null in tests without a story source: the tab stays empty.
  /// Production wires `CreateRepository.fetchAuthorStories`.
  final Future<List<DraftStory>> Function({required String authorId})?
  fetchAuthorStories;

  /// Test seam for creation taps. Null navigates to the canvas editor
  /// through the `/create/:id` deep link.
  final void Function(String storyId)? onDraftOpen;

  /// Content tab to select (0 sagas, 1 endings, 2 creations). The shell
  /// sets it from the `/profile/<tab>` deep link; out-of-range values
  /// fall back to the default tab.
  final int initialTab;

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  ProfileBloc? _bloc;
  var _editing = false;
  var _saveInFlight = false;
  late var _tab = _clampTab(widget.initialTab);

  static int _clampTab(int tab) => tab >= 0 && tab <= 2 ? tab : 0;

  @override
  void didUpdateWidget(covariant ProfileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The shell reuses this view across `/profile/<tab>` deep links, so
    // sync the selected tab when the route changes underneath us.
    if (widget.initialTab != oldWidget.initialTab) {
      _tab = _clampTab(widget.initialTab);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bloc != null) return;
    final injected = widget.bloc;
    if (injected != null) {
      _bloc = injected;
      return;
    }
    // Widget tests mount the shell without Firebase: stay on a static
    // page instead of throwing. Production initializes Firebase in main
    // before this tab builds, like FeedView's missing-bloc fallback.
    try {
      _bloc = ProfileBloc(
        auth: createFirebaseAuthRepository(),
        users: FirestoreUserDirectory(),
        follows: createFirebaseFollowRepository(),
        fetchAuthorStories:
            widget.fetchAuthorStories ??
            createFirebaseCreateRepository().fetchAuthorStories,
      )..add(ProfileRequested(authorId: widget.authorId));
      // Own profile only: foreign viewers never see these drafts.
      if (widget.authorId == null) {
        _bloc!.add(const ProfileDraftsRequested());
      }
    } catch (_) {
      _bloc = null;
    }
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
      return const Scaffold(body: SafeArea(child: _Unavailable()));
    }
    return BlocProvider.value(
      value: bloc,
      child: BlocListener<ProfileBloc, ProfileState>(
        listener: _closeEditorOnSaved,
        child: BlocBuilder<ProfileBloc, ProfileState>(
          builder: (context, state) {
            final showActions =
                state.phase == ProfilePhase.loaded && state.isOwn && !_editing;
            return Scaffold(
              appBar: AppBar(
                backgroundColor: RamificaColors.surface,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                title: const Text('Profile', style: RamificaText.screenTitle),
                actions: [
                  if (showActions) ...[
                    IconButton(
                      key: const Key('profileEditButton'),
                      tooltip: 'Edit profile',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => setState(() => _editing = true),
                    ),
                    IconButton(
                      key: const Key('profileSignOutButton'),
                      tooltip: 'Sign out',
                      icon: const Icon(Icons.logout),
                      onPressed: () => context.read<ProfileBloc>().add(
                        const SignOutRequested(),
                      ),
                    ),
                  ],
                ],
              ),
              body: SafeArea(child: _body(context, state)),
            );
          },
        ),
      ),
    );
  }

  void _closeEditorOnSaved(BuildContext context, ProfileState state) {
    if (!_saveInFlight || state.saving) return;
    _saveInFlight = false;
    if (state.failure == null && mounted) {
      setState(() => _editing = false);
    }
  }

  Widget _body(BuildContext context, ProfileState state) {
    return ListView(
      padding: const .all(16),
      children: [
        switch (state.phase) {
          .loading => const Center(child: CircularProgressIndicator()),
          .failed => Center(
            child: FailureText(
              message: state.failure ?? 'Something failed',
              onRetry: () => _reload(context),
            ),
          ),
          .signedOut => const EmptyState(message: 'Signed out.'),
          .loaded => _loaded(context, state),
        },
      ],
    );
  }

  Widget _loaded(BuildContext context, ProfileState state) {
    final editing = _editing && state.isOwn;
    final sagas = widget.sagaStories;
    final featured = _firstUnlocked(sagas);
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        if (editing)
          ProfileEditForm(
            initialDisplayName: state.displayName,
            initialHandle: state.handle,
            initialPhotoUrl: state.photoUrl,
            initialLocale: state.locale,
            saving: state.saving,
            failure: state.failure,
            onSave:
                ({
                  required displayName,
                  required handle,
                  required photoUrl,
                  required locale,
                }) => _save(
                  context,
                  displayName: displayName,
                  handle: handle,
                  photoUrl: photoUrl,
                  locale: locale,
                ),
            onCancel: () => setState(() => _editing = false),
          )
        else
          ProfileHeader(
            displayName: state.displayName,
            handle: state.handle,
            photoUrl: state.photoUrl,
            locale: state.locale,
            isOwn: state.isOwn,
            isFollowing: state.isFollowing,
            followingCount: state.followingCount,
            toggling: state.toggling,
            onFollowToggle: () =>
                context.read<ProfileBloc>().add(const FollowToggled()),
          ),
        if (state.failure != null && !editing) ...[
          const SizedBox(height: 12),
          Text(
            state.failure!,
            style: RamificaText.body.copyWith(color: RamificaColors.error),
          ),
        ],
        const SizedBox(height: 16),
        _MetricsRow(
          sagas: sagas.length,
          endings: widget.unlockedEndings.length,
          following: state.followingCount,
        ),
        const SizedBox(height: 16),
        _TabBar(
          tab: _tab,
          sagas: sagas.length,
          onSelect: (index) => setState(() => _tab = index),
        ),
        const SizedBox(height: 16),
        if (_tab == 0) ...[
          if (featured != null) ...[
            _FeaturedSaga(
              story: featured,
              total: sagas.length,
              onOpen: () => _openSaga(context, featured.storyId),
            ),
            const SizedBox(height: 16),
          ],
          SagaList(
            stories: sagas,
            onOpen: (storyId) => _openSaga(context, storyId),
          ),
        ],
        if (_tab == 1)
          EndingList(
            endings: widget.unlockedEndings,
            onOpen: (storyId) => _openEnding(context, storyId),
          ),
        if (_tab == 2)
          _CreationsCard(
            drafts: state.drafts,
            onOpen: (id) => _openDraft(context, id),
          ),
      ],
    );
  }

  SagaStory? _firstUnlocked(List<SagaStory> stories) {
    for (final story in stories) {
      if (story.unlocked) return story;
    }
    return null;
  }

  void _openEnding(BuildContext context, String storyId) {
    final open = widget.onEndingOpen;
    if (open != null) {
      open(storyId);
      return;
    }
    try {
      AppNavigation.read(context)
          .go(AppRoutes.graphPath(Uri.encodeComponent(storyId)));
    } on FlutterError {
      // Widget tests mount ProfileView without the router.
    }
  }

  /// Opens a creation in the canvas editor through the `/create/:id`
  /// deep link. Test seam first, like endings and sagas.
  void _openDraft(BuildContext context, String storyId) {
    final open = widget.onDraftOpen;
    if (open != null) {
      open(storyId);
      return;
    }
    try {
      AppNavigation.read(context)
          .go(AppRoutes.createFor(Uri.encodeComponent(storyId)));
    } on FlutterError {
      // Widget tests mount ProfileView without the router.
    }
  }

  void _openSaga(BuildContext context, String storyId) {
    final open = widget.onSagaOpen;
    if (open != null) {
      open(storyId);
      return;
    }
    try {
      AppNavigation.read(context)
          .go(AppRoutes.storyPath(Uri.encodeComponent(storyId)));
    } on FlutterError {
      // Widget tests mount ProfileView without the router.
    }
  }

  void _reload(BuildContext context) {
    context.read<ProfileBloc>().add(
      ProfileRequested(authorId: widget.authorId),
    );
  }

  void _save(
    BuildContext context, {
    required String displayName,
    required String handle,
    required String photoUrl,
    required String locale,
  }) {
    String? clean(String value) => value.isEmpty ? null : value;
    _saveInFlight = true;
    context.read<ProfileBloc>().add(
      ProfileSaved(
        displayName: clean(displayName),
        handle: clean(handle),
        photoUrl: clean(photoUrl),
        locale: clean(locale),
      ),
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
        Text('Profile', style: RamificaText.screenTitle),
        SizedBox(height: 16),
        EmptyState(message: 'Profile is unavailable right now.'),
      ],
    );
  }
}

/// Key metrics row in the Stitch style: three cells bound to real data only.
/// Sagas and endings come from the owner's props; following is the viewer's
/// own follow-set size (null on foreign profiles renders an em dash).
/// Viewer and rating counts have no readable source, so they stay out.
class _MetricsRow extends StatelessWidget {
  const _MetricsRow({
    required this.sagas,
    required this.endings,
    required this.following,
  });

  final int sagas;
  final int endings;
  final int? following;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const .all(12),
      decoration: BoxDecoration(
        color: RamificaColors.containerLow,
        borderRadius: .circular(16),
        border: .all(color: RamificaColors.glassBorder),
      ),
      child: Row(
        children: [
          _Metric(
            icon: Icons.video_library_outlined,
            color: RamificaColors.hotspot,
            value: '$sagas',
            label: 'Sagas',
          ),
          _Metric(
            icon: Icons.alt_route,
            color: RamificaColors.nodeActive,
            value: '$endings',
            label: 'Endings',
          ),
          _Metric(
            icon: Icons.group_outlined,
            color: RamificaColors.rewardGold,
            value: following?.toString() ?? '—',
            label: 'Following',
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: .min,
        children: [
          Row(
            mainAxisSize: .min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 4),
              Text(value, style: RamificaText.headlineSM),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            style: RamificaText.caption,
            maxLines: 1,
            overflow: .ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Content tab switcher in the Stitch segmented style. Pure local view
/// state: selection arrives via [onSelect], no timers, no animation
/// controllers, so every frame settles.
class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tab,
    required this.sagas,
    required this.onSelect,
  });

  final int tab;
  final int sagas;
  final void Function(int index) onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const .all(4),
      decoration: BoxDecoration(
        color: RamificaColors.containerBase,
        borderRadius: .circular(12),
      ),
      child: Row(
        children: [
          _TabButton(
            icon: Icons.video_library_outlined,
            label: 'Sagas ($sagas)',
            selected: tab == 0,
            onTap: () => onSelect(0),
          ),
          _TabButton(
            icon: Icons.emoji_events_outlined,
            label: 'Endings',
            selected: tab == 1,
            onTap: () => onSelect(1),
          ),
          _TabButton(
            icon: Icons.hub_outlined,
            label: 'Creations',
            selected: tab == 2,
            onTap: () => onSelect(2),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          color: selected ? RamificaColors.containerHigh : null,
          borderRadius: .circular(8),
        ),
        child: InkWell(
          borderRadius: .circular(8),
          onTap: onTap,
          child: Padding(
            padding: const .symmetric(vertical: 10, horizontal: 4),
            child: Row(
              mainAxisAlignment: .center,
              mainAxisSize: .min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: selected
                      ? RamificaColors.hotspot
                      : RamificaColors.textSecondary,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    style: RamificaText.labelSM.copyWith(
                      color: selected
                          ? RamificaColors.textPrimary
                          : RamificaColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: .ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Featured-saga hero adapted from the Stitch cinematic banner: shows the
/// first unlocked saga only (cover, title, author) with a single
/// `Play from Start` CTA. Episode, progress, branch-count, and save chips
/// have no readable source, so they stay out.
class _FeaturedSaga extends StatelessWidget {
  const _FeaturedSaga({
    required this.story,
    required this.total,
    required this.onOpen,
  });

  final SagaStory story;
  final int total;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final title = story.title ?? story.storyId;
    final author = (story.authorName ?? '').trim();
    final cover = (story.coverUrl ?? '').trim();
    return Container(
      decoration: BoxDecoration(
        color: RamificaColors.containerLow,
        borderRadius: .circular(16),
        border: .all(color: RamificaColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          ClipRRect(
            borderRadius: const .only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
            ),
            child: SizedBox(
              height: 144,
              child: cover.isEmpty
                  ? Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            RamificaColors.containerHigh,
                            RamificaColors.containerLowest,
                          ],
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.movie_outlined,
                          size: 44,
                          color: RamificaColors.glassBorder,
                        ),
                      ),
                    )
                  : Image.network(
                      cover,
                      fit: .cover,
                      semanticLabel: 'Cover of $title',
                      errorBuilder: (_, _, _) =>
                          const ColoredBox(color: RamificaColors.nodeLocked),
                    ),
            ),
          ),
          Padding(
            padding: const .all(12),
            child: Column(
              crossAxisAlignment: .stretch,
              mainAxisSize: .min,
              children: [
                Row(
                  mainAxisAlignment: .spaceBetween,
                  children: [
                    const Text('Featured Saga', style: RamificaText.labelSM),
                    Text(
                      '$total sagas',
                      style: RamificaText.meta.copyWith(
                        color: RamificaColors.hotspot,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  style: RamificaText.headlineSM,
                  maxLines: 2,
                  overflow: .ellipsis,
                ),
                if (author.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    author,
                    style: RamificaText.meta,
                    maxLines: 1,
                    overflow: .ellipsis,
                  ),
                ],
                const SizedBox(height: 12),
                Material(
                  color: Colors.transparent,
                  borderRadius: .circular(12),
                  child: Ink(
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: .circular(12),
                      gradient: const LinearGradient(
                        colors: [
                          RamificaColors.hotspot,
                          RamificaColors.nodeActive,
                        ],
                      ),
                    ),
                    child: InkWell(
                      borderRadius: .circular(12),
                      onTap: onOpen,
                      child: Row(
                        mainAxisAlignment: .center,
                        children: [
                          const Icon(
                            Icons.play_arrow,
                            color: RamificaColors.onSecondary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Play from Start',
                            style: RamificaText.label.copyWith(
                              color: RamificaColors.onSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Creations tab: the signed-in user's own stories, newest first. Tapping
/// one opens it on the canvas editor; empty means no drafts yet (foreign
/// profiles never reach this widget with data).
class _CreationsCard extends StatelessWidget {
  const _CreationsCard({required this.drafts, required this.onOpen});

  final List<DraftStory> drafts;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const .all(16),
      decoration: BoxDecoration(
        color: RamificaColors.containerLow,
        borderRadius: .circular(16),
        border: .all(color: RamificaColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.video_library_outlined,
                color: RamificaColors.hotspot,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'My creations (${drafts.length})',
                  style: RamificaText.headlineSM,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Drafts open in the editor. Published stories keep playing in Explore.',
            style: RamificaText.bodySM.copyWith(
              color: RamificaColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          if (drafts.isEmpty)
            const Text(
              'No creations yet. Start one from the Create tab.',
              style: RamificaText.meta,
            )
          else
            for (var i = 0; i < drafts.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _CreationRow(
                draft: drafts[i],
                onOpen: () => onOpen(drafts[i].storyId),
              ),
            ],
        ],
      ),
    );
  }
}

/// One creation row: title plus its Draft/Published state.
class _CreationRow extends StatelessWidget {
  const _CreationRow({required this.draft, required this.onOpen});

  final DraftStory draft;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final title = draft.title.trim().isEmpty ? 'Untitled' : draft.title;
    return Material(
      color: RamificaColors.containerLowest,
      borderRadius: .circular(12),
      child: InkWell(
        key: ValueKey('open-draft-${draft.storyId}'),
        borderRadius: .circular(12),
        onTap: onOpen,
        child: Padding(
          padding: const .all(12),
          child: Row(
            children: [
              Expanded(child: Text(title, style: RamificaText.labelSM)),
              Text(
                draft.status == 'published' ? 'Published' : 'Draft',
                style: RamificaText.meta,
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: RamificaColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
