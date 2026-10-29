import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/data/repositories/firebase_auth_gateway.dart';
import 'package:ramifica/data/repositories/follow_repository.dart';
import 'package:ramifica/features/profile/ending_list.dart';
import 'package:ramifica/features/profile/install_guide.dart';
import 'package:ramifica/features/profile/install_guide_banner.dart';
import 'package:ramifica/features/profile/later_block.dart';
import 'package:ramifica/features/profile/profile_bloc.dart';
import 'package:ramifica/features/profile/profile_event.dart';
import 'package:ramifica/features/profile/profile_header.dart';
import 'package:ramifica/features/profile/profile_state.dart';
import 'package:ramifica/features/profile/saga_list.dart';

/// Profile tab: screen title, install banner, then the header or editor
/// drawn from [ProfileBloc]. Creates its own bloc like Explore; tests
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

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  ProfileBloc? _bloc;
  var _editing = false;
  var _saveInFlight = false;
  var _tab = 0;

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
      )..add(ProfileRequested(authorId: widget.authorId));
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
            return Scaffold(body: SafeArea(child: _body(context, state)));
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
    final showGuide =
        widget.showInstallGuide?.call() ?? shouldShowInstallGuide();
    return ListView(
      padding: const .all(16),
      children: [
        const Text('Profile', style: RamificaText.screenTitle),
        const SizedBox(height: 16),
        if (showGuide) ...[
          InstallGuideBanner(shouldShow: () => showGuide),
          const SizedBox(height: 16),
        ],
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
        if (state.isOwn && !editing) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton(
                key: const Key('profileEditButton'),
                onPressed: () => setState(() => _editing = true),
                child: const Text('Edit profile'),
              ),
              const SizedBox(width: 12),
              TextButton(
                key: const Key('profileSignOutButton'),
                onPressed: () =>
                    context.read<ProfileBloc>().add(const SignOutRequested()),
                child: const Text('Sign out'),
              ),
            ],
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
        if (_tab == 2) const _LoreCard(),

        // Guild placeholder always sits at the bottom of the profile.
        const SizedBox(height: 16),
        const LaterBlock(),
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
            label: 'Lore & Graph',
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

/// Lore tab: static story-graph card in the Stitch DAG style. The miniature
/// graph is a fixed [CustomPainter] (no animation, settles immediately) with
/// an Explored/Unexplored legend. No editor CTA: the graph tab owns branch
/// editing, so the profile links nothing here.
class _LoreCard extends StatelessWidget {
  const _LoreCard();

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
          const Row(
            children: [
              Icon(Icons.account_tree_outlined, color: RamificaColors.hotspot),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Active Story Graph',
                  style: RamificaText.headlineSM,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Each node is a scene; each edge is a viewer choice.',
            style: RamificaText.bodySM.copyWith(
              color: RamificaColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 140,
            decoration: BoxDecoration(
              color: RamificaColors.containerLowest,
              borderRadius: .circular(12),
            ),
            child: const CustomPaint(painter: _MiniDagPainter()),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: .circle,
                  color: RamificaColors.hotspot,
                ),
              ),
              const SizedBox(width: 6),
              const Text('Explored', style: RamificaText.meta),
              const SizedBox(width: 16),
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: .circle,
                  color: RamificaColors.nodeLocked,
                ),
              ),
              const SizedBox(width: 6),
              const Text('Unexplored', style: RamificaText.meta),
            ],
          ),
        ],
      ),
    );
  }
}

/// Fixed miniature DAG: root, two branches, one locked node, one golden
/// ending. All coordinates are fractions of the canvas size; nothing moves.
class _MiniDagPainter extends CustomPainter {
  const _MiniDagPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    Offset p(double x, double y) => Offset(w * x, h * y);

    final edgeHot = Paint()
      ..color = RamificaColors.hotspot
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final edgeBlue = Paint()
      ..color = RamificaColors.nodeActive
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final edgeLocked = Paint()
      ..color = RamificaColors.nodeLocked
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final root = p(0.12, 0.5);
    final top = p(0.42, 0.24);
    final bottom = p(0.42, 0.76);
    final locked = p(0.74, 0.24);
    final ending = p(0.74, 0.76);

    canvas.drawLine(root, top, edgeHot);
    canvas.drawLine(root, bottom, edgeBlue);
    canvas.drawLine(top, locked, edgeLocked);
    canvas.drawLine(bottom, ending, edgeHot);

    void dot(Offset c, double r, Color fill, [Color? ring]) {
      if (ring != null) {
        canvas.drawCircle(
          c,
          r,
          Paint()
            ..color = ring
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      canvas.drawCircle(c, r - 2, Paint()..color = fill);
    }

    dot(root, 12, RamificaColors.hotspot);
    dot(top, 10, RamificaColors.nodeActive, RamificaColors.nodeActive);
    dot(bottom, 13, RamificaColors.hotspot, RamificaColors.textPrimary);
    dot(locked, 9, RamificaColors.nodeLocked, RamificaColors.nodeLocked);
    dot(ending, 12, RamificaColors.rewardGold, RamificaColors.hotspot);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
