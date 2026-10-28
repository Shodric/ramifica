import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/data/models/user.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/follow_repository.dart';
import 'package:ramifica/features/profile/install_guide.dart';
import 'package:ramifica/features/profile/profile_bloc.dart';
import 'package:ramifica/features/profile/profile_event.dart';
import 'package:ramifica/features/profile/profile_state.dart';
import 'package:ramifica/features/profile/profile_view.dart';

const _iosSafari =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 '
    'Safari/604.1';

void main() {
  group('ProfileView', () {
    testWidgets('own profile shows header, count, edit, and sign out', (
      tester,
    ) async {
      final bloc = _stub(
        const ProfileState(
          phase: ProfilePhase.loaded,
          uid: 'u_me',
          authorId: 'u_me',
          displayName: 'Ada',
          handle: 'ada',
          locale: 'es-AR',
          isOwn: true,
          followingCount: 3,
        ),
      );
      addTearDown(bloc.close);

      await _pump(tester, bloc);

      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('@ada'), findsOneWidget);
      expect(find.text('es-AR'), findsOneWidget);
      expect(find.text('3 following'), findsOneWidget);
      expect(find.byKey(const Key('profileEditButton')), findsOneWidget);
      expect(find.byKey(const Key('profileSignOutButton')), findsOneWidget);
      expect(find.byKey(const Key('profileFollowButton')), findsNothing);
      expect(bloc.added, isEmpty);
    });

    testWidgets('foreign profile shows a follow button and no editor', (
      tester,
    ) async {
      final bloc = _stub(
        const ProfileState(
          phase: ProfilePhase.loaded,
          uid: 'u_me',
          authorId: 'u_author',
          displayName: 'Alex Vance',
          handle: 'alex',
          locale: 'en-US',
          isOwn: false,
          isFollowing: false,
        ),
      );
      addTearDown(bloc.close);

      await _pump(tester, bloc);

      expect(find.text('Alex Vance'), findsOneWidget);
      expect(find.text('Follow'), findsOneWidget);
      expect(find.byKey(const Key('profileEditButton')), findsNothing);
      expect(find.byKey(const Key('profileSignOutButton')), findsNothing);
    });

    testWidgets('follow button text follows isFollowing', (tester) async {
      final unfollowed = _stub(
        const ProfileState(
          phase: ProfilePhase.loaded,
          uid: 'u_me',
          authorId: 'u_author',
          displayName: 'Alex Vance',
          handle: 'alex',
          locale: 'en-US',
          isOwn: false,
          isFollowing: false,
        ),
      );
      addTearDown(unfollowed.close);
      await _pump(tester, unfollowed);
      expect(find.text('Follow'), findsOneWidget);

      final followed = _stub(
        const ProfileState(
          phase: ProfilePhase.loaded,
          uid: 'u_me',
          authorId: 'u_author',
          displayName: 'Alex Vance',
          handle: 'alex',
          locale: 'en-US',
          isOwn: false,
          isFollowing: true,
        ),
      );
      addTearDown(followed.close);
      await _pump(tester, followed);
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
    });

    testWidgets('minimal foreign profile falls back to a placeholder', (
      tester,
    ) async {
      final bloc = _stub(
        const ProfileState(
          phase: ProfilePhase.loaded,
          uid: 'u_me',
          authorId: 'u_author',
          locale: 'es-AR',
          isOwn: false,
          isFollowing: false,
        ),
      );
      addTearDown(bloc.close);

      await _pump(tester, bloc);

      expect(find.text('Unknown author'), findsOneWidget);
      expect(find.text('Follow'), findsOneWidget);
    });

    testWidgets('follow tap dispatches FollowToggled', (tester) async {
      final bloc = _stub(
        const ProfileState(
          phase: ProfilePhase.loaded,
          uid: 'u_me',
          authorId: 'u_author',
          displayName: 'Alex Vance',
          handle: 'alex',
          locale: 'en-US',
          isOwn: false,
          isFollowing: false,
        ),
      );
      addTearDown(bloc.close);

      await _pump(tester, bloc);
      await tester.tap(find.byKey(const Key('profileFollowButton')));

      expect(bloc.added, hasLength(1));
      expect(bloc.added.single, isA<FollowToggled>());
    });

    testWidgets('sign out tap dispatches SignOutRequested', (tester) async {
      final bloc = _stub(
        const ProfileState(
          phase: ProfilePhase.loaded,
          uid: 'u_me',
          authorId: 'u_me',
          displayName: 'Ada',
          handle: 'ada',
          locale: 'es-AR',
          isOwn: true,
        ),
      );
      addTearDown(bloc.close);

      await _pump(tester, bloc);
      await tester.tap(find.byKey(const Key('profileSignOutButton')));

      expect(bloc.added, hasLength(1));
      expect(bloc.added.single, isA<SignOutRequested>());
    });

    testWidgets('edit opens the form; save dispatches ProfileSaved', (
      tester,
    ) async {
      final bloc = _stub(
        const ProfileState(
          phase: ProfilePhase.loaded,
          uid: 'u_me',
          authorId: 'u_me',
          displayName: 'Ada',
          handle: 'ada',
          locale: 'es-AR',
          isOwn: true,
        ),
      );
      addTearDown(bloc.close);

      await _pump(tester, bloc);
      await tester.tap(find.byKey(const Key('profileEditButton')));
      await tester.pump();

      expect(_fieldText(tester, 'profileNameField'), 'Ada');
      await tester.enterText(find.byKey(const Key('profileNameField')), 'Bo');
      await tester.tap(find.byKey(const Key('profileSaveButton')));

      expect(bloc.added, hasLength(1));
      final saved = bloc.added.single as ProfileSaved;
      expect(saved.displayName, 'Bo');
      expect(saved.handle, 'ada');
      expect(saved.locale, 'es-AR');
    });

    testWidgets('cancel closes the form without dispatching', (tester) async {
      final bloc = _stub(
        const ProfileState(
          phase: ProfilePhase.loaded,
          uid: 'u_me',
          authorId: 'u_me',
          displayName: 'Ada',
          handle: 'ada',
          locale: 'es-AR',
          isOwn: true,
        ),
      );
      addTearDown(bloc.close);

      await _pump(tester, bloc);
      await tester.tap(find.byKey(const Key('profileEditButton')));
      await tester.pump();
      expect(find.byKey(const Key('profileSaveButton')), findsOneWidget);

      await tester.tap(find.byKey(const Key('profileCancelButton')));
      await tester.pump();

      expect(find.byKey(const Key('profileSaveButton')), findsNothing);
      expect(find.text('Ada'), findsOneWidget);
      expect(bloc.added, isEmpty);
    });

    testWidgets('loading draws a spinner under the title', (tester) async {
      final bloc = _stub(const ProfileState());
      addTearDown(bloc.close);

      await _pump(tester, bloc);

      expect(find.text('Profile'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('failed draws the phrase and retry resends', (tester) async {
      final bloc = _stub(
        const ProfileState(phase: ProfilePhase.failed, failure: 'Offline'),
      );
      addTearDown(bloc.close);

      await _pump(tester, bloc);

      expect(find.text('Offline'), findsOneWidget);
      await tester.tap(find.text('Retry'));

      expect(bloc.added, hasLength(1));
      expect(bloc.added.single, isA<ProfileRequested>());
    });

    testWidgets('signed out draws a note; the shell owns the trip back', (
      tester,
    ) async {
      final bloc = _stub(const ProfileState(phase: ProfilePhase.signedOut));
      addTearDown(bloc.close);

      await _pump(tester, bloc);

      expect(find.text('Signed out.'), findsOneWidget);
      expect(bloc.added, isEmpty);
    });

    testWidgets('banner slot stays empty outside iOS Safari', (tester) async {
      final bloc = _stub(
        const ProfileState(
          phase: ProfilePhase.loaded,
          uid: 'u_me',
          authorId: 'u_me',
          displayName: 'Ada',
          handle: 'ada',
          locale: 'es-AR',
          isOwn: true,
        ),
      );
      addTearDown(bloc.close);

      await _pump(tester, bloc, showInstallGuide: () => false);

      expect(find.byKey(const Key('installGuideBanner')), findsNothing);
    });

    testWidgets('banner shows on iOS Safari and dismisses', (tester) async {
      final bloc = _stub(
        const ProfileState(
          phase: ProfilePhase.loaded,
          uid: 'u_me',
          authorId: 'u_me',
          displayName: 'Ada',
          handle: 'ada',
          locale: 'es-AR',
          isOwn: true,
        ),
      );
      addTearDown(bloc.close);

      await _pump(tester, bloc, showInstallGuide: () => true);

      expect(find.byKey(const Key('installGuideBanner')), findsOneWidget);
      expect(find.text('Install Ramifica'), findsOneWidget);

      await tester.tap(find.byKey(const Key('installGuideDismiss')));
      await tester.pump();

      expect(find.byKey(const Key('installGuideBanner')), findsNothing);
    });
  });

  group('install guide check', () {
    test('non-installed iOS Safari shows', () {
      expect(
        shouldShowInstallGuideFor(userAgent: _iosSafari, installed: false),
        isTrue,
      );
    });

    test('installed iOS Safari hides', () {
      expect(
        shouldShowInstallGuideFor(userAgent: _iosSafari, installed: true),
        isFalse,
      );
    });

    test('desktop Safari hides', () {
      expect(
        shouldShowInstallGuideFor(
          userAgent:
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
              'Safari/605.1.15',
          installed: false,
        ),
        isFalse,
      );
    });

    test('in-app iOS browsers hide', () {
      const chrome =
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/120.0 Mobile/15E148 '
          'Safari/604.1';
      expect(
        shouldShowInstallGuideFor(userAgent: chrome, installed: false),
        isFalse,
      );
    });
  });
}

/// Stubbed bloc state: the recorded events prove the view's wiring without
/// running any bloc logic. `add` never reaches the real handlers.
_StubProfileBloc _stub(ProfileState state) => _StubProfileBloc(state);

Future<void> _pump(
  WidgetTester tester,
  _StubProfileBloc bloc, {
  bool Function()? showInstallGuide,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProfileView(
          bloc: bloc,
          showInstallGuide: showInstallGuide ?? () => false,
        ),
      ),
    ),
  );
}

String _fieldText(WidgetTester tester, String key) {
  return tester.widget<TextField>(find.byKey(Key(key))).controller?.text ?? '';
}

class _StubProfileBloc extends ProfileBloc {
  _StubProfileBloc(this.stub)
    : super(
        auth: AuthRepository(auth: _FakeGateway(), users: _FakeUsers()),
        users: _FakeUsers(),
        follows: FollowRepository(
          fetchAuthorIds: (_) async => const <String>{},
        ),
      );

  ProfileState stub;
  final added = <ProfileEvent>[];

  @override
  ProfileState get state => stub;

  @override
  Stream<ProfileState> get stream => const Stream.empty();

  @override
  void add(ProfileEvent event) {
    added.add(event);
  }
}

class _FakeGateway implements AuthGateway {
  @override
  Stream<AuthIdentity?> authStateChanges() => const Stream.empty();

  @override
  AuthIdentity? get currentIdentity => null;

  @override
  Future<void> completeGoogleRedirect() async {}

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signInWithGooglePopup() async {}

  @override
  Future<void> signInWithGoogleRedirect() async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> signUpWithEmail({
    required String email,
    required String password,
  }) async {}
}

class _FakeUsers implements UserDirectory {
  @override
  Future<void> create(UserAccount user) async {}

  @override
  Future<bool> exists(String uid) async => false;

  @override
  Future<UserAccount?> read(String uid) async => null;

  @override
  Future<void> updateProfile({
    required String uid,
    String? displayName,
    String? handle,
    String? photoUrl,
    required String locale,
  }) async {}
}
