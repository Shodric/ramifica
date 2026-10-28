import 'package:ramifica/data/models/user.dart';

enum ProfilePhase { loading, loaded, failed, signedOut }

/// What the profile view shows.
///
/// [uid] is the signed-in user, [authorId] the viewed profile. They match
/// exactly when [isOwn]. Foreign `users/{uid}` docs are owner-readable
/// only under firestore.rules, so a foreign profile often loads minimal
/// (ids plus [isFollowing]) with null names; that is still [ProfilePhase]
/// `.loaded`, not a failure.
///
/// Counts stay where they are cheap: [followingCount] is the size of the
/// viewer's own follow set (one subcollection read the bloc already
/// makes), so it is only set on the own profile. Follower and story counts
/// have no cheap readable source under the rules (follows are
/// owner-readable, stories need a query per author) and are omitted until
/// a backend counter exists.
class ProfileState {
  const ProfileState({
    this.phase = ProfilePhase.loading,
    this.uid = '',
    this.authorId = '',
    this.displayName,
    this.handle,
    this.photoUrl,
    this.locale = defaultUserLocale,
    this.isOwn = true,
    this.isFollowing = false,
    this.followingCount,
    this.toggling = false,
    this.saving = false,
    this.failure,
  });

  final ProfilePhase phase;
  final String uid;
  final String authorId;
  final String? displayName;
  final String? handle;
  final String? photoUrl;
  final String locale;
  final bool isOwn;
  final bool isFollowing;
  final int? followingCount;
  final bool toggling;
  final bool saving;
  final String? failure;

  ProfileState copy({
    ProfilePhase Function()? phase,
    String? uid,
    String? authorId,
    String? Function()? displayName,
    String? Function()? handle,
    String? Function()? photoUrl,
    String? locale,
    bool? isOwn,
    bool? isFollowing,
    int? Function()? followingCount,
    bool? toggling,
    bool? saving,
    String? Function()? failure,
  }) {
    return ProfileState(
      phase: phase == null ? this.phase : phase(),
      uid: uid ?? this.uid,
      authorId: authorId ?? this.authorId,
      displayName: displayName == null ? this.displayName : displayName(),
      handle: handle == null ? this.handle : handle(),
      photoUrl: photoUrl == null ? this.photoUrl : photoUrl(),
      locale: locale ?? this.locale,
      isOwn: isOwn ?? this.isOwn,
      isFollowing: isFollowing ?? this.isFollowing,
      followingCount: followingCount == null
          ? this.followingCount
          : followingCount(),
      toggling: toggling ?? this.toggling,
      saving: saving ?? this.saving,
      failure: failure == null ? this.failure : failure(),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ProfileState &&
        other.phase == phase &&
        other.uid == uid &&
        other.authorId == authorId &&
        other.displayName == displayName &&
        other.handle == handle &&
        other.photoUrl == photoUrl &&
        other.locale == locale &&
        other.isOwn == isOwn &&
        other.isFollowing == isFollowing &&
        other.followingCount == followingCount &&
        other.toggling == toggling &&
        other.saving == saving &&
        other.failure == failure;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    uid,
    authorId,
    displayName,
    handle,
    photoUrl,
    locale,
    isOwn,
    isFollowing,
    followingCount,
    toggling,
    saving,
    failure,
  );
}
