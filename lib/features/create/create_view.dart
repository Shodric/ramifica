import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/app/navigation.dart';
import 'package:ramifica/app/routes.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/core/widgets/not_found_view.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/data/repositories/firebase_auth_gateway.dart';
import 'package:ramifica/features/create/canvas_controls.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/creation_card.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:ramifica/features/create/draft_canvas.dart';
import 'package:ramifica/features/create/create_node_screen.dart';
import 'package:ramifica/features/create/story_settings.dart';
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
    this.pickImage,
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

  /// Picks a reference still for the Scenes step. Injected for tests;
  /// production wires the browser picker. Null hides the reference
  /// upload button.
  final PickImageFile? pickImage;

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
  var _pendingPush = false;
  String? _pendingOpenStory;
  String? _routeStoryId;

  /// The last story the canvas centered on by itself. Entering a draft
  /// with a tree (e.g. a `/create/:id` deep link) recenters once on
  /// arrival; later edits keep the author's pan.
  String? _centeredStoryId;
  final _canvasKey = GlobalKey();

  /// Deep links like `/create/<id>` open that creation directly. Runs on
  /// route changes only (never on bloc state changes), and once per id,
  /// so a failed open does not retry itself into a loop.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    String? routed;
    try {
      final location = AppNavigation.read(context).location;
      if (location is CreateCanvasLocation) routed = location.storyId;
    } on FlutterError {
      routed = null;
    }
    final bloc = _bloc;
    if (bloc == null) return;
    if (routed == null || routed.isEmpty) {
      _routeStoryId = null;
      return;
    }
    if (routed == _routeStoryId) return;
    if (bloc.state.story?.storyId == routed) {
      _routeStoryId = routed;
      return;
    }
    _routeStoryId = routed;
    bloc.add(DraftOpened(routed));
  }

  @override
  void initState() {
    super.initState();
    _canvasController = TransformationController()..addListener(_syncZoom);
    if (widget.bloc != null) {
      _bloc = widget.bloc;
      return;
    }
    try {
      final repository = widget.repository ?? createFirebaseCreateRepository();
      final publisher = repository.publisher;
      if (publisher == null) {
        throw StateError('Create publisher is not configured.');
      }
      _bloc = CreateBloc(
        repository: repository,
        drafts: repository.persistence,
        publisher: publisher,
        auth: widget.authRepository ?? createFirebaseAuthRepository(),
      );
      _bloc!.add(const StoriesRequested());
    } catch (_) {
      _bloc = null;
    }
  }

  @override
  void dispose() {
    _canvasController.dispose();
    super.dispose();
  }

  /// Visible canvas scale from the x/y axes only. `getMaxScaleOnAxis`
  /// always reads >= 1 here because the untouched z axis stays at 1, which
  /// froze the zoom label and defeated the min-scale clamp.
  double _canvasScale() {
    final value = _canvasController.value;
    return math.max(value.getColumn(0).length, value.getColumn(1).length);
  }

  void _syncZoom() {
    final zoom = _canvasScale().clamp(0.25, 1.0);
    if (zoom != _zoom) setState(() => _zoom = zoom);
  }

  void _zoomBy(double factor) {
    final current = _canvasScale();
    final zoom = (current * factor).clamp(0.25, 1.0);
    final actual = zoom / current;
    if (actual == 1) return;
    _canvasController.value = Matrix4.copy(_canvasController.value)
      ..multiply(Matrix4.diagonal3Values(actual, actual, 1));
  }

  /// Middle zoom segment: back to 100%, keeping the current pan.
  void _resetZoom() {
    final current = _canvasScale();
    if (current == 1) return;
    _zoomBy(1 / current);
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

  /// The creation id on `/create/<id>`, or null on the list, on
  /// `/create/new-creation`, and on bare widget mounts.
  String? _routedStoryId(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<AppNavigation>();
    try {
      final location = AppNavigation.read(context).location;
      if (location is CreateCanvasLocation) return location.storyId;
    } on FlutterError {
      return null;
    }
    return null;
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
          pickImage: widget.pickImage,
        ),
      ),
    );
  }

  /// Opens a creation from the list on its own `/create/:id` route:
  /// navigates at once when it is the open story, otherwise loads it first
  /// and navigates on arrival (see the pending-open listener) so the
  /// canvas never mounts empty. `/create/new-creation` stays for new
  /// drafts only.
  void _openStory(BuildContext context, CreateBloc bloc, String storyId) {
    if (bloc.state.story?.storyId == storyId) {
      _go(context, AppRoutes.createFor(storyId));
      return;
    }
    _pendingOpenStory = storyId;
    bloc.add(DraftOpened(storyId));
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
    final list = !_isCanvasRoute(context);
    return BlocProvider.value(
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
              previous.deletedStoryId != next.deletedStoryId &&
              next.deletedStoryId != null,
          listener: (context, state) {
            if (state.deletedStoryId == null) return;
            try {
              AppNavigation.read(context).go(AppRoutes.create);
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
            child: BlocListener<CreateBloc, CreateState>(
              listenWhen: (previous, next) =>
                  _pendingOpenStory != null &&
                  next.story?.storyId == _pendingOpenStory &&
                  next.job == CreateJob.none,
              listener: (context, state) {
                final opened = _pendingOpenStory;
                _pendingOpenStory = null;
                if (state.failure != null || opened == null) return;
                _go(context, AppRoutes.createFor(opened));
              },
              child: BlocListener<CreateBloc, CreateState>(
                // A newly arrived story with a tree centers the canvas on
                // its root, like the recenter button. Fires once per story:
                // node edits and same-story reloads keep the author's pan.
                listenWhen: (previous, next) {
                  final id = next.story?.storyId;
                  return id != null &&
                      next.nodes.isNotEmpty &&
                      id != _centeredStoryId;
                },
                listener: (context, state) {
                  final id = state.story?.storyId;
                  if (id == null ||
                      state.nodes.isEmpty ||
                      id == _centeredStoryId) {
                    return;
                  }
                  _centeredStoryId = id;
                  // The canvas needs a laid-out viewport to center on, so
                  // this runs after the frame that draws the arrived tree.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    _recenter(context, state);
                  });
                },
                child: Scaffold(
                  appBar: list
                      ? AppBar(
                          backgroundColor: RamificaColors.surface,
                          surfaceTintColor: Colors.transparent,
                          elevation: 0,
                          title: Text('Create', style: RamificaText.headlineSM),
                          actions: [
                            IconButton(
                              key: const ValueKey('create-new'),
                              tooltip: 'New creation',
                              icon: const Icon(Icons.add, size: 24),
                              color: RamificaColors.nodeActive,
                              onPressed: () {
                                bloc.add(const DraftRequested());
                                _go(context, AppRoutes.createNew);
                              },
                            ),
                          ],
                        )
                      : null,
                  body: SafeArea(
                    child: BlocBuilder<CreateBloc, CreateState>(
                      builder: (context, state) => _body(context, state),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Creations list (the Create tab root): every own story as a card with
  /// cover, title, description, counts, and status, newest first. Tapping
  /// one opens it on the canvas; the AppBar + starts a new draft. Empty
  /// only while the author owns nothing.
  Widget _creations(BuildContext context, CreateState state, CreateBloc bloc) {
    if (state.stories.isEmpty) {
      return Padding(
        padding: const .all(16),
        child: Column(
          crossAxisAlignment: .stretch,
          children: [
            if (state.failure != null) FailureText(message: state.failure!),
            Expanded(
              child: Center(
                child: EmptyState(
                  message: 'Your drafts live here.',
                  actionLabel: 'Start a draft',
                  onAction: () {
                    bloc.add(const DraftRequested());
                    _go(context, AppRoutes.createNew);
                  },
                ),
              ),
            ),
          ],
        ),
      );
    }
    // The page padding lives on the scrollable itself, so the scrollbar
    // travels over padding instead of content and the extreme cards keep
    // their borders clear of the viewport edges.
    return Column(
      crossAxisAlignment: .stretch,
      children: [
        if (state.failure != null)
          Padding(
            padding: const .fromLTRB(16, 16, 16, 0),
            child: FailureText(message: state.failure!),
          ),
        Expanded(
          child: ListView.separated(
            padding: const .all(16),
            itemCount: state.stories.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final story = state.stories[index];
              final open = story.storyId == state.story?.storyId;
              // The open draft counts live nodes so the card stays
              // truthful while editing; the rest show the listed counts.
              final live = open ? state.nodes : null;
              return CreationCard(
                story: story,
                nodeCount: live?.length ?? story.nodeCount,
                endingCount:
                    live?.where((node) => node.isEnding).length ??
                    story.endingCount,
                isOpen: open,
                onTap: () => _openStory(context, bloc, story.storyId),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, CreateState state) {
    final bloc = context.read<CreateBloc>();
    final canvas = _isCanvasRoute(context);
    if (!canvas) return _creations(context, state, bloc);
    if (!state.hasDraft) {
      final routed = _routedStoryId(context);
      final deepLink = routed != null && routed.isNotEmpty;
      if (deepLink && state.missing) return const NotFoundView();
      if (deepLink && state.job == CreateJob.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return Padding(
        padding: const .all(16),
        child: Column(
          crossAxisAlignment: .stretch,
          children: [
            const Text('Create', style: RamificaText.screenTitle),
            if (state.failure != null) FailureText(message: state.failure!),
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
    final problems = state.publishProblems();
    return Padding(
      padding: const .all(16),
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          CreateRibbon(
            title: state.story?.title ?? '',
            onSettings: () => showStorySettings(context),
            onPublish: state.job == CreateJob.none
                ? () => bloc.add(const StoryPublished())
                : null,
            canPublish: state.job == CreateJob.none && problems.isEmpty,
            showPublish: state.story?.status != 'published',
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
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: CanvasRecenterButton(
                      onRecenter: () => _recenter(context, state),
                    ),
                  ),
                  Positioned(
                    bottom: 12,
                    right: 12,
                    child: CanvasZoomControls(
                      zoom: _zoom,
                      onZoomIn: _zoom >= 1 ? null : () => _zoomBy(1.2),
                      onZoomOut: _zoom <= 0.25 ? null : () => _zoomBy(1 / 1.2),
                      onZoomReset: _resetZoom,
                    ),
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
