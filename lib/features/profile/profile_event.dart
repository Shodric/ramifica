/// Events for [ProfileBloc].
///
/// Loading is explicit: [ProfileRequested] carries the viewed author, or
/// nothing for the signed-in user's own profile. [FollowToggled] and
/// [ProfileSaved] act on the loaded profile; [SignOutRequested] signs out
/// and the shell returns to access.
sealed class ProfileEvent {
  const ProfileEvent();
}

/// Loads the profile to show. A blank or missing [authorId] loads the
/// signed-in user's own profile; any other id loads that foreign author.
/// Restartable: requesting again refetches.
final class ProfileRequested extends ProfileEvent {
  const ProfileRequested({this.authorId});

  final String? authorId;
}

/// Flips the follow on the loaded foreign profile. Ignored unless a
/// foreign profile is loaded; self-follow is a no-op (no call, no state
/// change) and is guarded here, not in the repository.
final class FollowToggled extends ProfileEvent {
  const FollowToggled();
}

/// Saves the editable fields of the loaded own profile. Rejected when the
/// loaded profile is foreign (the bloc reports `Not allowed` and writes
/// nothing). Omitted or empty values keep the current field; there is no
/// explicit clear.
final class ProfileSaved extends ProfileEvent {
  const ProfileSaved({
    this.displayName,
    this.handle,
    this.photoUrl,
    this.locale,
  });

  final String? displayName;
  final String? handle;
  final String? photoUrl;
  final String? locale;
}

/// Signs out. The bloc only ends in [ProfilePhase.signedOut]; the shell
/// owns the return to access.
final class SignOutRequested extends ProfileEvent {
  const SignOutRequested();
}
