import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ramifica/app/app.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/data/models/auth_exception.dart';
import 'package:ramifica/data/models/user.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/pending_story_store.dart';
import 'package:ramifica/features/access/access_bloc.dart';
import 'package:ramifica/features/access/access_state.dart';
import 'package:ramifica/features/feed/feed_view.dart';

void main() {
  testWidgets('the form fits a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const RamificaApp(initialRoute: '/access'));
    await tester.pump();

    expect(find.text('Forgot my password'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    final button = tester.getRect(
      find.widgetWithText(FilledButton, 'Continue with Google'),
    );
    final link = tester.getRect(find.text('Forgot my password'));
    expect(button.left, greaterThanOrEqualTo(16));
    expect(button.right, lessThanOrEqualTo(320));
    expect(link.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the form has no tab bar', (tester) async {
    await tester.pumpWidget(
      RamificaApp(initialRoute: '/access', authRepository: _repository()),
    );
    await tester.pump();

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Forgot my password'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Explore'), findsNothing);
  });

  testWidgets('Google disables the actions while it runs', (tester) async {
    final auth = _ViewAuth()..onPopup = () => Completer<void>().future;
    await tester.pumpWidget(
      RamificaApp(initialRoute: '/access', authRepository: _repository(auth)),
    );
    await tester.pump();

    await tester.tap(find.text('Continue with Google'));
    await tester.pump();

    expect(auth.popupCalls, 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Continue with Google'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('a closed popup shows FailureText', (tester) async {
    final auth = _ViewAuth()
      ..onPopup = () async {
        throw const AuthException(.popupClosed);
      };
    await tester.pumpWidget(
      RamificaApp(initialRoute: '/access', authRepository: _repository(auth)),
    );
    await tester.pump();

    await tester.tap(find.text('Continue with Google'));
    await tester.pump();

    expect(find.byType(FailureText), findsOneWidget);
    expect(find.text('The sign-in window was closed'), findsOneWidget);
  });

  testWidgets('sign in sends the email and password', (tester) async {
    final auth = _ViewAuth();
    await tester.pumpWidget(
      RamificaApp(initialRoute: '/access', authRepository: _repository(auth)),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField).at(0), 'a@b.co');
    await tester.enterText(find.byType(TextField).at(1), 'long-enough');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(auth.email, 'a@b.co');
    expect(auth.password, 'long-enough');
  });

  testWidgets('create account rejects a short password', (tester) async {
    await tester.pumpWidget(
      RamificaApp(initialRoute: '/access', authRepository: _repository()),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField).at(0), 'a@b.co');
    await tester.enterText(find.byType(TextField).at(1), 'short');
    await tester.tap(find.text('Create account'));
    await tester.pump();

    expect(find.text('Use at least 8 characters'), findsOneWidget);
  });

  testWidgets('forgot password shows the notice', (tester) async {
    await tester.pumpWidget(
      RamificaApp(initialRoute: '/access', authRepository: _repository()),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField).at(0), 'a@b.co');
    await tester.tap(find.text('Forgot my password'));
    await tester.pump();

    expect(find.text(passwordResetNotice), findsOneWidget);
    expect(find.byType(FailureText), findsNothing);
  });

  testWidgets('a story link without a session opens sign in', (tester) async {
    await tester.pumpWidget(
      RamificaApp(
        initialRoute: '/story/story_temple',
        authRepository: _repository(),
      ),
    );
    await tester.pump();

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Feed'), findsNothing);
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

  testWidgets('a signed-in session at / opens the feed', (tester) async {
    final auth = _ViewAuth();
    await tester.pumpWidget(RamificaApp(authRepository: _repository(auth)));
    await tester.pump();

    auth.identity = const AuthIdentity(uid: 'uid_1', providers: ['google.com']);
    auth.sessions.add(auth.identity);
    await tester.pumpAndSettle();

    expect(tester.widget<FeedView>(find.byType(FeedView)).storyId, isNull);
    expect(find.text('Continue with Google'), findsNothing);
  });

  testWidgets('a signed-in session opens the pending story', (tester) async {
    final auth = _ViewAuth();
    final store = MemoryPendingStoryStore()..write('story_temple');
    await tester.pumpWidget(
      RamificaApp(
        initialRoute: '/access',
        authRepository: _repository(auth),
        pendingStoryStore: store,
      ),
    );
    await tester.pump();

    auth.identity = const AuthIdentity(uid: 'uid_1', providers: ['google.com']);
    auth.sessions.add(auth.identity);
    await tester.pumpAndSettle();

    expect(
      tester.widget<FeedView>(find.byType(FeedView)).storyId,
      'story_temple',
    );
    expect(find.text('Continue with Google'), findsNothing);
  });

  testWidgets('a signed-in session with no story opens the feed', (
    tester,
  ) async {
    final auth = _ViewAuth();
    await tester.pumpWidget(
      RamificaApp(initialRoute: '/access', authRepository: _repository(auth)),
    );
    await tester.pump();

    auth.identity = const AuthIdentity(uid: 'uid_1', providers: ['google.com']);
    auth.sessions.add(auth.identity);
    await tester.pumpAndSettle();

    expect(tester.widget<FeedView>(find.byType(FeedView)).storyId, isNull);
    expect(find.text('Continue with Google'), findsNothing);
  });
}

AuthRepository _repository([_ViewAuth? auth]) {
  return AuthRepository(auth: auth ?? _ViewAuth(), users: _ViewUsers());
}

class _ViewAuth implements AuthGateway {
  final sessions = StreamController<AuthIdentity?>();
  AuthIdentity? identity;
  var popupCalls = 0;
  String? email;
  String? password;
  Future<void> Function()? onPopup;

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
  Future<void> signInWithGoogleRedirect() async {}

  @override
  Future<void> completeGoogleRedirect() async {}

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {
    this.email = email;
    this.password = password;
  }

  @override
  Future<void> signUpWithEmail({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Future<void> signOut() async {}
}

class _ViewUsers implements UserDirectory {
  @override
  Future<void> create(UserAccount user) async {}

  @override
  Future<bool> exists(String uid) async => true;

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
