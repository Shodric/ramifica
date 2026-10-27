import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/features/access/access_bloc.dart';
import 'package:ramifica/features/access/access_event.dart';
import 'package:ramifica/features/access/access_state.dart';

class AccessView extends StatefulWidget {
  const AccessView({super.key});

  @override
  State<AccessView> createState() => _AccessViewState();
}

class _AccessViewState extends State<AccessView> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final bloc = _authOf(context);
      if (bloc != null && bloc.state.phase == .signedIn) {
        _openApp(bloc.state);
      }
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bloc = _authOf(context, listen: true);
    final state = bloc?.state ?? const AuthState();
    final form = _AccessForm(
      state: state,
      email: _email,
      password: _password,
      onGoogle: bloc == null
          ? null
          : () => bloc.add(const SignInWithGoogleRequested()),
      onSignIn: bloc == null
          ? null
          : () => bloc.add(
              SignInWithEmailRequested(
                email: _email.text,
                password: _password.text,
              ),
            ),
      onSignUp: bloc == null
          ? null
          : () => bloc.add(
              SignUpWithEmailRequested(
                email: _email.text,
                password: _password.text,
              ),
            ),
      onReset: bloc == null
          ? null
          : () => bloc.add(PasswordResetRequested(_email.text)),
    );
    if (bloc == null) return form;
    return BlocListener<AuthBloc, AuthState>(
      listenWhen: (previous, next) {
        return previous.phase != .signedIn && next.phase == .signedIn;
      },
      listener: (context, state) => _openApp(state),
      child: form,
    );
  }

  void _openApp(AuthState state) {
    final pending = state.pendingStoryId;
    final route = pending == null || pending.isEmpty
        ? AppRoutes.feed
        : AppRoutes.storyPath(Uri.encodeComponent(pending));
    Navigator.of(context).pushReplacementNamed(route);
  }
}

AuthBloc? _authOf(BuildContext context, {bool listen = false}) {
  try {
    return BlocProvider.of<AuthBloc>(context, listen: listen);
  } on FlutterError {
    return null;
  }
}

class _AccessForm extends StatelessWidget {
  const _AccessForm({
    required this.state,
    required this.email,
    required this.password,
    required this.onGoogle,
    required this.onSignIn,
    required this.onSignUp,
    required this.onReset,
  });

  final AuthState state;
  final TextEditingController email;
  final TextEditingController password;
  final VoidCallback? onGoogle;
  final VoidCallback? onSignIn;
  final VoidCallback? onSignUp;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final busy = state.phase == .signingIn;
    final enabled = !busy;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth - 48;
            final height = constraints.maxHeight - 64;
            return SingleChildScrollView(
              padding: const .symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: width > 0 ? width : 0,
                  minHeight: height > 0 ? height : 0,
                ),
                child: Column(
                  mainAxisAlignment: .center,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: Column(
                        crossAxisAlignment: .stretch,
                        children: [
                          Text(
                            'Sign in',
                            style: RamificaText.screenTitle,
                            textAlign: .center,
                          ),
                          const SizedBox(height: 28),
                          if (busy) ...[
                            const LinearProgressIndicator(),
                            const SizedBox(height: 16),
                          ],
                          FilledButton(
                            onPressed: enabled ? () => onGoogle?.call() : null,
                            child: const Text('Continue with Google'),
                          ),
                          const SizedBox(height: 20),
                          TextField(
                            controller: email,
                            enabled: enabled,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            textInputAction: .next,
                            style: RamificaText.body,
                            decoration: _field('Email'),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: password,
                            enabled: enabled,
                            obscureText: true,
                            autofillHints: const [AutofillHints.password],
                            textInputAction: .done,
                            onSubmitted: enabled
                                ? (_) => onSignIn?.call()
                                : null,
                            style: RamificaText.body,
                            decoration: _field('Password'),
                          ),
                          Align(
                            alignment: .centerRight,
                            child: TextButton(
                              onPressed: enabled ? () => onReset?.call() : null,
                              child: const Text('Forgot my password'),
                            ),
                          ),
                          FilledButton(
                            onPressed: enabled ? () => onSignIn?.call() : null,
                            child: const Text('Sign in'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: enabled ? () => onSignUp?.call() : null,
                            child: const Text('Create account'),
                          ),
                          if (state.failure != null) ...[
                            const SizedBox(height: 16),
                            FailureText(message: state.failure!),
                          ],
                          if (state.notice != null) ...[
                            const SizedBox(height: 16),
                            Text(
                              state.notice!,
                              style: RamificaText.body.copyWith(
                                color: RamificaColors.textSecondary,
                              ),
                              textAlign: .center,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

InputDecoration _field(String label) {
  const radius = BorderRadius.all(Radius.circular(12));
  const side = BorderSide(color: RamificaColors.glassBorder);
  return InputDecoration(
    labelText: label,
    labelStyle: RamificaText.label.copyWith(
      color: RamificaColors.textSecondary,
    ),
    filled: true,
    fillColor: const Color(0x0FFFFFFF),
    enabledBorder: const OutlineInputBorder(
      borderRadius: radius,
      borderSide: side,
    ),
    focusedBorder: const OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: RamificaColors.hotspot),
    ),
    disabledBorder: const OutlineInputBorder(
      borderRadius: radius,
      borderSide: side,
    ),
  );
}
