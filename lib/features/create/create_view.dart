import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/failure_text.dart';
import 'package:ramifica/data/repositories/auth_repository.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/data/repositories/firebase_auth_gateway.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:ramifica/features/create/draft_canvas.dart';
import 'package:ramifica/features/create/node_inspector.dart';
import 'package:ramifica/features/create/publish_bar.dart';
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
  });

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

  @override
  void initState() {
    super.initState();
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
          child: BlocBuilder<CreateBloc, CreateState>(
            builder: (context, state) => _body(context, state),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, CreateState state) {
    final bloc = context.read<CreateBloc>();
    return Padding(
      padding: const .all(16),
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          Row(
            children: [
              const Text('Create', style: RamificaText.screenTitle),
              const Spacer(),
              if (state.hasDraft && state.openNode != null)
                OutlinedButton(
                  onPressed: state.job == CreateJob.none
                      ? () => bloc.add(const NodeAdded())
                      : null,
                  child: const Text('Add node'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (state.failure != null) ...[
            FailureText(message: state.failure!),
            const SizedBox(height: 12),
          ],
          if (!state.hasDraft)
            Expanded(
              child: Center(
                child: EmptyState(
                  message: 'Your drafts live here.',
                  actionLabel: 'Start a draft',
                  onAction: () => bloc.add(const DraftRequested()),
                ),
              ),
            )
          else ...[
            Expanded(
              flex: 2,
              child: DraftCanvas(
                nodes: state.nodes,
                orphans: state.orphanNodeIds,
                openNodeId: state.openNodeId,
                rootNodeId: state.story?.rootNodeId,
                onSelect: (id) => bloc.add(NodeSelected(id)),
              ),
            ),
            const SizedBox(height: 12),
            if (state.openNode != null)
              Flexible(
                flex: 3,
                child: SingleChildScrollView(
                  child: NodeInspector(
                    node: state.openNode!,
                    status: state.statusOf(state.openNodeId!),
                    missing: state.missingFor(state.openNode!),
                    busy:
                        state.job == CreateJob.saving ||
                        state.job == CreateJob.generating ||
                        state.job == CreateJob.imaging ||
                        state.job == CreateJob.uploading,
                    isRoot: state.isRoot(state.openNodeId!),
                    parent: state.parentOf(state.openNode!),
                    targets: [
                      for (final node in state.nodes)
                        if (node.nodeId != state.openNodeId) node,
                    ],
                    videoGateMessage: state.videoGateMessage(state.openNode!),
                    videoDesynced: state.videoDesynced(state.openNode!),
                    uploadProgress:
                        state.job == CreateJob.uploading &&
                            state.jobNodeId == state.openNodeId
                        ? state.uploadProgress
                        : null,
                    onTitleChanged: (value) => bloc.add(
                      NodeFieldChanged(nodeId: state.openNodeId!, title: value),
                    ),
                    onLineChanged: (value) => bloc.add(
                      NodeFieldChanged(
                        nodeId: state.openNodeId!,
                        ttsText: value,
                      ),
                    ),
                    onChoiceLabelChanged: (choiceId, label) => bloc.add(
                      NodeFieldChanged(
                        nodeId: state.openNodeId!,
                        choiceLabels: {choiceId: label},
                      ),
                    ),
                    onVisibilityChanged: (visibility) => bloc.add(
                      NodeFieldChanged(
                        nodeId: state.openNodeId!,
                        visibility: visibility,
                      ),
                    ),
                    onWindowChanged: (window) => bloc.add(
                      NodeFieldChanged(
                        nodeId: state.openNodeId!,
                        windowSeconds: window,
                      ),
                    ),
                    onZoneMoved: (choiceId, x, y) => bloc.add(
                      ZoneMoved(
                        nodeId: state.openNodeId!,
                        choiceId: choiceId,
                        x: x,
                        y: y,
                      ),
                    ),
                    onZoneAdded: (targetNodeId) => bloc.add(
                      ChoiceAdded(
                        nodeId: state.openNodeId!,
                        targetNodeId: targetNodeId,
                      ),
                    ),
                    onZoneRemoved: (choiceId) => bloc.add(
                      ChoiceRemoved(
                        nodeId: state.openNodeId!,
                        choiceId: choiceId,
                      ),
                    ),
                    onZonesSaved: () => bloc.add(const ZonesSaved()),
                    onWindowSaved: () => bloc.add(const WindowSaved()),
                    onSave: () => bloc.add(const NodeSaved()),
                    onGenerate: () => bloc.add(const TextGenerateRequested()),
                    onRegenerate: () =>
                        bloc.add(const TextGenerateRequested(regenerate: true)),
                    onImageApprovalChanged: (which, approved) => bloc.add(
                      ImageApprovalChanged(
                        nodeId: state.openNodeId!,
                        which: which,
                        approved: approved,
                      ),
                    ),
                    onImageGenerate: (which) => bloc.add(
                      ImageGenerateRequested(
                        nodeId: state.openNodeId!,
                        which: which,
                      ),
                    ),
                    onVideoGenerate: () =>
                        bloc.add(VideoGenerateRequested(state.openNodeId!)),
                    onLineApprovalChanged: (approved) => bloc.add(
                      NodeFieldChanged(
                        nodeId: state.openNodeId!,
                        lineApproved: approved,
                      ),
                    ),
                    onVoiceGenerate: () =>
                        bloc.add(VoiceGenerateRequested(state.openNodeId!)),
                    onVoiceApprovalChanged: (approved) => bloc.add(
                      NodeFieldChanged(
                        nodeId: state.openNodeId!,
                        ttsApproved: approved,
                      ),
                    ),
                    onUploadVideo: widget.pickVideo == null
                        ? null
                        : () async {
                            final picked = await widget.pickVideo!();
                            if (picked == null) return;
                            if (!context.mounted) return;
                            bloc.add(
                              VideoUploadRequested(
                                nodeId: state.openNodeId!,
                                contentType: picked.contentType,
                                bytes: picked.bytes,
                                takeId: widget.newTakeId(),
                              ),
                            );
                          },
                  ),
                ),
              ),
            if (state.hasDraft) ...[
              const SizedBox(height: 12),
              PublishBar(
                problems: state.publishProblems(),
                // #51 owns the real publish call: for now the CTA only
                // reports readiness, touching nothing.
                onPublish: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Story is ready. Publishing lands in #51.',
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
        ],
      ),
    );
  }
}

String _defaultTakeId() => const Uuid().v4();
