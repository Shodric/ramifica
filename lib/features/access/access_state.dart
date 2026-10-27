enum AuthPhase { signedOut, signingIn, signedIn }

const passwordResetNotice = 'If that email has an account, we sent a link.';

class AuthState {
  const AuthState({
    this.phase = AuthPhase.signedOut,
    this.pendingStoryId,
    this.failure,
    this.notice,
  });

  final AuthPhase phase;
  final String? pendingStoryId;
  final String? failure;
  final String? notice;

  AuthState copyWith({
    AuthPhase? phase,
    String? pendingStoryId,
    String? failure,
    String? notice,
    bool clearPendingStoryId = false,
    bool clearFailure = false,
    bool clearNotice = false,
  }) {
    return AuthState(
      phase: phase ?? this.phase,
      pendingStoryId: clearPendingStoryId
          ? null
          : pendingStoryId ?? this.pendingStoryId,
      failure: clearFailure ? null : failure ?? this.failure,
      notice: clearNotice ? null : notice ?? this.notice,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AuthState &&
        other.phase == phase &&
        other.pendingStoryId == pendingStoryId &&
        other.failure == failure &&
        other.notice == notice;
  }

  @override
  int get hashCode => Object.hash(phase, pendingStoryId, failure, notice);
}
