enum AuthPhase { signedOut, signingIn, signedIn }

const passwordResetNotice = 'If that email has an account, we sent a link.';

class AuthState {
  const AuthState({
    this.phase = AuthPhase.signedOut,
    this.pendingStoryId,
    this.failure,
    this.notice,
    this.email,
    this.emailVerified = false,
    this.sessionReady = false,
  });

  final AuthPhase phase;
  final String? pendingStoryId;
  final String? failure;
  final String? notice;

  /// From the ID token. Null after sign-out. Not stored as a role.
  final String? email;
  final bool emailVerified;

  /// True after the first auth-state event, including a signed-out one.
  /// Cold start stays false so `/create` is not bounced before restore.
  final bool sessionReady;

  AuthState copyWith({
    AuthPhase? phase,
    String? pendingStoryId,
    String? failure,
    String? notice,
    String? email,
    bool? emailVerified,
    bool? sessionReady,
    bool clearPendingStoryId = false,
    bool clearFailure = false,
    bool clearNotice = false,
    bool clearEmail = false,
  }) {
    return AuthState(
      phase: phase ?? this.phase,
      pendingStoryId: clearPendingStoryId
          ? null
          : pendingStoryId ?? this.pendingStoryId,
      failure: clearFailure ? null : failure ?? this.failure,
      notice: clearNotice ? null : notice ?? this.notice,
      email: clearEmail ? null : email ?? this.email,
      emailVerified: emailVerified ?? this.emailVerified,
      sessionReady: sessionReady ?? this.sessionReady,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AuthState &&
        other.phase == phase &&
        other.pendingStoryId == pendingStoryId &&
        other.failure == failure &&
        other.notice == notice &&
        other.email == email &&
        other.emailVerified == emailVerified &&
        other.sessionReady == sessionReady;
  }

  @override
  int get hashCode => Object.hash(
    phase,
    pendingStoryId,
    failure,
    notice,
    email,
    emailVerified,
    sessionReady,
  );
}
