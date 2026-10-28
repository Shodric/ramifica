import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:ramifica/data/models/app_failure.dart';
import 'package:ramifica/data/models/auth_exception.dart';
import 'package:ramifica/data/models/user.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/follow_repository.dart';
import 'package:ramifica/features/profile/profile_event.dart';
import 'package:ramifica/features/profile/profile_state.dart';

/// Own vs foreign profile plus follow writes and sign out.
///
/// The signed-in uid comes from [auth]'s current identity on every event,
/// so a mid-session account change cannot act on a stale id. Profile reads
/// and saves go through [users] (`users/{uid}`); follow state goes
/// through [follows] (`follows/{uid}/authors/{authorId}`).
class ProfileBloc extends Bloc<ProfileEvent, ProfileState> {
  ProfileBloc({
    required this.auth,
    required this.users,
    required this.follows,
  }) : super(const ProfileState()) {
    on<ProfileRequested>(_onRequested, transformer: restartable());
    on<FollowToggled>(_onToggled);
    on<ProfileSaved>(_onSaved);
    on<SignOutRequested>(_onSignOut);
  }

  final AuthRepository auth;
  final UserDirectory users;
  final FollowRepository follows;

  Future<void> _onRequested(
    ProfileRequested event,
    Emitter<ProfileState> emit,
  ) async {
    final uid = auth.auth.currentIdentity?.uid.trim() ?? '';
    final requested = event.authorId?.trim() ?? '';
    final target = requested.isEmpty ? uid : requested;
    if (uid.isEmpty || target.isEmpty) {
      emit(
        state.copy(
          phase: () => .failed,
          failure: () => const AppFailure(.failed).phrase,
        ),
      );
      return;
    }
    final own = target == uid;
    emit(
      ProfileState(
        phase: .loading,
        uid: uid,
        authorId: target,
        isOwn: own,
      ),
    );
    try {
      if (own) {
        final account = await users.read(target);
        if (emit.isDone) return;
        // Ancillary: a failed count degrades to null, never to a
        // failed load.
        int? count;
        try {
          count = (await follows.followingIds(uid)).length;
        } on AppFailure {
          count = null;
        }
        if (emit.isDone) return;
        emit(
          ProfileState(
            phase: .loaded,
            uid: uid,
            authorId: target,
            displayName: account?.displayName,
            handle: account?.handle,
            photoUrl: account?.photoUrl,
            locale: account?.locale ?? defaultUserLocale,
            isOwn: true,
            followingCount: count,
          ),
        );
      } else {
        final following = await follows.isFollowing(
          uid: uid,
          authorId: target,
        );
        if (emit.isDone) return;
        // Foreign user docs are owner-readable only, so denial is the
        // common case and still a loaded (minimal) profile.
        UserAccount? account;
        try {
          account = await users.read(target);
        } on AuthException {
          account = null;
        }
        if (emit.isDone) return;
        emit(
          ProfileState(
            phase: .loaded,
            uid: uid,
            authorId: target,
            displayName: account?.displayName,
            handle: account?.handle,
            photoUrl: account?.photoUrl,
            locale: account?.locale ?? defaultUserLocale,
            isOwn: false,
            isFollowing: following,
          ),
        );
      }
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(
        state.copy(phase: () => .failed, failure: () => error.phrase),
      );
    } on AuthException catch (error) {
      if (emit.isDone) return;
      emit(
        state.copy(phase: () => .failed, failure: () => error.phrase),
      );
    }
  }

  Future<void> _onToggled(
    FollowToggled event,
    Emitter<ProfileState> emit,
  ) async {
    // Self-follow is a no-op: no call, no state change.
    if (state.phase != .loaded) return;
    if (state.isOwn) return;
    if (state.uid.isEmpty ||
        state.authorId.isEmpty ||
        state.uid == state.authorId) {
      return;
    }
    if (state.toggling) return;
    final wasFollowing = state.isFollowing;
    emit(state.copy(toggling: true, failure: () => null));
    try {
      if (wasFollowing) {
        await follows.unfollow(uid: state.uid, authorId: state.authorId);
      } else {
        await follows.follow(uid: state.uid, authorId: state.authorId);
      }
      if (emit.isDone) return;
      emit(state.copy(toggling: false, isFollowing: !wasFollowing));
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(state.copy(toggling: false, failure: () => error.phrase));
    }
  }

  Future<void> _onSaved(
    ProfileSaved event,
    Emitter<ProfileState> emit,
  ) async {
    // Foreign saves are rejected: no write, just the phrase.
    if (!state.isOwn || state.uid.isEmpty) {
      emit(
        state.copy(failure: () => const AppFailure(.denied).phrase),
      );
      return;
    }
    if (state.saving) return;
    // Omitted or empty values keep the current field; no explicit clear.
    String? clean(String? value, String? fallback) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
      final keep = fallback?.trim();
      return keep == null || keep.isEmpty ? null : keep;
    }
    final locale = event.locale?.trim();
    emit(state.copy(saving: true, failure: () => null));
    try {
      await users.updateProfile(
        uid: state.uid,
        displayName: clean(event.displayName, state.displayName),
        handle: clean(event.handle, state.handle),
        photoUrl: clean(event.photoUrl, state.photoUrl),
        locale: locale == null || locale.isEmpty ? state.locale : locale,
      );
      if (emit.isDone) return;
      emit(
        state.copy(
          saving: false,
          displayName: () => clean(event.displayName, state.displayName),
          handle: () => clean(event.handle, state.handle),
          photoUrl: () => clean(event.photoUrl, state.photoUrl),
          locale: locale == null || locale.isEmpty ? state.locale : locale,
        ),
      );
    } on AuthException catch (error) {
      if (emit.isDone) return;
      emit(state.copy(saving: false, failure: () => error.phrase));
    } on AppFailure catch (error) {
      if (emit.isDone) return;
      emit(state.copy(saving: false, failure: () => error.phrase));
    }
  }

  Future<void> _onSignOut(
    SignOutRequested event,
    Emitter<ProfileState> emit,
  ) async {
    try {
      await auth.signOut();
      if (emit.isDone) return;
      emit(state.copy(phase: () => .signedOut));
    } on AuthException catch (error) {
      if (emit.isDone) return;
      emit(state.copy(failure: () => error.phrase));
    }
  }
}
