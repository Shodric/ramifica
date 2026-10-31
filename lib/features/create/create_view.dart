import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/data/repositories/firebase_auth_gateway.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:ramifica/features/create/draft_canvas.dart';
import 'package:ramifica/features/create/create_node_screen.dart';
import 'package:ramifica/features/create/create_preview.dart';
import 'package:ramifica/features/create/create_ribbon.dart';
import 'package:uuid/uuid.dart';

/// Create tab: draft canvas plus the inspector. Creates its own bloc
/// like Explore; tests inject [bloc] and read recorded events instead of
/// touching Firebase.
class CreateView extends StatefulWidget {
  const CreateView({
    super.key,
    this.bloc,
    this.repository,
    this.authRepository,
    this.pickVideo,
    this.newTakeId = _defaultTakeId,
    this.onPublished,
  });

  /// Fires once with the story id when `publishStory` succeeds. Tests
  /// inject this and assert navigation; production leaves it null and the
  /// view routes to Explore through [AppNavigation] instead.
  final void Function(String storyId)? onPublished;

  final CreateBloc? bloc;
  final CreateRepository? repository;
  final AuthRepository? authRepository;

  /// Picks a video file for upload. Injected for tests; production wires a
  /// picker plugin. Null hides the upload button (see [NodeInspector]).
  final PickVideoFile? pickVideo;

  /// Mints the take nonce echoed by the trigger as `uploadTakeId`, so the
  /// bloc can tell its own trigger write apart from pre-trigger state.
  /// Injected for tests; defaults to a uuid.
  final String Function() newTakeId;

  @override
  State<CreateView> createState() => _CreateViewState();
}

