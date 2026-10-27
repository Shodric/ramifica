enum AuthErrorCode {
  invalidCredential,
  invalidEmail,
  weakPassword,
  popupClosed,
  popupBlocked,
  network,
  failed,
}

class AuthException implements Exception {
  const AuthException(this.code, {this.cause});

  final AuthErrorCode code;
  final Object? cause;

  String get phrase {
    return switch (code) {
      .invalidCredential => 'Email or password is wrong',
      .invalidEmail => 'That email is not valid',
      .weakPassword => 'Use at least 8 characters',
      .popupClosed => 'The sign-in window was closed',
      .popupBlocked => 'The sign-in window was blocked',
      .network => 'No connection',
      .failed => 'Something failed',
    };
  }

  @override
  String toString() => 'AuthException(${code.name})';
}

AuthErrorCode authErrorCodeFor(String code) {
  return switch (code) {
    'invalid-credential' ||
    'wrong-password' ||
    'user-not-found' ||
    'email-already-in-use' ||
    'invalid-login-credentials' => .invalidCredential,
    'invalid-email' => .invalidEmail,
    'weak-password' => .weakPassword,
    'popup-closed-by-user' || 'cancelled-popup-request' => .popupClosed,
    'popup-blocked' || 'operation-not-supported' => .popupBlocked,
    'network-request-failed' ||
    'unavailable' ||
    'deadline-exceeded' => .network,
    _ => .failed,
  };
}
