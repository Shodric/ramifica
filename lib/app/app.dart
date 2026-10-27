import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/router.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/shell_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/prefetcher.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/pending_story_store.dart';
import 'package:ramifica/data/repositories/run_repository.dart';
import 'package:ramifica/features/access/access_bloc.dart';
import 'package:ramifica/features/access/access_event.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';

class RamificaApp extends StatefulWidget {
  const RamificaApp({
    super.key,
    this.initialRoute = AppRoutes.feed,
    this.authRepository,
    this.pendingStoryStore,
    this.runRepository,
    this.prefetcher,
  });

  final String initialRoute;
  final AuthRepository? authRepository;
  final PendingStoryStore? pendingStoryStore;
  final RunRepository? runRepository;

  /// Test double. Production builds a browser [Prefetcher].
  final Prefetcher? prefetcher;

  @override
  State<RamificaApp> createState() => _RamificaAppState();
}

class _RamificaAppState extends State<RamificaApp> {
  late final String _startPath = _resolveStartPath();
  late final AppRouteController _controller = AppRouteController(
    parseLocation(_startPath),
  );
  late final RamificaRouterDelegate _router = RamificaRouterDelegate(
    _controller,
  );
  late final PlatformRouteInformationProvider _provider =
      PlatformRouteInformationProvider(
        initialRouteInformation: RouteInformation(uri: Uri.parse(_startPath)),
      );

  String _resolveStartPath() {
    if (widget.initialRoute != AppRoutes.feed) return widget.initialRoute;
    final platform =
        WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    if (platform.isEmpty || platform == AppRoutes.feed) {
      return widget.initialRoute;
    }
    return platform.startsWith('/') ? platform : '/$platform';
  }

  @override
  void dispose() {
    _router.dispose();
    _provider.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppNavigation(
      controller: _controller,
      child: MaterialApp.router(
        title: 'Ramifica',
        theme: RamificaTheme.data,
        routerDelegate: _router,
        routeInformationParser: const AppRouteInformationParser(),
        routeInformationProvider: _provider,
      ),
    );
    Widget shell = BlocProvider(
      create: (_) =>
          ShellBloc(initial: shellStateFor(parseLocation(_startPath))),
      child: app,
    );
    final runs = widget.runRepository;
    if (runs != null) {
      shell = BlocProvider(
        create: (_) =>
            FeedBloc(repository: runs, prefetcher: widget.prefetcher),
        child: shell,
      );
    }
    final repository = widget.authRepository;
    if (repository == null) return shell;
    return BlocProvider(
      create: (_) => AuthBloc(
        repository: repository,
        pendingStories: widget.pendingStoryStore ?? MemoryPendingStoryStore(),
      )..add(const AuthStarted()),
      child: shell,
    );
  }
}