class _CreateViewState extends State<CreateView> {
  CreateBloc? _bloc;
  late final TransformationController _canvasController;
  double _zoom = 1;
  var _rootMode = false;
  var _pendingPush = false;
  final _canvasKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _canvasController = TransformationController()..addListener(_syncZoom);
    if (widget.bloc != null) {
      _bloc = widget.bloc;
      return;
    }
    try {
      _bloc = CreateBloc(
        repository: widget.repository ?? createFirebaseCreateRepository(),
        auth: widget.authRepository ?? createFirebaseAuthRepository(),
      );
    } catch (_) {
      _bloc = null;
    }
  }

  @override
  void dispose() {
    _canvasController.dispose();
    super.dispose();
  }

  void _syncZoom() {
    final zoom = _canvasController.value.getMaxScaleOnAxis().clamp(0.25, 1.0);
    if (zoom != _zoom) setState(() => _zoom = zoom);
  }

  void _zoomBy(double factor) {
    final current = _canvasController.value.getMaxScaleOnAxis();
    final zoom = (current * factor).clamp(0.25, 1.0);
    final actual = zoom / current;
    if (actual == 1) return;
    _canvasController.value = Matrix4.copy(_canvasController.value)
      ..multiply(Matrix4.diagonal3Values(actual, actual, 1));
  }

  /// Pans (at 1x) so the root node lands centered in the viewport — the
  /// focus button always returns to the story root, never to a corner.
  void _recenter(BuildContext context, CreateState state) {
    final story = state.story;
    final viewport = _canvasKey.currentContext?.size;
    Offset? center;
    if (story != null) {
      final layout = layoutDraft(state.nodes, rootNodeId: story.rootNodeId);
      center = layout.positions[story.rootNodeId];
    }
    _canvasController.value = recenterTransform(viewport, center);
  }

  /// True on the fullscreen canvas route — or on bare mounts: widget tests
  /// run CreateView without a router and exercise the canvas directly.
  bool _isCanvasRoute(BuildContext context) {
    // Subscribe so route pushes rebuild the view; the read below tolerates
    // bare mounts (widget tests run CreateView without a router).
    context.dependOnInheritedWidgetOfExactType<AppNavigation>();
    try {
      return AppNavigation.read(context).location is CreateCanvasLocation;
    } on FlutterError {
      return true;
    }
  }

  /// Router navigation that tolerates bare mounts (widget tests run the
  /// view without AppNavigation, like the published-story redirect above).
  void _go(BuildContext context, String path) {
    try {
      AppNavigation.read(context).go(path);
    } on FlutterError {
      // Widget tests mount CreateView without the router.
    }
  }

  /// Selects the node and enters its fullscreen editor.
  void _openNode(BuildContext context, CreateBloc bloc, String nodeId) {
    bloc.add(NodeSelected(nodeId));
    _pushNode(context, bloc, nodeId);
  }

  /// Adds a child under [parentId] on [slot], then enters it once the save
  /// lands. A null slot falls back to the first free one (HUD next-scene).
  void _addAndOpen(CreateBloc bloc, String parentId, [String? slot]) {
    _pendingPush = true;
    bloc.add(NodeAdded(parentNodeId: parentId, slot: slot));
  }

  void _pushNode(BuildContext context, CreateBloc bloc, String nodeId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CreateNodeScreen(
          bloc: bloc,
          nodeId: nodeId,
          pickVideo: widget.pickVideo,
          newTakeId: widget.newTakeId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bloc = _bloc;
    if (bloc == null) {
      return const Scaffold(
        body: SafeArea(
          child: Center(
            child: EmptyState(message: 'Create is unavailable right now.'),
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: BlocProvider.value(
          value: bloc,
          child: BlocListener<CreateBloc, CreateState>(
            listenWhen: (previous, next) =>
                previous.publishedStoryId != next.publishedStoryId &&
                next.publishedStoryId != null,
            listener: (context, state) {
              final storyId = state.publishedStoryId;
              if (storyId == null) return;
              final open = widget.onPublished;
              if (open != null) {
                open(storyId);
                return;
              }
              try {
                AppNavigation.read(context).go(AppRoutes.explore);
              } on FlutterError {
                // Widget tests mount CreateView without the router.
              }
            },
            child: BlocListener<CreateBloc, CreateState>(
              listenWhen: (previous, next) =>
                  _pendingPush &&
                  previous.job != CreateJob.none &&
                  next.job == CreateJob.none,
              listener: (context, state) {
                _pendingPush = false;
                if (state.failure != null) return;
                final openId = state.openNodeId;
                if (openId == null) return;
                final bloc = context.read<CreateBloc>();
                _pushNode(context, bloc, openId);
              },
              child: BlocBuilder<CreateBloc, CreateState>(
                builder: (context, state) => _body(context, state),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, CreateState state) {
    final bloc = context.read<CreateBloc>();
    final canvas = _isCanvasRoute(context);
    if (!state.hasDraft) {
      return Padding(
        padding: const .all(16),
        child: Column(
          crossAxisAlignment: .stretch,
          children: [
            const Text('Create', style: RamificaText.screenTitle),
            Expanded(
              child: Center(
                child: EmptyState(
                  message: 'Your drafts live here.',
                  actionLabel: 'Start a draft',
                  onAction: () {
                    bloc.add(const DraftRequested());
                    if (!canvas) _go(context, AppRoutes.createNew);
                  },
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (!canvas) {
      return Padding(
        padding: const .all(16),
        child: Column(
          crossAxisAlignment: .stretch,
          children: [
            const Text('Create', style: RamificaText.screenTitle),
            Expanded(
              child: Center(
                child: EmptyState(
                  message: 'Draft in progress.',
                  actionLabel: 'Continue draft',
                  onAction: () => _go(context, AppRoutes.createNew),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final problems = state.publishProblems();
    return Padding(
      padding: const .all(16),
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          CreateRibbon(
            title: state.story?.title ?? '',
            rootMode: _rootMode,
            onModeChanged: (mode) => setState(() => _rootMode = mode),
            zoom: _zoom,
            onZoomIn: () => _zoomBy(1.2),
            onZoomOut: () => _zoomBy(1 / 1.2),
            onRecenter: () => _recenter(context, state),
            onSimulate: () => showCreatePreview(context, node: state.openNode),
            onPublish: state.job == CreateJob.none
                ? () => bloc.add(const StoryPublished())
                : null,
            canPublish: state.job == CreateJob.none && problems.isEmpty,
            onClose: () => _go(context, AppRoutes.create),
          ),
          const SizedBox(height: 12),
          if (state.failure != null) ...[
            FailureText(message: state.failure!),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: Container(
              key: _canvasKey,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: RamificaLayout.cardBorderRadius,
                border: Border.all(color: RamificaColors.outlineVariant),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CanvasViewportGrid(controller: _canvasController),
                  ),
                  DraftCanvas(
                    nodes: state.nodes,
                    orphans: state.orphanNodeIds,
                    openNodeId: state.openNodeId,
                    rootNodeId: state.story?.rootNodeId,
                    onSelect: (id) => _openNode(context, bloc, id),
                    onAdd: (parentId, slot) =>
                        _addAndOpen(bloc, parentId, slot),
                    transformationController: _canvasController,
                    rootMode: _rootMode,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _defaultTakeId() => const Uuid().v4();
