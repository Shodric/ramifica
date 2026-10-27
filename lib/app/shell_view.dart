import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/shell_bloc.dart';
import 'package:ramifica/app/shell_event.dart';
import 'package:ramifica/app/shell_state.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/features/access/access_bloc.dart';
import 'package:ramifica/features/access/access_event.dart';
import 'package:ramifica/features/access/access_view.dart';
import 'package:ramifica/features/create/create_view.dart';
import 'package:ramifica/features/explore/explore_view.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/graph/graph_view.dart';
import 'package:ramifica/features/profile/profile_view.dart';

class ShellView extends StatefulWidget {
  const ShellView({super.key, required this.location});

  final AppLocation location;

  @override
  State<ShellView> createState() => _ShellViewState();
}

class _ShellViewState extends State<ShellView> {
  String? _redirect;

  @override
  void initState() {
    super.initState();
    _apply(widget.location);
    _scheduleRedirect();
  }

  @override
  void didUpdateWidget(ShellView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (pathOf(oldWidget.location) == pathOf(widget.location)) return;
    _apply(widget.location);
    _scheduleRedirect();
  }

  void _apply(AppLocation location) {
    final shell = context.read<ShellBloc>();
    switch (location) {
      case FeedLocation(:final storyId):
        final pending = _pendingStory();
        final openId = storyId == null || storyId.isEmpty ? pending : storyId;
        if (openId != null && openId.isNotEmpty) {
          shell.add(StoryOpenRequested(openId));
          if (pathOf(location) == AppRoutes.feed && openId == pending) {
            _redirect = AppRoutes.storyPath(Uri.encodeComponent(openId));
          }
        } else {
          shell.add(const TabSelected(.feed));
        }
        _consumePending();
      case ExploreLocation():
        shell.add(const TabSelected(.explore));
      case CreateLocation():
        shell.add(const TabSelected(.create));
      case GraphLocation(:final storyId):
        shell.add(TabSelected(.graph, storyId: storyId));
      case ProfileLocation():
        shell.add(const TabSelected(.profile));
      case AccessLocation() || UnknownLocation():
        break;
    }
  }

  String? _pendingStory() {
    final auth = _authOf(context);
    if (auth == null || auth.state.phase != .signedIn) return null;
    final pending = auth.state.pendingStoryId;
    if (pending == null || pending.isEmpty) return null;
    return pending;
  }

  void _consumePending() {
    final auth = _authOf(context);
    if (auth == null || auth.state.phase != .signedIn) return;
    final pending = auth.state.pendingStoryId;
    if (pending == null || pending.isEmpty) return;
    auth.add(const PendingStoryConsumed());
  }

  void _scheduleRedirect() {
    final path = _redirect;
    _redirect = null;
    if (path == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppNavigation.read(context).go(path);
    });
  }

  void _select(ShellState state, ShellTab tab) {
    context.read<ShellBloc>().add(TabSelected(tab));
    final storyId = state.storyId;
    final path = switch (tab) {
      .feed => _feedPath(storyId),
      .explore => AppRoutes.explore,
      .create => AppRoutes.create,
      .graph => _graphPath(storyId),
      .profile => AppRoutes.profile,
    };
    if (path == null) return;
    AppNavigation.read(context).go(path);
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ShellBloc, ShellState>(
      builder: (context, state) {
        final storyId = state.storyId ?? '';
        return Scaffold(
          extendBody: true,
          body: IndexedStack(
            index: state.tab.index,
            children: [
              TickerMode(
                enabled: state.tab == .feed,
                child: FeedView(storyId: state.storyId),
              ),
              const ExploreView(),
              const CreateView(),
              GraphView(storyId: storyId),
              const ProfileView(),
            ],
          ),
          bottomNavigationBar: NavigationBarTheme(
            data: NavigationBarThemeData(
              backgroundColor: RamificaColors.glass,
              indicatorColor: RamificaColors.hotspot.withValues(alpha: 0.2),
              elevation: 0,
              labelTextStyle: WidgetStateProperty.resolveWith((states) {
                final selected = states.contains(WidgetState.selected);
                return RamificaText.meta.copyWith(
                  color: selected
                      ? RamificaColors.hotspot
                      : RamificaColors.textSecondary,
                  fontWeight: selected ? .w600 : .w400,
                );
              }),
              iconTheme: WidgetStateProperty.resolveWith((states) {
                final selected = states.contains(WidgetState.selected);
                return IconThemeData(
                  color: selected
                      ? RamificaColors.hotspot
                      : RamificaColors.textSecondary,
                );
              }),
            ),
            child: NavigationBar(
              selectedIndex: state.tab.index,
              labelBehavior: .alwaysShow,
              destinations: [
                for (final tab in ShellTab.values) _destination(tab),
              ],
              onDestinationSelected: (index) {
                _select(state, ShellTab.values[index]);
              },
            ),
          ),
        );
      },
    );
  }
}

