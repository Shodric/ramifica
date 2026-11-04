import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/shell_bloc.dart';
import 'package:ramifica/app/shell_event.dart';
import 'package:ramifica/app/shell_state.dart';
import 'package:ramifica/data/repositories/graph_repository.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_view.dart';
import 'package:ramifica/features/feed/node_video.dart';
import 'package:ramifica/features/graph/graph_view.dart';

/// Swipe navigation from the feed to the story tree, PageView-native.
///
/// Page 0 is the fullscreen feed, page 1 the tree, so a leftward drag
/// reveals the tree. The finger drives the transition: release past
/// halfway (or fling) to land, release early to snap back.
///
/// Swiping only works on the feed: anywhere else the pager locks and
/// the tree is left through the tab bar. The [PageController] stays in
/// sync with the [ShellBloc] both ways: settling on the tree selects
/// its tab (carrying the feed's story id), and an external tab
/// selection (navbar, deep link, "See map" pill) jumps instantly.
class FeedGraphPager extends StatefulWidget {
  const FeedGraphPager({
    super.key,
    this.storyId,
    this.graphRepository,
    this.clipPlayer,
  });

  /// Open story shown on both pages. The feed falls back to its own.
  final String? storyId;

  /// Test double for the tree page. Production leaves this null.
  final GraphRepository? graphRepository;

  /// Test double for the feed's [NodeVideo]. Production leaves this null.
  final ClipPlayer? clipPlayer;

  @override
  State<FeedGraphPager> createState() => _FeedGraphPagerState();
}

class _FeedGraphPagerState extends State<FeedGraphPager> {
  static const _feedPage = 0;
  static const _graphPage = 1;

  late final PageController _pages;

  @override
  void initState() {
    super.initState();
    final tab = context.read<ShellBloc>().state.tab;
    _pages = PageController(
      initialPage: tab == .graph ? _graphPage : _feedPage,
    );
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    if (page == _graphPage) {
      context.read<ShellBloc>().add(
        TabSelected(.graph, storyId: _feedOf(context)?.state.storyId),
      );
    } else {
      context.read<ShellBloc>().add(const TabSelected(.feed));
    }
  }

  void _jumpToTab(ShellTab tab) {
    if (!_pages.hasClients) return;
    final target = tab == .graph ? _graphPage : _feedPage;
    if (_pages.page?.round() == target) return;
    _pages.jumpToPage(target);
  }

  @override
  Widget build(BuildContext context) {
    final tab = context.watch<ShellBloc>().state.tab;
    return BlocListener<ShellBloc, ShellState>(
      listenWhen: (previous, current) =>
          (current.tab == .feed || current.tab == .graph) &&
          current.tab != previous.tab,
      listener: (context, state) => _jumpToTab(state.tab),
      child: PageView(
        controller: _pages,
        // The swipe lives on the feed only. Off the feed the pager
        // locks; programmatic jumps still work.
        physics: tab == .feed ? null : const NeverScrollableScrollPhysics(),
        onPageChanged: _onPageChanged,
        children: [
          TickerMode(
            enabled: tab == .feed,
            child: FeedView(
              storyId: widget.storyId,
              clipPlayer: widget.clipPlayer,
            ),
          ),
          GraphView(
            storyId: widget.storyId ?? '',
            repository: widget.graphRepository,
          ),
        ],
      ),
    );
  }
}

FeedBloc? _feedOf(BuildContext context) {
  try {
    return BlocProvider.of<FeedBloc>(context);
  } on FlutterError {
    return null;
  }
}
