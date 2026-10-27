import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/app.dart';
import 'package:ramifica/data/models/auth_exception.dart';
import 'package:ramifica/data/models/user.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/pending_story_store.dart';
import 'package:ramifica/features/access/access_bloc.dart';
import 'package:ramifica/features/access/access_event.dart';
import 'package:ramifica/features/access/access_state.dart';

void main() {
  test('auth codes keep enumeration answers identical', () {
    expect(
      authErrorCodeFor('invalid-credential'),
      AuthErrorCode.invalidCredential,
    );
    expect(
      authErrorCodeFor('email-already-in-use'),
      AuthErrorCode.invalidCredential,
    );
    expect(authErrorCodeFor('user-not-found'), AuthErrorCode.invalidCredential);
    expect(authErrorCodeFor('popup-blocked'), AuthErrorCode.popupBlocked);
    expect(authErrorCodeFor('network-request-failed'), AuthErrorCode.network);
    expect(
      const AuthException(.invalidCredential).phrase,
      'Email or password is wrong',
    );
  });

  test('a new user document omits handle and null fields', () {
    final fields = const UserAccount(
      uid: 'uid_1',
      displayName: 'Alex',
      providers: ['google.com'],
    ).toCreateMap(createdAt: 'stamp');

    expect(fields.keys, ['displayName', 'providers', 'locale', 'createdAt']);
    expect(fields['locale'], defaultUserLocale);
    expect(fields.containsKey('handle'), isFalse);
    expect(fields.containsKey('photoUrl'), isFalse);
  });

  test('an installed iOS PWA uses Google redirect', () {
    expect(
      googleRedirectOnIosPwa(userAgent: 'iPhone', standalone: true),
      isTrue,
    );
    expect(
      googleRedirectOnIosPwa(userAgent: 'iPhone', standalone: false),
      isFalse,
    );
    expect(
      googleRedirectOnIosPwa(userAgent: 'Android', standalone: true),
      isFalse,
    );
  });

  test('a blocked Google popup falls back to redirect', () async {
    final auth = _FakeAuth()
      ..onPopup = () async {
        throw const AuthException(.popupBlocked);
      };
    final repository = _repository(auth);

    await repository.signInWithGoogle();

    expect(auth.popupCalls, 1);
    expect(auth.redirectCalls, 1);
  });

  test('an iOS PWA does not open the Google popup', () async {
    final auth = _FakeAuth();
    final repository = _repository(auth, preferGoogleRedirect: true);

    await repository.signInWithGoogle();

    expect(auth.popupCalls, 0);
    expect(auth.redirectCalls, 1);
  });

  test('sign up rejects a short password before Auth', () async {
    final auth = _FakeAuth();
    final repository = _repository(auth);

    await expectLater(
      repository.signUpWithEmail(email: 'a@b.co', password: 'short'),
      throwsA(
        isA<AuthException>().having(
          (error) => error.code,
          'code',
          AuthErrorCode.weakPassword,
        ),
      ),
    );
    expect(auth.signUpCalls, 0);
  });

  test('password reset hides a missing account', () async {
    final auth = _FakeAuth()
      ..onReset = () async {
        throw const AuthException(.invalidCredential);
      };
    final repository = _repository(auth);

    await repository.sendPasswordReset('a@b.co');

    expect(auth.resetCalls, 1);
  });

  test('password reset rejects a malformed email', () async {
    final auth = _FakeAuth();
    final repository = _repository(auth);

    await expectLater(
      repository.sendPasswordReset('not-an-email'),
      throwsA(
        isA<AuthException>().having(
          (error) => error.code,
          'code',
          AuthErrorCode.invalidEmail,
        ),
      ),
    );
    expect(auth.resetCalls, 0);
  });

  test('ensureUser creates the doc once', () async {
    final auth = _FakeAuth()
      ..identity = const AuthIdentity(
        uid: 'uid_1',
        displayName: 'Alex',
        providers: ['google.com'],
      );
    final users = _FakeUsers();
    final repository = _repository(auth, users: users);

    final created = await repository.ensureUser();
    final again = await repository.ensureUser();

    expect(created.uid, 'uid_1');
    expect(created.locale, defaultUserLocale);
    expect(again.uid, 'uid_1');
    expect(users.created, ['uid_1']);
  });

  test('a closed popup returns to signed out with a phrase', () async {
    final auth = _FakeAuth()
      ..onPopup = () async {
        throw const AuthException(.popupClosed);
      };
    final bloc = _bloc(_repository(auth));
    addTearDown(bloc.close);

    final states = expectLater(
      bloc.stream,
      emitsInOrder([
        isA<AuthState>().having(
          (state) => state.phase,
          'phase',
          AuthPhase.signingIn,
        ),
        isA<AuthState>()
            .having((state) => state.phase, 'phase', AuthPhase.signedOut)
            .having(
              (state) => state.failure,
              'failure',
              'The sign-in window was closed',
            ),
      ]),
    );
    bloc.add(const SignInWithGoogleRequested());
    await states;
  });

  test('a second Google sign-in is dropped while one is in flight', () async {
    final gate = Completer<void>();
    final auth = _FakeAuth()..onPopup = () => gate.future;
    final bloc = _bloc(_repository(auth));
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await bloc.close();
    });

    bloc.add(const SignInWithGoogleRequested());
    await bloc.stream.firstWhere((state) => state.phase == AuthPhase.signingIn);
    bloc.add(const SignInWithGoogleRequested());
    await Future<void>.delayed(Duration.zero);

    expect(auth.popupCalls, 1);
  });

  test('email sign-in uses the shared wrong-credentials phrase', () async {
    final auth = _FakeAuth()
      ..onEmail = () async {
        throw const AuthException(.invalidCredential);
      };
    final bloc = _bloc(_repository(auth));
    addTearDown(bloc.close);

    bloc.add(
      const SignInWithEmailRequested(email: 'a@b.co', password: 'whatever'),
    );
    final failed = await bloc.stream.firstWhere(
      (state) => state.failure != null,
    );

    expect(failed.phase, AuthPhase.signedOut);
    expect(failed.failure, 'Email or password is wrong');
  });

  test('sign up surfaces a short password without calling Auth', () async {
    final auth = _FakeAuth();
    final bloc = _bloc(_repository(auth));
    addTearDown(bloc.close);

    bloc.add(
      const SignUpWithEmailRequested(email: 'a@b.co', password: 'short'),
    );
    final failed = await bloc.stream.firstWhere(
      (state) => state.failure != null,
    );

    expect(failed.failure, 'Use at least 8 characters');
    expect(auth.signUpCalls, 0);
  });

  test('password reset keeps the phase and shows the notice', () async {
    final auth = _FakeAuth();
    final bloc = _bloc(_repository(auth));
    addTearDown(bloc.close);

    bloc.add(const PasswordResetRequested('a@b.co'));
    final next = await bloc.stream.firstWhere((state) => state.notice != null);

    expect(next.phase, AuthPhase.signedOut);
    expect(next.notice, passwordResetNotice);
    expect(next.failure, isNull);
    expect(auth.resetCalls, 1);
  });

  test(
    'the pending story survives in the store until it is consumed',
    () async {
      final store = MemoryPendingStoryStore();
      final bloc = _bloc(_repository(_FakeAuth()), store: store);
      addTearDown(bloc.close);
      final states = expectLater(
        bloc.stream,
        emitsInOrder([
          isA<AuthState>().having(
            (state) => state.pendingStoryId,
            'pendingStoryId',
            'story_temple',
          ),
          isA<AuthState>().having(
            (state) => state.pendingStoryId,
            'pendingStoryId',
            isNull,
          ),
        ]),
      );

      bloc.add(const PendingStorySaved(' story_temple '));
      bloc.add(const PendingStoryConsumed());
      await states;

      expect(store.read(), isNull);
    },
  );

  test('startup restores the pending story', () async {
    final store = MemoryPendingStoryStore()..write('story_temple');
    final bloc = _bloc(_repository(_FakeAuth()), store: store);
    addTearDown(bloc.close);

    final restored = bloc.stream.first;
    bloc.add(const AuthStarted());

    expect((await restored).pendingStoryId, 'story_temple');
  });

  test('a session creates the user doc and signs in', () async {
    final auth = _FakeAuth();
    final users = _FakeUsers();
    final bloc = _bloc(_repository(auth, users: users));
    addTearDown(bloc.close);

    final signedIn = bloc.stream.firstWhere(
      (state) => state.phase == AuthPhase.signedIn,
    );
    bloc.add(const AuthStarted());
    auth.identity = const AuthIdentity(uid: 'uid_1', providers: ['password']);
    auth.sessions.add(auth.identity);
    await signedIn;

    expect(users.created, ['uid_1']);
    expect(bloc.state.failure, isNull);
  });

  testWidgets('AuthBloc sits above the app', (tester) async {
    final store = MemoryPendingStoryStore()..write('story_temple');
    await tester.pumpWidget(
      RamificaApp(
        authRepository: _repository(_FakeAuth()),
        pendingStoryStore: store,
      ),
    );
    await tester.pump();

    final bloc = tester
        .element(find.text('Continue with Google'))
        .read<AuthBloc>();
    if (bloc.state.pendingStoryId != 'story_temple') {
      await bloc.stream.firstWhere(
        (state) => state.pendingStoryId == 'story_temple',
      );
    }
    expect(bloc.state.pendingStoryId, 'story_temple');
    expect(bloc.state.phase, AuthPhase.signedOut);
  });
}

