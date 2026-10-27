import 'package:ramifica/data/repositories/auth_repository.dart';

sealed class AuthEvent {
  const AuthEvent();
}

final class AuthStarted extends AuthEvent {
  const AuthStarted();
}

final class AuthSessionChanged extends AuthEvent {
  const AuthSessionChanged(this.identity);

  final AuthIdentity? identity;
}

final class SignInWithGoogleRequested extends AuthEvent {
  const SignInWithGoogleRequested();
}

final class SignInWithEmailRequested extends AuthEvent {
  const SignInWithEmailRequested({required this.email, required this.password});

  final String email;
  final String password;
}

final class SignUpWithEmailRequested extends AuthEvent {
  const SignUpWithEmailRequested({required this.email, required this.password});

  final String email;
  final String password;
}

final class PasswordResetRequested extends AuthEvent {
  const PasswordResetRequested(this.email);

  final String email;
}

final class PendingStorySaved extends AuthEvent {
  const PendingStorySaved(this.storyId);

  final String storyId;
}

final class PendingStoryConsumed extends AuthEvent {
  const PendingStoryConsumed();
}

final class SignOutRequested extends AuthEvent {
  const SignOutRequested();
}
