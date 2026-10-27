import 'package:flutter/material.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/features/access/access_view.dart';
import 'package:ramifica/features/create/create_view.dart';
import 'package:ramifica/features/explore/explore_view.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/graph/graph_view.dart';
import 'package:ramifica/features/profile/profile_view.dart';

class RamificaApp extends StatelessWidget {
  const RamificaApp({super.key, this.initialRoute = AppRoutes.feed});

  final String initialRoute;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ramifica',
      theme: RamificaTheme.data,
      initialRoute: initialRoute,
      onGenerateRoute: _onGenerateRoute,
    );
  }
}

Route<void> _onGenerateRoute(RouteSettings settings) {
  final location = parseLocation(settings.name);
  return MaterialPageRoute<void>(
    settings: settings,
    builder: (context) {
      return switch (location) {
        FeedLocation(:final storyId) => FeedView(storyId: storyId),
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

class _UnknownPage extends StatelessWidget {
  const _UnknownPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('This page does not exist.')),
    );
  }
}
