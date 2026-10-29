import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_state.dart';
import 'package:ramifica/features/create/draft_canvas.dart';
import 'package:ramifica/features/create/node_inspector.dart';

/// Fullscreen node editor: one node, its inspector, nothing else. Pushed
/// over the canvas when the author taps a card (or creates through a `+`
/// mini); the back button returns to the canvas. The canvas owns selection
/// state — this screen only edits the node it was opened with. If the node
/// disappears (deleted), the screen pops itself.
class CreateNodeScreen extends StatelessWidget {
  const CreateNodeScreen({
    super.key,
    required this.bloc,
    required this.nodeId,
    required this.pickVideo,
    required this.newTakeId,
  });

  final CreateBloc bloc;
  final String nodeId;
  final PickVideoFile? pickVideo;
  final String Function() newTakeId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: bloc,
      child: BlocBuilder<CreateBloc, CreateState>(
        builder: (context, state) {
          final scene = sceneIndexes(state.nodes, state.story?.rootNodeId);
          final number = scene[nodeId];
          if (number == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) Navigator.of(context).maybePop();
            });
            return const Scaffold(body: SizedBox.shrink());
          }
          final node = state.nodes.firstWhere((n) => n.nodeId == nodeId);
          final busy =
              state.job == CreateJob.saving ||
              state.job == CreateJob.generating ||
              state.job == CreateJob.imaging ||
              state.job == CreateJob.uploading;
          return Scaffold(
            appBar: AppBar(),
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const .all(16),
                child: NodeInspector(
                  node: node,
                  status: state.statusOf(nodeId),
                  missing: state.missingFor(node),
                  headline: _titleFor(
                    state.nodes,
                    state.story?.rootNodeId,
                    nodeId,
                    number,
                  ),
                  choiceTargets: {
                    for (final choice in node.choices)
                      choice.choiceId: _targetLabel(
                        state.nodes,
                        state.story?.rootNodeId,
                        choice.targetNodeId,
                      ),
                  },
                  busy: busy,
                  isRoot: state.isRoot(nodeId),
                  parent: state.parentOf(node),
                  targets: [
                    for (final candidate in state.nodes)
                      if (candidate.nodeId != nodeId) candidate,
                  ],
                  videoGateMessage: state.videoGateMessage(node),
                  videoDesynced: state.videoDesynced(node),
                  uploadProgress:
                      state.job == CreateJob.uploading &&
                          state.jobNodeId == nodeId
                      ? state.uploadProgress
                      : null,
                  onTitleChanged: (value) =>
                      bloc.add(NodeFieldChanged(nodeId: nodeId, title: value)),
                  onLineChanged: (value) => bloc.add(
                    NodeFieldChanged(nodeId: nodeId, ttsText: value),
                  ),
                  onChoiceLabelChanged: (choiceId, label) => bloc.add(
                    NodeFieldChanged(
                      nodeId: nodeId,
                      choiceLabels: {choiceId: label},
                    ),
                  ),
                  onVisibilityChanged: (visibility) => bloc.add(
                    NodeFieldChanged(nodeId: nodeId, visibility: visibility),
                  ),
                  onZoneMoved: (choiceId, x, y) => bloc.add(
                    ZoneMoved(nodeId: nodeId, choiceId: choiceId, x: x, y: y),
                  ),
                  onZoneAdded: (targetNodeId) => bloc.add(
                    ChoiceAdded(nodeId: nodeId, targetNodeId: targetNodeId),
                  ),
                  onZoneRemoved: (choiceId) => bloc.add(
                    ChoiceRemoved(nodeId: nodeId, choiceId: choiceId),
                  ),
                  onZonesSaved: () => bloc.add(const ZonesSaved()),
                  onSave: () => bloc.add(const NodeSaved()),
                  onDelete: () => bloc.add(const NodeDeleted()),
                  deleteBlockedReason: state.deleteBlockReason(nodeId),
                  onGenerate: () => bloc.add(const TextGenerateRequested()),
                  onRegenerate: () =>
                      bloc.add(const TextGenerateRequested(regenerate: true)),
                  onImageApprovalChanged: (which, approved) => bloc.add(
                    ImageApprovalChanged(
                      nodeId: nodeId,
                      which: which,
                      approved: approved,
                    ),
                  ),
                  onImageGenerate: (which) => bloc.add(
                    ImageGenerateRequested(nodeId: nodeId, which: which),
                  ),
                  onVideoGenerate: () =>
                      bloc.add(VideoGenerateRequested(nodeId)),
                  onLineApprovalChanged: (approved) => bloc.add(
                    NodeFieldChanged(nodeId: nodeId, lineApproved: approved),
                  ),
                  onVoiceGenerate: () =>
                      bloc.add(VoiceGenerateRequested(nodeId)),
                  onVoiceApprovalChanged: (approved) => bloc.add(
                    NodeFieldChanged(nodeId: nodeId, ttsApproved: approved),
                  ),
                  onUploadVideo: pickVideo == null
                      ? null
                      : () async {
                          final picked = await pickVideo!();
                          if (picked == null) return;
                          if (!context.mounted) return;
                          bloc.add(
                            VideoUploadRequested(
                              nodeId: nodeId,
                              contentType: picked.contentType,
                              bytes: picked.bytes,
                              takeId: newTakeId(),
                            ),
                          );
                        },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Editor title with the branch path (`Scene 3 - ABA`), mirroring the
/// canvas card labels. Empty path shows the plain `Scene N`.
String _titleFor(
  List<DraftNode> nodes,
  String? rootNodeId,
  String nodeId,
  int number,
) {
  final path = slotPaths(nodes, rootNodeId)[nodeId] ?? '';
  if (path.isEmpty) return 'Scene $number';
  return 'Scene $number - $path';
}

/// `Scene M` label pointing at a choice target. Numbers only, no titles:
/// titles already show in the editable choice fields.
String _targetLabel(
  List<DraftNode> nodes,
  String? rootNodeId,
  String targetId,
) {
  final number = sceneIndexes(nodes, rootNodeId)[targetId];
  if (number == null) return 'Scene —';
  return 'Scene $number';
}
