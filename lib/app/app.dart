import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/pending_story_store.dart';
import 'package:ramifica/features/access/access_bloc.dart';
import 'package:ramifica/features/access/access_event.dart';
import 'package:ramifica/features/access/access_view.dart';
import 'package:ramifica/features/create/create_view.dart';
import 'package:ramifica/features/explore/explore_view.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/graph/graph_view.dart';
import 'package:ramifica/features/profile/profile_view.dart';

class RamificaApp extends StatelessWidget {
  const RamificaApp({
    super.key,
    this.initialRoute = AppRoutes.feed,
    this.authRepository,
    this.pendingStoryStore,
  });

  final String initialRoute;
  final AuthRepository? authRepository;
  final PendingStoryStore? pendingStoryStore;

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      title: 'Ramifica',
      theme: RamificaTheme.data,
      initialRoute: initialRoute,
      onGenerateRoute: _onGenerateRoute,
    );
    final repository = authRepository;
    if (repository == null) return app;
    return BlocProvider(
      create: (_) => AuthBloc(
        repository: repository,
        pendingStories: pendingStoryStore ?? MemoryPendingStoryStore(),
      )..add(const AuthStarted()),
      child: app,
    );
  }
}

Route<void> _onGenerateRoute(RouteSettings settings) {
  final location = parseLocation(settings.name);
  return MaterialPageRoute<void>(
    settings: settings,
    builder: (context) {
      return switch (location) {
        FeedLocation(:final storyId) => _FeedGate(storyId: storyId),
        ExploreLocation() => const ExploreView(),
        GraphLocation(:final storyId) => GraphView(storyId: storyId),
        ProfileLocation() => const ProfileView(),
        AccessLocation() => const AccessView(),
        CreateLocation() => const CreateView(),
        UnknownLocation() => const _UnknownPage(),
      };
    },
  );
}

class _FeedGate extends StatefulWidget {
  const _FeedGate({this.storyId});

  final String? storyId;

  @override
  State<_FeedGate> createState() => _FeedGateState();
}

class _FeedGateState extends State<_FeedGate> {
  @override
  void initState() {
    super.initState();
    final storyId = widget.storyId;
    if (storyId == null || storyId.isEmpty) return;
    final bloc = _authOf(context);
    if (bloc == null || bloc.state.phase == .signedIn) return;
    bloc.add(PendingStorySaved(storyId));
  }

  @override
  Widget build(BuildContext context) {
    final bloc = _authOf(context, listen: true);
    final signedIn = bloc != null && bloc.state.phase == .signedIn;
    if (!signedIn) return const AccessView();
    return FeedView(storyId: widget.storyId);
  }
}

AuthBloc? _authOf(BuildContext context, {bool listen = false}) {
  try {
    return BlocProvider.of<AuthBloc>(context, listen: listen);
  } on FlutterError {
    return null;
  }
}

class _UnknownPage extends StatelessWidget {
  const _UnknownPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('This page does not exist.')),
    );
  }
}
