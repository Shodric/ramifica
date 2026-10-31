import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/create_preview.dart';
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
            backgroundColor: RamificaColors.surface,
            appBar: AppBar(
              backgroundColor: RamificaColors.surface,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, size: 24),
                color: RamificaColors.textPrimary,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              titleSpacing: 0,
              title: Text('Create', style: RamificaText.headlineSM),
              actions: [
                IconButton(
                  key: ValueKey('preview-node-$nodeId'),
                  tooltip: 'Preview',
                  icon: const Icon(Icons.visibility, size: 22),
                  color: RamificaColors.nodeActive,
                  onPressed: busy
                      ? null
                      : () => showCreatePreview(context, node: node),
                ),
                IconButton(
                  key: ValueKey('save-node-$nodeId'),
                  tooltip: 'Save',
                  icon: const Icon(Icons.save, size: 22),
                  color: RamificaColors.textPrimary,
                  onPressed: busy ? null : () => bloc.add(const NodeSaved()),
                ),
              ],
            ),
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const .fromLTRB(16, 16, 16, 32),
                child: Column(
                  crossAxisAlignment: .stretch,
                  children: [
                    _BreadcrumbHud(
                      sceneNumber: number,
                      sceneTotal: state.nodes.length,
                      title: node.title,
                      status: state.statusOf(nodeId),
                    ),
                    const SizedBox(height: 24),
                    NodeInspector(
                      node: node,
                      missing: state.missingFor(node),
                      targetTitles: {
                        for (final choice in node.choices)
                          choice.choiceId: _targetTitle(
                            state.nodes,
                            state.story?.rootNodeId,
                            choice.targetNodeId,
                            scene,
                          ),
                      },
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
                      onTitleChanged: (value) => bloc.add(
                        NodeFieldChanged(nodeId: nodeId, title: value),
                      ),
                      onLineChanged: (value) => bloc.add(
                        NodeFieldChanged(nodeId: nodeId, ttsText: value),
                      ),
                      onChoiceLabelChanged: (choiceId, label) => bloc.add(
                        NodeFieldChanged(
                          nodeId: nodeId,
                          choiceLabels: {choiceId: label},
                        ),
                      ),
                      onChoiceIconChanged: (choiceId, icon) => bloc.add(
                        NodeFieldChanged(
                          nodeId: nodeId,
                          choiceIcons: {choiceId: icon},
                        ),
                      ),
                      onChoiceIconColorChanged: (choiceId, color) => bloc.add(
                        NodeFieldChanged(
                          nodeId: nodeId,
                          choiceIconColors: {choiceId: color},
                        ),
                      ),
                      onVisibilityChanged: (visibility) => bloc.add(
                        NodeFieldChanged(
                          nodeId: nodeId,
                          visibility: visibility,
                        ),
                      ),
                      onZoneMoved: (choiceId, x, y) => bloc.add(
                        ZoneMoved(
                          nodeId: nodeId,
                          choiceId: choiceId,
                          x: x,
                          y: y,
                        ),
                      ),
                      onZoneAdded: (targetNodeId) => bloc.add(
                        ChoiceAdded(nodeId: nodeId, targetNodeId: targetNodeId),
                      ),
                      onZoneRemoved: (choiceId) => bloc.add(
                        ChoiceRemoved(nodeId: nodeId, choiceId: choiceId),
                      ),
                      onZonesSaved: () => bloc.add(const ZonesSaved()),
                      onDelete: () => bloc.add(const NodeDeleted()),
                      deleteBlockedReason: state.deleteBlockReason(nodeId),
                      onPromptGenerate: (prompt) => bloc.add(
                        TextGenerateRequested(
                          prompt: prompt.isEmpty ? null : prompt,
                        ),
                      ),
                      onRegenerate: () => bloc.add(
                        const TextGenerateRequested(regenerate: true),
                      ),
                      onAddBranch: () =>
                          bloc.add(NodeAdded(parentNodeId: nodeId)),
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
                        NodeFieldChanged(
                          nodeId: nodeId,
                          lineApproved: approved,
                        ),
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
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Suite breadcrumb HUD: editing status row plus the scene title row.
/// `N of M` counts the draft scenes; the pill is display-only.
class _BreadcrumbHud extends StatelessWidget {
  const _BreadcrumbHud({
    required this.sceneNumber,
    required this.sceneTotal,
    required this.title,
    required this.status,
  });

  final int sceneNumber;
  final int sceneTotal;
  final String title;
  final StatusPillState status;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: RamificaColors.hotspot,
                boxShadow: [
                  BoxShadow(color: RamificaColors.glowCyan, blurRadius: 8),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'SCENE $sceneNumber EDITING',
                style: RamificaText.labelSM.copyWith(
                  fontSize: 10,
                  fontWeight: .w700,
                  letterSpacing: 0.5,
                  color: RamificaColors.hotspot,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: RamificaColors.containerHigh,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: .min,
                children: [
                  const Icon(
                    Icons.edit_note,
                    size: 13,
                    color: RamificaColors.rewardGold,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Draft Mode',
                    style: RamificaText.labelSM.copyWith(
                      fontSize: 10,
                      color: RamificaColors.rewardGold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: .baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                title.isEmpty
                    ? 'Scene $sceneNumber'
                    : 'Scene $sceneNumber: $title',
                style: RamificaText.headlineSM.copyWith(
                  fontSize: 18,
                  height: 24 / 18,
                  fontWeight: .w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$sceneNumber of $sceneTotal',
              style: RamificaText.labelSM.copyWith(
                fontSize: 10,
                color: RamificaColors.textSecondary,
              ),
            ),
            const SizedBox(width: 8),
            StatusPill(status: status),
          ],
        ),
      ],
    );
  }
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

/// Full `Scene M (Title)` destination for the suite decision cards.
/// Falls back to the bare scene label when the title is missing.
String _targetTitle(
  List<DraftNode> nodes,
  String? rootNodeId,
  String targetId,
  Map<String, int> scenes,
) {
  final number = scenes[targetId];
  if (number == null) return 'Scene —';
  var title = '';
  for (final node in nodes) {
    if (node.nodeId == targetId) {
      title = node.title.trim();
      break;
    }
  }
  if (title.isEmpty) return 'Scene $number';
  return 'Scene $number ($title)';
}
