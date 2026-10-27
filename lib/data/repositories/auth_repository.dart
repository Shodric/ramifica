import 'package:ramifica/data/models/auth_exception.dart';
import 'package:ramifica/data/models/user.dart';

class AuthIdentity {
  const AuthIdentity({
    required this.uid,
    this.displayName,
    this.photoUrl,
    this.providers = const [],
  });

  final String uid;
  final String? displayName;
  final String? photoUrl;
  final List<String> providers;
}

abstract class AuthGateway {
  Stream<AuthIdentity?> authStateChanges();

  AuthIdentity? get currentIdentity;

  Future<void> signInWithGooglePopup();

  Future<void> signInWithGoogleRedirect();

  Future<void> completeGoogleRedirect();

  Future<void> signInWithEmail({
    required String email,
    required String password,
  });

  Future<void> signUpWithEmail({
    required String email,
    required String password,
  });

  Future<void> sendPasswordReset(String email);

  Future<void> signOut();
}

abstract class UserDirectory {
  Future<bool> exists(String uid);

  Future<void> create(UserAccount user);
}

/// Installed iOS PWAs cannot rely on a Google popup.
bool googleRedirectOnIosPwa({
  required String userAgent,
  required bool standalone,
}) {
  final ios =
      userAgent.contains('iPhone') ||
      userAgent.contains('iPad') ||
      userAgent.contains('iPod');
  return ios && standalone;
}

class AuthRepository {
  AuthRepository({
    required this.auth,
    required this.users,
    this.preferGoogleRedirect = false,
  });

  final AuthGateway auth;
  final UserDirectory users;
  final bool preferGoogleRedirect;

  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  Stream<AuthIdentity?> authStateChanges() => auth.authStateChanges();

  Future<void> signInWithGoogle() async {
    if (preferGoogleRedirect) {
      await auth.signInWithGoogleRedirect();
      return;
    }
    try {
      await auth.signInWithGooglePopup();
    } on AuthException catch (error) {
      if (error.code != .popupBlocked) rethrow;
      await auth.signInWithGoogleRedirect();
    }
  }

  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final trimmed = _requireEmail(email);
    if (password.isEmpty) {
      throw const AuthException(.invalidCredential);
    }
    await auth.signInWithEmail(email: trimmed, password: password);
  }

  Future<void> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    final trimmed = _requireEmail(email);
    if (password.length < 8) {
      throw const AuthException(.weakPassword);
    }
    await auth.signUpWithEmail(email: trimmed, password: password);
  }

  Future<void> sendPasswordReset(String email) async {
    final trimmed = _requireEmail(email);
    try {
      await auth.sendPasswordReset(trimmed);
    } on AuthException catch (error) {
      if (error.code != .invalidCredential) rethrow;
    }
  }

  Future<void> signOut() => auth.signOut();

  Future<void> completeRedirect() => auth.completeGoogleRedirect();

  Future<UserAccount> ensureUser() async {
    final identity = auth.currentIdentity;
    if (identity == null) {
      throw const AuthException(.failed);
    }
    final account = UserAccount(
      uid: identity.uid,
      displayName: identity.displayName,
      photoUrl: identity.photoUrl,
      providers: identity.providers,
    );
    if (await users.exists(account.uid)) return account;
    try {
      await users.create(account);
    } on AuthException {
      if (!await users.exists(account.uid)) rethrow;
    }
    return account;
  }

  String _requireEmail(String email) {
    final trimmed = email.trim();
    if (!_email.hasMatch(trimmed)) {
      throw const AuthException(.invalidEmail);
    }
    return trimmed;
  }
}
