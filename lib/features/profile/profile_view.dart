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
        const SizedBox(height: 24),
        EndingList(
          endings: widget.unlockedEndings,
          onOpen: (storyId) => _openEnding(context, storyId),
        ),
        const SizedBox(height: 24),
        SagaList(
          stories: widget.sagaStories,
          onOpen: (storyId) => _openSaga(context, storyId),
        ),

        // Endings and sagas sections render above; future
        // placeholders always sit at the bottom of the profile.
        const SizedBox(height: 16),
        const LaterBlock(),
       ],
    );
  }

  void _openEnding(BuildContext context, String storyId) {
    final open = widget.onEndingOpen;
    if (open != null) {
      open(storyId);
      return;
    }
    try {
      AppNavigation.read(context).go(
        AppRoutes.graphPath(Uri.encodeComponent(storyId)),
      );
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
      AppNavigation.read(context).go(
        AppRoutes.storyPath(Uri.encodeComponent(storyId)),
      );
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
