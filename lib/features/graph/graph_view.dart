import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/shell_bloc.dart';
import 'package:ramifica/app/shell_event.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/data/repositories/graph_repository.dart';
import 'package:ramifica/features/create/draft_canvas.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/feed/feed_event.dart';
import 'package:ramifica/features/graph/graph_bloc.dart';
import 'package:ramifica/features/graph/graph_event.dart';
import 'package:ramifica/features/graph/graph_state.dart';
import 'package:ramifica/features/graph/scene_info_card.dart';
import 'package:ramifica/features/graph/stub_draft.dart';

/// Map tab: the create hub canvas without actions. Stubs project onto
/// draft nodes; the run's current node keeps the You-are-here pill.
/// Creates its own bloc; tests inject a fake [repository] and [runId]
/// instead of a FeedBloc.
class GraphView extends StatefulWidget {
  const GraphView({
    super.key,
    required this.storyId,
    this.runId,
    this.repository,
    this.onExplore,
  });

  final String storyId;
  final String? runId;
  final GraphRepository? repository;
  final VoidCallback? onExplore;

  @override
  State<GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<GraphView> {
  GraphBloc? _bloc;
  final _viewer = TransformationController();

  /// A card play waiting for the run to land. Only this completion opens
  /// the feed; anything else that moves the run (the map following the
  /// feed, a reload) stays silent.
  bool _playArmed = false;
  String? _playTarget;
  FeedBloc? _feed;
  (String, String, String?)? _lastRequest;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _feed = _feedOf(context);
    _bloc ??= GraphBloc(
      repository: widget.repository ?? createFirebaseGraphRepository(),
    );
    _requestGraph();
  }

  @override
  void didUpdateWidget(GraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _requestGraph();
  }

  void _requestGraph({bool force = false}) {
    final bloc = _bloc;
    if (bloc == null) return;
    final feed = _feed?.state;
    final requestedStory = widget.storyId.trim();
    final story = requestedStory.isEmpty
        ? feed?.storyId?.trim() ?? ''
        : requestedStory;
    final followsFeed = widget.runId == null && feed?.storyId == story;
    final run = (widget.runId ?? (followsFeed ? feed?.runId : null) ?? '')
        .trim();
    final node = followsFeed ? feed?.playback?.node.nodeId : null;
    final request = (story, run, node);
    if (!force && request == _lastRequest) return;
    _lastRequest = request;
    final savedRun = bloc.state.storyId == story ? bloc.state.runId : null;
    bloc.add(
      GraphRequested(storyId: story, runId: run.isEmpty ? savedRun ?? '' : run),
    );
  }

