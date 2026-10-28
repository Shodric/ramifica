import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/auth_exception.dart';
import 'package:ramifica/data/models/user.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/follow_repository.dart';
import 'package:ramifica/features/profile/profile_bloc.dart';
import 'package:ramifica/features/profile/profile_event.dart';
import 'package:ramifica/features/profile/profile_state.dart';

void main() {
  group('ProfileBloc', () {
    test('loads the own profile with names and follow count', () async {
      final users = _Users()
        ..accounts['u_me'] = const UserAccount(
          uid: 'u_me',
          displayName: 'Me',
          handle: 'me',
          locale: 'es-AR',
        );
      final bloc = _profile(users: users, follows: _follows({'a', 'b'}));
      addTearDown(bloc.close);

      bloc.add(const ProfileRequested());
      await bloc.stream.firstWhere(
        (state) => state.phase == ProfilePhase.loaded,
      );

      expect(bloc.state.isOwn, isTrue);
      expect(bloc.state.authorId, 'u_me');
      expect(bloc.state.displayName, 'Me');
      expect(bloc.state.handle, 'me');
      expect(bloc.state.isFollowing, isFalse);
      expect(bloc.state.followingCount, 2);
      expect(bloc.state.failure, isNull);
    });

    test('loads a foreign profile with follow state', () async {
      final users = _Users()
        ..accounts['u_author'] = const UserAccount(
          uid: 'u_author',
          displayName: 'Author',
          handle: 'author',
        );
      final bloc = _profile(
        users: users,
        follows: _follows({'u_author'}),
      );
      addTearDown(bloc.close);

      bloc.add(const ProfileRequested(authorId: 'u_author'));
      await bloc.stream.firstWhere(
        (state) => state.phase == ProfilePhase.loaded,
      );

      expect(bloc.state.isOwn, isFalse);
      expect(bloc.state.authorId, 'u_author');
      expect(bloc.state.displayName, 'Author');
      expect(bloc.state.isFollowing, isTrue);
      expect(bloc.state.followingCount, isNull);
    });

    test('a denied foreign read still loads a minimal profile', () async {
      final users = _Users()..readError = const AuthException(.failed);
      final bloc = _profile(users: users, follows: _follows({}));
      addTearDown(bloc.close);

      bloc.add(const ProfileRequested(authorId: 'u_author'));
      await bloc.stream.firstWhere(
        (state) => state.phase == ProfilePhase.loaded,
      );

      expect(bloc.state.isOwn, isFalse);
      expect(bloc.state.displayName, isNull);
      expect(bloc.state.isFollowing, isFalse);
    });

    test('toggling on the own profile is a no-op without any call',
        () async {
      final writes = <String>[];
      final removes = <String>[];
      final users = _Users()
        ..accounts['u_me'] = const UserAccount(uid: 'u_me');
      final bloc = _profile(
        users: users,
        follows: _follows({}, writes, removes),
      );
      addTearDown(bloc.close);

      bloc.add(const ProfileRequested());
      await bloc.stream.firstWhere(
        (state) => state.phase == ProfilePhase.loaded,
      );
      bloc.add(const FollowToggled());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(writes, isEmpty);
      expect(removes, isEmpty);
      expect(bloc.state.isFollowing, isFalse);
      expect(bloc.state.toggling, isFalse);
    });

    test('toggling a foreign profile follows and unfollows', () async {
      final writes = <String>[];
      final removes = <String>[];
      final users = _Users()
        ..accounts['u_author'] = const UserAccount(uid: 'u_author');
      final bloc = _profile(
        users: users,
        follows: _follows({}, writes, removes),
      );
      addTearDown(bloc.close);

      bloc.add(const ProfileRequested(authorId: 'u_author'));
      await bloc.stream.firstWhere(
        (state) => state.phase == ProfilePhase.loaded,
      );

      bloc.add(const FollowToggled());
      await bloc.stream.firstWhere(
        (state) => !state.toggling && state.isFollowing,
      );
      expect(writes, ['u_me>u_author']);
      expect(removes, isEmpty);

      bloc.add(const FollowToggled());
      await bloc.stream.firstWhere(
        (state) => !state.toggling && !state.isFollowing,
      );
      expect(removes, ['u_me>u_author']);
    });

    test('saving the own profile writes trimmed fields', () async {
      final users = _Users()
        ..accounts['u_me'] = const UserAccount(uid: 'u_me');
      final bloc = _profile(users: users, follows: _follows({}));
      addTearDown(bloc.close);

      bloc.add(const ProfileRequested());
      await bloc.stream.firstWhere(
        (state) => state.phase == ProfilePhase.loaded,
      );
      bloc.add(const ProfileSaved(displayName: '  Me  ', handle: 'me'));
      await bloc.stream.firstWhere(
        (state) => !state.saving && state.displayName == 'Me',
      );

      expect(users.updates, hasLength(1));
      expect(users.updates.single['displayName'], 'Me');
      expect(users.updates.single['locale'], 'es-AR');
      expect(bloc.state.handle, 'me');
      expect(bloc.state.failure, isNull);
    });

    test('saving a foreign profile is rejected without a write', () async {
      final users = _Users()
        ..accounts['u_author'] = const UserAccount(uid: 'u_author');
      final bloc = _profile(
        users: users,
        follows: _follows({}),
      );
      addTearDown(bloc.close);

      bloc.add(const ProfileRequested(authorId: 'u_author'));
      await bloc.stream.firstWhere(
        (state) => state.phase == ProfilePhase.loaded,
      );
      bloc.add(const ProfileSaved(displayName: 'Hijack'));
      await bloc.stream.firstWhere((state) => state.failure != null);

      expect(users.updates, isEmpty);
      expect(bloc.state.failure, 'Not allowed');
    });

    test('sign out calls the gateway and ends signed out', () async {
      final auth = _Auth();
      final bloc = ProfileBloc(
        auth: AuthRepository(auth: auth, users: _Users()),
        users: _Users(),
        follows: _follows({}),
      );
      addTearDown(bloc.close);

      bloc.add(const SignOutRequested());
      await bloc.stream.firstWhere(
        (state) => state.phase == ProfilePhase.signedOut,
      );

      expect(auth.signOutCalls, 1);
    });
  });
}