AuthRepository _repository(
  _FakeAuth auth, {
  _FakeUsers? users,
  bool preferGoogleRedirect = false,
}) {
  return AuthRepository(
    auth: auth,
    users: users ?? _FakeUsers(),
    preferGoogleRedirect: preferGoogleRedirect,
  );
}

AuthBloc _bloc(AuthRepository repository, {PendingStoryStore? store}) {
  return AuthBloc(
    repository: repository,
    pendingStories: store ?? MemoryPendingStoryStore(),
  );
}

class _FakeAuth implements AuthGateway {
  final sessions = StreamController<AuthIdentity?>();
  AuthIdentity? identity;
  var popupCalls = 0;
  var redirectCalls = 0;
  var signUpCalls = 0;
  var resetCalls = 0;
  Future<void> Function()? onPopup;
  Future<void> Function()? onEmail;
  Future<void> Function()? onReset;

  @override
  Stream<AuthIdentity?> authStateChanges() => sessions.stream;

  @override
  AuthIdentity? get currentIdentity => identity;

  @override
  Future<void> signInWithGooglePopup() async {
    popupCalls += 1;
    await onPopup?.call();
  }

  @override
  Future<void> signInWithGoogleRedirect() async {
    redirectCalls += 1;
  }

  @override
  Future<void> completeGoogleRedirect() async {}

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {
    await onEmail?.call();
  }

  @override
  Future<void> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    signUpCalls += 1;
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    resetCalls += 1;
    await onReset?.call();
  }

  @override
  Future<void> signOut() async {}
}

class _FakeUsers implements UserDirectory {
  final created = <String>[];
  var _exists = false;

  @override
  Future<bool> exists(String uid) async => _exists;

  @override
  Future<void> create(UserAccount user) async {
    created.add(user.uid);
    _exists = true;
  }
}