  @override
  void dispose() {
    _viewer.dispose();
    _bloc?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bloc = _bloc;
    if (bloc == null) {
      return const Scaffold(body: SizedBox.shrink());
    }
    return BlocProvider.value(
      value: bloc,
      child: Builder(
        builder: (context) => BlocListener<GraphBloc, GraphState>(
          listenWhen: (previous, current) =>
              previous.currentNodeId != current.currentNodeId ||
              previous.failure != current.failure,
          listener: _onGraphChange,
          child: BlocBuilder<GraphBloc, GraphState>(
            builder: (context, state) {
              return Scaffold(
                appBar: state.phase == .loaded ? _mapBar(state) : null,
                body: Semantics(
                  label: 'Map ${state.storyId ?? widget.storyId}',
                  child: SafeArea(child: _body(context, state)),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, GraphState state) {
    if (!state.hasStory) {
      return Center(
        child: EmptyState(
          message: 'Open a story to see its map.',
          actionLabel: 'Explore',
          onAction: () => _explore(context),
        ),
      );
    }
    if (state.phase == .loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.phase == .failed) {
      return Center(
        child: FailureText(
          message: state.failure ?? 'Something failed',
          onRetry: () => _requestGraph(force: true),
        ),
      );
    }
    final selected = state.selected;
    return Stack(
      children: [
        Semantics(
          label: 'Story map',
          child: DraftCanvas(
            nodes: draftNodesFromStubs(state.stubs),
            orphans: draftOrphansFromStubs(state.stubs),
            rootNodeId: draftRootIdFromStubs(state.stubs),
            currentNodeId: state.currentNodeId,
            onSelect: (id) =>
                context.read<GraphBloc>().add(NodeSelected(id)),
            transformationController: _viewer,
          ),
        ),
        if (selected != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SceneInfoCard(
              stub: selected,
              onPlay: selected.visited && !state.acting
                  ? () => _playScene(context, state, selected.nodeId)
                  : null,
            ),
          ),
      ],
    );
  }

  void _explore(BuildContext context) {
    final explore = widget.onExplore;
    if (explore != null) {
      explore();
      return;
    }
    try {
      AppNavigation.read(context).go(AppRoutes.explore);
    } on FlutterError {
      // Widget tests mount GraphView without the router.
    }
  }

  /// Plays a scene from the card. The current one just opens the feed;
  /// anything else jumps the run first and [_onGraphChange] opens the
  /// feed once the run moves.
  void _playScene(BuildContext context, GraphState state, String nodeId) {
    if (nodeId == state.currentNodeId) {
      _openFeed(context, state);
      return;
    }
    _playArmed = true;
    _playTarget = nodeId;
    context.read<GraphBloc>().add(PlayRequested(nodeId));
  }

  /// Completes a card play once the run lands on the tapped scene.
  /// Reloads first: the shell skips same-story opens, so without this
  /// the feed would keep showing the old scene. While the jump settles
  /// the arm holds; the first settled state disarms, and only a landing
  /// on the tapped scene opens the feed. Play failures surface as a
  /// snack; the card has no failure slot.
  void _onGraphChange(BuildContext context, GraphState state) {
    if (!_playArmed) return;
    final failure = state.failure;
    if (failure != null && failure.isNotEmpty) {
      _playArmed = false;
      _playTarget = null;
      if (Scaffold.maybeOf(context) != null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(failure)));
      }
      return;
    }
    if (state.acting) return;
    _playArmed = false;
    final target = _playTarget;
    _playTarget = null;
    final current = state.currentNodeId;
    if (current == null || target == null || current != target) return;
    final feed = _feedOf(context);
    final run = state.runId;
    if (feed != null && run != null && run.isNotEmpty) {
      feed.add(PlaybackReloadRequested(run));
    }
    _openFeed(context, state);
  }

  void _openFeed(BuildContext context, GraphState state) {
    try {
      context.read<ShellBloc>().add(const TabSelected(.feed));
      final storyId = state.storyId ?? widget.storyId;
      if (storyId.isNotEmpty) {
        AppNavigation.read(context).go(
          AppRoutes.storyPath(Uri.encodeComponent(storyId)),
        );
      }
    } on FlutterError {
      // Widget tests mount GraphView without the shell.
    }
  }
}

FeedBloc? _feedOf(BuildContext context) {
  try {
    return BlocProvider.of<FeedBloc>(context, listen: true);
  } on FlutterError {
    return null;
  }
}

/// Map header: the story cover, title, and discovered-scenes count.
/// Only the loaded page has all three; other phases show no bar.
PreferredSizeWidget _mapBar(GraphState state) {
  final visited = state.stubs.where((stub) => stub.visited).length;
  final rawTitle = state.storyTitle?.trim() ?? '';
  final title = rawTitle.isEmpty ? state.storyId ?? '' : rawTitle;
  return AppBar(
    backgroundColor: RamificaColors.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    automaticallyImplyLeading: false,
    toolbarHeight: 72,
    title: Row(
      children: [
        _StoryCover(url: state.storyCoverUrl),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: .min,
            crossAxisAlignment: .start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: .ellipsis,
                style: RamificaText.screenTitle,
              ),
              const SizedBox(height: 2),
              Text(
                '$visited/${state.stubs.length} scenes discovered',
                style: RamificaText.meta,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _StoryCover extends StatelessWidget {
  const _StoryCover({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final cover = url?.trim() ?? '';
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 48,
        height: 48,
        child: cover.isEmpty
            ? Container(
                color: RamificaColors.inputFill,
                child: const Icon(
                  Icons.image_outlined,
                  size: 20,
                  color: RamificaColors.textSecondary,
                ),
              )
            : Image.network(
                cover,
                fit: .cover,
                errorBuilder: (_, _, _) => Container(
                  color: RamificaColors.inputFill,
                  child: const Icon(
                    Icons.image_outlined,
                    size: 20,
                    color: RamificaColors.textSecondary,
                  ),
                ),
              ),
      ),
    );
  }
}
