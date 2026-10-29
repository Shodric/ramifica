import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/app/shell_bloc.dart';
import 'package:ramifica/app/shell_event.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/data/models/graph_stub.dart';
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
        Column(
          crossAxisAlignment: .stretch,
          children: [
            _MapHeader(
              storyId: state.storyId ?? widget.storyId,
              busy: state.acting,
              onRewind: () =>
                  context.read<GraphBloc>().add(const RewindRequested()),
            ),
            _MapStats(stubs: state.stubs),
            Expanded(
              child: Semantics(
                label: 'Graph canvas',
                child: GraphCanvas(
                  stubs: state.stubs,
                  currentNodeId: state.currentNodeId,
                  selectedId: state.selectedId,
                  onSelected: (id) =>
                      context.read<GraphBloc>().add(NodeSelected(id)),
                  onApproach: (id) =>
                      context.read<GraphBloc>().add(ApproachRequested(id)),
                ),
              ),
            ),
          ],
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
                  bloc.add(locked ? ApproachRequested(id) : NodeSelected(id));
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
    try {
      // Keeps the tab bar on Feed while the route below returns to it.
      context.read<ShellBloc>().add(const TabSelected(.feed));
    } on Exception {
      // Widget tests mount GraphView without the shell.
    }
    final story = widget.storyId.trim();
    try {
      AppNavigation.read(context).go(
        story.isEmpty
            ? AppRoutes.feed
            : AppRoutes.storyPath(Uri.encodeComponent(story)),
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

/// Stitch summary header: story-map eyebrow plus the story id and a
/// rewind action. No back button: tab navigation owns it.
class _MapHeader extends StatelessWidget {
  const _MapHeader({
    required this.storyId,
    required this.busy,
    required this.onRewind,
  });

  final String storyId;
  final bool busy;
  final VoidCallback onRewind;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        crossAxisAlignment: .start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: .start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.schema,
                      size: 14,
                      color: RamificaColors.onPrimaryContainer,
                      semanticLabel: 'Story map',
                    ),
                    SizedBox(width: 4),
                    Text(
                      'STORY MAP',
                      style: TextStyle(
                        fontFamily: RamificaText.sans,
                        fontWeight: FontWeight.w700,
                        fontSize: 10,
                        height: 14 / 10,
                        letterSpacing: 0.8,
                        color: RamificaColors.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  storyId,
                  maxLines: 1,
                  overflow: .ellipsis,
                  style: RamificaText.headlineSM,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _RewindPill(busy: busy, onRewind: onRewind),
        ],
      ),
    );
  }
}

class _RewindPill extends StatelessWidget {
  const _RewindPill({required this.busy, required this.onRewind});

  final bool busy;
  final VoidCallback onRewind;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: busy ? 0.5 : 1,
      child: InkWell(
        onTap: busy ? null : onRewind,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          decoration: BoxDecoration(
            color: RamificaColors.containerHigh,
            borderRadius: BorderRadius.circular(999),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: const Row(
            mainAxisSize: .min,
            children: [
              Icon(
                Icons.restart_alt,
                size: 16,
                color: RamificaColors.textSecondary,
                semanticLabel: 'Rewind',
              ),
              SizedBox(width: 4),
              Text('Rewind', style: RamificaText.labelSM),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stitch HUD strip, derived from stubs only: visited scenes, endings
/// found, and total progress with a static bar.
class _MapStats extends StatelessWidget {
  const _MapStats({required this.stubs});

  final List<GraphStub> stubs;

  @override
  Widget build(BuildContext context) {
    var visited = 0;
    var endings = 0;
    var foundEndings = 0;
    for (final stub in stubs) {
      if (stub.visited) visited++;
      if (stub.isEnding) {
        endings++;
        if (stub.visited) foundEndings++;
      }
    }
    final percent = stubs.isEmpty ? 0 : (visited / stubs.length * 100).round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: RamificaColors.containerLowest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: _StatCell(
                  value: '$visited/${stubs.length}',
                  valueColor: RamificaColors.onPrimaryContainer,
                  label: 'Scenes discovered',
                ),
              ),
              Expanded(
                child: _StatCell(
                  value: '$foundEndings/$endings',
                  valueColor: RamificaColors.rewardGold,
                  label: 'Endings found',
                  icon: Icons.emoji_events,
                ),
              ),
              Expanded(
                child: _StatCell(
                  value: '$percent%',
                  valueColor: RamificaColors.nodeActive,
                  label: 'Total progress',
                  progress: stubs.isEmpty ? 0 : visited / stubs.length,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.value,
    required this.valueColor,
    required this.label,
    this.icon,
    this.progress,
  });

  final String value;
  final Color valueColor;
  final String label;
  final IconData? icon;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: RamificaColors.containerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: .center,
            children: [
              Text(
                value,
                style: RamificaText.headlineSM.copyWith(color: valueColor),
              ),
              if (icon != null) ...[
                const SizedBox(width: 4),
                Icon(icon, size: 16, color: valueColor),
              ],
            ],
          ),
          if (progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: SizedBox(
                  height: 4,
                  width: double.infinity,
                  child: CustomPaint(painter: _ProgressBar(progress!)),
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.only(top: progress != null ? 4 : 2),
            child: Text(label, textAlign: .center, style: RamificaText.meta),
          ),
        ],
      ),
    );
  }
}

class _ProgressBar extends CustomPainter {
  const _ProgressBar(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = RamificaColors.containerHighest,
    );
    if (progress <= 0) return;
    canvas.drawRect(
      Offset.zero & Size(size.width * progress.clamp(0.0, 1.0), size.height),
      Paint()
        ..shader = const LinearGradient(
          colors: [RamificaColors.hotspot, RamificaColors.nodeActive],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_ProgressBar old) => old.progress != progress;
}
