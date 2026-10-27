import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:ramifica/data/models/auth_exception.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/pending_story_store.dart';
import 'package:ramifica/features/access/access_event.dart';
import 'package:ramifica/features/access/access_state.dart';

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc({required this.repository, required this.pendingStories})
    : super(const AuthState()) {
    on<AuthStarted>(_onStarted);
    on<AuthSessionChanged>(_onSession, transformer: restartable());
    on<SignInWithGoogleRequested>(_onGoogle, transformer: droppable());
    on<SignInWithEmailRequested>(_onEmail, transformer: droppable());
    on<SignUpWithEmailRequested>(_onSignUp, transformer: droppable());
    on<PasswordResetRequested>(_onReset, transformer: droppable());
    on<PendingStorySaved>(_onPendingSaved);
    on<PendingStoryConsumed>(_onPendingConsumed);
    on<SignOutRequested>(_onSignOut);
  }

  final AuthRepository repository;
  final PendingStoryStore pendingStories;
  StreamSubscription<AuthIdentity?>? _session;

  Future<void> _onStarted(AuthStarted event, Emitter<AuthState> emit) async {
    final pending = pendingStories.read();
    if (pending != null && pending.isNotEmpty) {
      emit(state.copyWith(pendingStoryId: pending));
    }
    try {
      await repository.completeRedirect();
    } on AuthException catch (error) {
      emit(state.copyWith(failure: error.phrase));
    }
    await _session?.cancel();
    _session = repository.authStateChanges().listen((identity) {
      if (isClosed) return;
      add(AuthSessionChanged(identity));
    });
  }

  Future<void> _onSession(
    AuthSessionChanged event,
    Emitter<AuthState> emit,
  ) async {
    final identity = event.identity;
    if (identity == null) {
      if (state.phase == .signingIn) return;
      emit(state.copyWith(phase: .signedOut));
      return;
    }
    try {
      await repository.ensureUser();
      emit(
        state.copyWith(phase: .signedIn, clearFailure: true, clearNotice: true),
      );
    } on AuthException catch (error) {
      emit(state.copyWith(phase: .signedIn, failure: error.phrase));
    }
  }

  Future<void> _onGoogle(
    SignInWithGoogleRequested event,
    Emitter<AuthState> emit,
  ) {
    return _signIn(emit, repository.signInWithGoogle);
  }

  Future<void> _onEmail(
    SignInWithEmailRequested event,
    Emitter<AuthState> emit,
  ) {
    return _signIn(
      emit,
      () => repository.signInWithEmail(
        email: event.email,
        password: event.password,
      ),
    );
  }

  Future<void> _onSignUp(
    SignUpWithEmailRequested event,
    Emitter<AuthState> emit,
  ) {
    return _signIn(
      emit,
      () => repository.signUpWithEmail(
        email: event.email,
        password: event.password,
      ),
    );
  }

  Future<void> _signIn(
    Emitter<AuthState> emit,
    Future<void> Function() action,
  ) async {
    if (state.phase == .signingIn) return;
    emit(
      state.copyWith(phase: .signingIn, clearFailure: true, clearNotice: true),
    );
    try {
      await action();
    } on AuthException catch (error) {
      emit(state.copyWith(phase: .signedOut, failure: error.phrase));
    }
  }

  Future<void> _onReset(
    PasswordResetRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(state.copyWith(clearFailure: true, clearNotice: true));
    try {
      await repository.sendPasswordReset(event.email);
      emit(state.copyWith(notice: passwordResetNotice, clearFailure: true));
    } on AuthException catch (error) {
      emit(state.copyWith(failure: error.phrase, clearNotice: true));
    }
  }

  void _onPendingSaved(PendingStorySaved event, Emitter<AuthState> emit) {
    final storyId = event.storyId.trim();
    if (storyId.isEmpty) return;
    pendingStories.write(storyId);
    emit(state.copyWith(pendingStoryId: storyId));
  }

  void _onPendingConsumed(PendingStoryConsumed event, Emitter<AuthState> emit) {
    pendingStories.clear();
    emit(state.copyWith(clearPendingStoryId: true));
  }

  Future<void> _onSignOut(
    SignOutRequested event,
    Emitter<AuthState> emit,
  ) async {
    try {
      await repository.signOut();
    } on AuthException catch (error) {
      emit(state.copyWith(failure: error.phrase));
    }
  }

  @override
  Future<void> close() async {
    await _session?.cancel();
    return super.close();
  }
}