NavigationDestination _destination(ShellTab tab) {
  return switch (tab) {
    .feed => const NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: 'Feed',
    ),
    .explore => const NavigationDestination(
      icon: Icon(Icons.grid_view_outlined),
      selectedIcon: Icon(Icons.grid_view),
      label: 'Explore',
    ),
    .create => const NavigationDestination(
      icon: _CreateIcon(selected: false),
      selectedIcon: _CreateIcon(selected: true),
      label: '',
    ),
    .graph => const NavigationDestination(
      icon: Icon(Icons.account_tree_outlined),
      selectedIcon: Icon(Icons.account_tree),
      label: 'Map',
    ),
    .profile => const NavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: 'Profile',
    ),
  };
}

class _CreateIcon extends StatelessWidget {
  const _CreateIcon({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Create',
      button: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? RamificaColors.hotspot : RamificaColors.glass,
          shape: .circle,
        ),
        child: SizedBox.square(
          dimension: 36,
          child: Icon(
            Icons.add,
            color: selected
                ? const Color(0xFF00373A)
                : RamificaColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

String _feedPath(String? storyId) {
  if (storyId == null || storyId.isEmpty) return AppRoutes.feed;
  return AppRoutes.storyPath(Uri.encodeComponent(storyId));
}

String? _graphPath(String? storyId) {
  if (storyId == null || storyId.isEmpty) return null;
  return AppRoutes.graphPath(Uri.encodeComponent(storyId));
}

class ShellGate extends StatefulWidget {
  const ShellGate({super.key, required this.location});

  final AppLocation location;

  @override
  State<ShellGate> createState() => _ShellGateState();
}

class _ShellGateState extends State<ShellGate> {
  @override
  void initState() {
    super.initState();
    _savePending(widget.location);
  }

  @override
  void didUpdateWidget(ShellGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (pathOf(oldWidget.location) == pathOf(widget.location)) return;
    _savePending(widget.location);
  }

  void _savePending(AppLocation location) {
    if (location is! FeedLocation) return;
    final storyId = location.storyId;
    if (storyId == null || storyId.isEmpty) return;
    final bloc = _authOf(context);
    if (bloc == null || bloc.state.phase == .signedIn) return;
    bloc.add(PendingStorySaved(storyId));
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    if (location is UnknownLocation) {
      return const _UnknownPage();
    }
    if (location is AccessLocation) {
      return const AccessView();
    }
    final bloc = _authOf(context, listen: true);
    final signedIn = bloc != null && bloc.state.phase == .signedIn;
    if (location is FeedLocation && !signedIn) {
      return const AccessView();
    }
    return ShellView(location: location);
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

AuthBloc? _authOf(BuildContext context, {bool listen = false}) {
  try {
    return BlocProvider.of<AuthBloc>(context, listen: listen);
  } on FlutterError {
    return null;
  }
}