ProfileBloc _profile({
  required _Users users,
  required FollowRepository follows,
}) {
  return ProfileBloc(
    auth: AuthRepository(auth: _Auth(), users: users),
    users: users,
    follows: follows,
  );
}

FollowRepository _follows(
  Set<String> ids, [
  List<String>? writes,
  List<String>? removes,
]) {
  return FollowRepository(
    fetchAuthorIds: (_) async => ids,
    writeFollow: (uid, authorId) async {
      writes?.add('$uid>$authorId');
    },
    removeFollow: (uid, authorId) async {
      removes?.add('$uid>$authorId');
    },
  );
}

class _Auth implements AuthGateway {
  var signOutCalls = 0;

  @override
  Stream<AuthIdentity?> authStateChanges() => const Stream.empty();

  @override
  AuthIdentity? get currentIdentity =>
      const AuthIdentity(uid: 'u_me', providers: ['google']);

  @override
  Future<void> signInWithGooglePopup() async {}

  @override
  Future<void> signInWithGoogleRedirect() async {}

  @override
  Future<void> completeGoogleRedirect() async {}

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signUpWithEmail({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Future<void> signOut() async {
    signOutCalls++;
  }
}

class _Users implements UserDirectory {
  final accounts = <String, UserAccount>{};
  final updates = <Map<String, Object?>>[];
  AuthException? readError;

  @override
  Future<bool> exists(String uid) async => accounts.containsKey(uid);

  @override
  Future<void> create(UserAccount user) async {
    accounts[user.uid] = user;
  }

  @override
  Future<UserAccount?> read(String uid) async {
    final error = readError;
    if (error != null) throw error;
    return accounts[uid];
  }

  @override
  Future<void> updateProfile({
    required String uid,
    String? displayName,
    String? handle,
    String? photoUrl,
    required String locale,
  }) async {
    updates.add({
      'displayName': displayName,
      'handle': handle,
      'photoUrl': photoUrl,
      'locale': locale,
    });
    final current = accounts[uid];
    if (current != null) {
      accounts[uid] = UserAccount(
        uid: uid,
        displayName: displayName,
        handle: handle,
        photoUrl: photoUrl,
        locale: locale,
        providers: current.providers,
      );
    }
  }
}
