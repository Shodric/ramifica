import 'dart:js_interop';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ramifica/data/models/auth_exception.dart';
import 'package:ramifica/data/models/user.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';

class FirebaseAuthGateway implements AuthGateway {
  FirebaseAuthGateway({FirebaseAuth? auth})
    : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  @override
  Stream<AuthIdentity?> authStateChanges() {
    return _auth.authStateChanges().map(_identityOf);
  }

  @override
  AuthIdentity? get currentIdentity => _identityOf(_auth.currentUser);

  @override
  Future<void> signInWithGooglePopup() {
    return _guard(() => _auth.signInWithPopup(GoogleAuthProvider()));
  }

  @override
  Future<void> signInWithGoogleRedirect() {
    return _guard(() => _auth.signInWithRedirect(GoogleAuthProvider()));
  }

  @override
  Future<void> completeGoogleRedirect() {
    return _guard(() => _auth.getRedirectResult());
  }

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) {
    return _guard(
      () => _auth.signInWithEmailAndPassword(email: email, password: password),
    );
  }

  @override
  Future<void> signUpWithEmail({
    required String email,
    required String password,
  }) {
    return _guard(
      () => _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      ),
    );
  }

  @override
  Future<void> sendPasswordReset(String email) {
    return _guard(() => _auth.sendPasswordResetEmail(email: email));
  }

  @override
  Future<void> signOut() => _guard(_auth.signOut);

  AuthIdentity? _identityOf(User? user) {
    if (user == null) return null;
    return AuthIdentity(
      uid: user.uid,
      displayName: user.displayName,
      photoUrl: user.photoURL,
      providers: [
        for (final info in user.providerData)
          if (info.providerId.isNotEmpty) info.providerId,
      ],
    );
  }

  Future<void> _guard(Future<Object?> Function() action) async {
    try {
      await action();
    } on FirebaseAuthException catch (error) {
      throw AuthException(authErrorCodeFor(error.code), cause: error);
    }
  }
}

class FirestoreUserDirectory implements UserDirectory {
  FirestoreUserDirectory({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  @override
  Future<bool> exists(String uid) async {
    try {
      final snapshot = await _firestore.collection('users').doc(uid).get();
      return snapshot.exists;
    } on FirebaseException catch (error) {
      throw AuthException(authErrorCodeFor(error.code), cause: error);
    }
  }

  @override
  Future<void> create(UserAccount user) async {
    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .set(user.toCreateMap(createdAt: FieldValue.serverTimestamp()));
    } on FirebaseException catch (error) {
      throw AuthException(authErrorCodeFor(error.code), cause: error);
    }
  }

  @override
  Future<UserAccount?> read(String uid) async {
    try {
      final snapshot = await _firestore.collection('users').doc(uid).get();
      if (!snapshot.exists) return null;
      return UserAccount.fromDoc(uid, snapshot.data() ?? const {});
    } on FirebaseException catch (error) {
      throw AuthException(authErrorCodeFor(error.code), cause: error);
    }
  }

  @override
  Future<void> updateProfile({
    required String uid,
    String? displayName,
    String? handle,
    String? photoUrl,
    required String locale,
  }) async {
    final account = UserAccount(
      uid: uid,
      displayName: displayName,
      handle: handle,
      photoUrl: photoUrl,
      locale: locale,
    );
    try {
      await _firestore
          .collection('users')
          .doc(uid)
          .update(account.toUpdateMap());
    } on FirebaseException catch (error) {
      throw AuthException(authErrorCodeFor(error.code), cause: error);
    }
  }
}

Future<void> configureFirebaseAuth() {
  return FirebaseAuth.instance.setPersistence(.LOCAL);
}

AuthRepository createFirebaseAuthRepository() {
  return AuthRepository(
    auth: FirebaseAuthGateway(),
    users: FirestoreUserDirectory(),
    preferGoogleRedirect: _currentPagePrefersGoogleRedirect(),
  );
}

@JS('navigator.userAgent')
external String get _navigatorUserAgent;

@JS('navigator.standalone')
external JSBoolean? get _navigatorStandalone;

@JS('window.matchMedia')
external _MediaQueryList _matchMedia(String query);

extension type _MediaQueryList._(JSObject _) implements JSObject {
  external bool get matches;
}

bool _currentPagePrefersGoogleRedirect() {
  final displayMode = _matchMedia('(display-mode: standalone)').matches;
  final iosStandalone = _navigatorStandalone?.toDart ?? false;
  return googleRedirectOnIosPwa(
    userAgent: _navigatorUserAgent,
    standalone: displayMode || iosStandalone,
  );
}
