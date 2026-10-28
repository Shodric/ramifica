import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/data/repositories/graph_repository.dart';
import 'package:ramifica/features/feed/feed_bloc.dart';
import 'package:ramifica/features/graph/graph_bloc.dart';
import 'package:ramifica/features/graph/graph_canvas.dart';
import 'package:ramifica/features/graph/graph_event.dart';
import 'package:ramifica/features/graph/graph_state.dart';
import 'package:ramifica/features/graph/node_sheet.dart';

/// Map tab: canvas plus the selected node sheet. Creates its own bloc;
/// tests inject a fake [repository] and [runId] instead of a FeedBloc.
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bloc != null) return;
    final runId = widget.runId ?? _feedRunId(context);
    _bloc = GraphBloc(
      repository: widget.repository ?? createFirebaseGraphRepository(),
    )..add(GraphRequested(storyId: widget.storyId, runId: runId ?? ''));
  }

  @override
  void dispose() {
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
        builder: (context) => BlocBuilder<GraphBloc, GraphState>(
          builder: (context, state) {
            return Scaffold(
              body: Semantics(
                label: 'Map ${widget.storyId}',
                child: SafeArea(child: _body(context, state)),
              ),
            );
          },
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
          onRetry: () => _reload(context, state),
        ),
      );
    }
    final selected = state.selected;
    return Stack(
      fit: .expand,
      children: [
        Semantics(
          label: 'Graph canvas',
          child: GraphCanvas(
            stubs: state.stubs,
            currentNodeId: state.currentNodeId,
            selectedId: state.selectedId,
            onSelected: (id) =>
                context.read<GraphBloc>().add(NodeSelected(id)),
          ),
        ),
        if (selected != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Semantics(
              label: 'Node sheet',
              child: NodeSheet(
                stub: selected,
                stubs: state.stubs,
                isCurrent: selected.nodeId == state.currentNodeId,
                busy: state.acting,
                failure: state.failure,
                onContinue: () => _continue(context),
                onRewind: () =>
                    context.read<GraphBloc>().add(const RewindRequested()),
                onApproach: () => context.read<GraphBloc>().add(
                  ApproachRequested(selected.nodeId),
                ),
                onRetry: () => _reload(context, state),
                onSelectChild: (id) {
                  final bloc = context.read<GraphBloc>();
                  var locked = false;
                  for (final stub in state.stubs) {
                    if (stub.nodeId == id && stub.locked) locked = true;
                  }
                  bloc.add(
                    locked ? ApproachRequested(id) : NodeSelected(id),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  void _reload(BuildContext context, GraphState state) {
    final runId = widget.runId ?? _feedRunId(context) ?? state.runId ?? '';
    context.read<GraphBloc>().add(
      GraphRequested(storyId: widget.storyId, runId: runId),
    );
  }

  void _continue(BuildContext context) {
    context.read<GraphBloc>().add(const ContinueRequested());
    final story = widget.storyId.trim();
    try {
      AppNavigation.read(context).go(
        story.isEmpty ? AppRoutes.feed : AppRoutes.storyPath(
          Uri.encodeComponent(story),
        ),
      );
    } on FlutterError {
      // Widget tests mount GraphView without the router.
    }
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
}

String? _feedRunId(BuildContext context) {
  try {
    return BlocProvider.of<FeedBloc>(context, listen: false).state.runId;
  } on FlutterError {
    return null;
  }
}
