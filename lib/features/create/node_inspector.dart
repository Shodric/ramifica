import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/choice_icon.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/frame_compare.dart';
import 'package:ramifica/features/create/voice_preview.dart';
import 'package:ramifica/features/create/zone_marker.dart';

/// Inspector for the open draft node: manual editing fields, the
/// per-node [StatusPill], and what is missing for publish.
///
/// Manual editing is the point. Every keystroke writes bloc state through
/// the callbacks; the node saves from the screen app bar. Controllers
/// resync from [node] only when the text differs (a proposal or a
/// reload), so typing never loses its caret: the bloc echoes each
/// keystroke back unchanged.
class NodeInspector extends StatefulWidget {
  const NodeInspector({
    super.key,
    required this.node,
    required this.missing,
    this.busy = false,
    this.onPromptGenerate,
    this.choiceTargets = const {},
    this.targetTitles = const {},
    this.onAddBranch,
    this.isRoot = false,
    this.parent,
    this.targets = const [],
    this.videoGateMessage,
    this.videoDesynced = false,
    this.onTitleChanged,
    this.onLineChanged,
    this.onChoiceLabelChanged,
    this.onChoiceIconChanged,
    this.onChoiceIconColorChanged,
    this.onVisibilityChanged,
    this.onZoneMoved,
    this.onZoneAdded,
    this.onZoneRemoved,
    this.onZonesSaved,
    this.onDelete,
    this.deleteBlockedReason,
    this.onRegenerate,
    this.onImageApprovalChanged,
    this.onImageGenerate,
    this.onVideoGenerate,
    this.onLineApprovalChanged,
    this.onVoiceGenerate,
    this.onVoiceApprovalChanged,
    this.onUploadVideo,
    this.uploadProgress,
  });
  final DraftNode node;
  final List<String> missing;

  /// `Scene M` label per choice id for the decision cards.
  final Map<String, String> choiceTargets;

  /// Full `Scene M (Title)` target per choice id for the decision cards.
  /// Falls back to [choiceTargets] when a choice is missing here.
  final Map<String, String> targetTitles;

  /// Adds a child under the open node, then lets the author open it from
  /// the canvas. Null hides the action.
  final VoidCallback? onAddBranch;

  /// A save or generation is in flight: fields and buttons disable.
  final bool busy;

  /// True for the draft root. Only the root shows S frame controls;
  /// other nodes inherit S from their parent E.
  final bool isRoot;

  /// The node this one inherits its S from, if any. Supplies the S
  /// preview on non-root nodes.
  final DraftNode? parent;

  /// Every node but the open one: candidates a new zone may point at.
  final List<DraftNode> targets;

  /// Why video generation is gated, or null when the gate is open.
  final String? videoGateMessage;

  /// True when this node's video is stale (parent E regenerated).
  final bool videoDesynced;

  final ValueChanged<String>? onTitleChanged;
  final ValueChanged<String>? onLineChanged;
  final void Function(String choiceId, String label)? onChoiceLabelChanged;
  final void Function(String choiceId, String icon)? onChoiceIconChanged;
  final void Function(String choiceId, String color)? onChoiceIconColorChanged;
  final ValueChanged<String>? onVisibilityChanged;
  final void Function(String choiceId, double x, double y)? onZoneMoved;
  final ValueChanged<String>? onZoneAdded;
  final ValueChanged<String>? onZoneRemoved;
  final VoidCallback? onZonesSaved;

  /// Deletes the open node. Null while no draft guards apply — always set
  /// by the view; null only in bare widget tests.
  final VoidCallback? onDelete;

  /// Why the open node cannot be deleted, or null when it can go. Non-null
  /// disables the delete button with this reason.
  final String? deleteBlockedReason;

  /// Prompt-driven generation: the AI card sends its textarea text (empty
  /// means unguided, like the old bare generate). Null hides the CTA.
  final ValueChanged<String>? onPromptGenerate;
  final VoidCallback? onRegenerate;

  final void Function(String which, bool approved)? onImageApprovalChanged;

  /// Frame generation request: `which` is `start` or `end`.
  final ValueChanged<String>? onImageGenerate;

  final VoidCallback? onVideoGenerate;
  final ValueChanged<bool>? onLineApprovalChanged;
  final VoidCallback? onVoiceGenerate;
  final ValueChanged<bool>? onVoiceApprovalChanged;

  /// Upload tap for a picked mp4/mov. Null when no picker is wired, in
  final VoidCallback? onUploadVideo;

  /// Upload progress 0..1 for this node, or null when not uploading.
  final double? uploadProgress;
  @override
  State<NodeInspector> createState() => _NodeInspectorState();
}

class _NodeInspectorState extends State<NodeInspector> {
  late final TextEditingController _title = TextEditingController(
    text: widget.node.title,
  );
  late final TextEditingController _line = TextEditingController(
    text: widget.node.ttsText,
  );
  final Map<String, TextEditingController> _labels = {};
  final TextEditingController _prompt = TextEditingController();
  final GlobalKey _previewKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _syncLabels(force: true);
  }

  @override
  void didUpdateWidget(covariant NodeInspector old) {
    super.didUpdateWidget(old);
    if (old.node.nodeId != widget.node.nodeId) {
      _title.text = widget.node.title;
      _line.text = widget.node.ttsText;
      _prompt.clear();
      _syncLabels(force: true);
    } else {
      _setIfDifferent(_title, widget.node.title);
      _setIfDifferent(_line, widget.node.ttsText);
      _syncLabels();
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _line.dispose();
    _prompt.dispose();
    for (final controller in _labels.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        _buildAiCard(node),
        const SizedBox(height: 24),
        TextField(
          key: ValueKey('title-${node.nodeId}'),
          controller: _title,
          enabled: !widget.busy,
          maxLength: 40,
          decoration: _inspectorInputDecoration(
            labelText: 'Title',
            hintText: 'The temple door',
          ),
          onChanged: widget.onTitleChanged,
        ),
        const SizedBox(height: 8),
        TextField(
          key: ValueKey('line-${node.nodeId}'),
          controller: _line,
          enabled: !widget.busy,
          maxLines: 3,
          decoration: _inspectorInputDecoration(
            labelText: 'Narrator line',
            hintText: 'What should they do next?',
          ),
          onChanged: widget.onLineChanged,
        ),
        const SizedBox(height: 24),
        _buildHotspotHeader(node),
        const SizedBox(height: 8),
        if (node.isEnding)
          const Text(
            'Endings hold no choices, so there are no zones.',
            style: RamificaText.meta,
          )
        else
          Container(
            key: _previewKey,
            child: ZoneMarker(
              nodeId: node.nodeId,
              choices: node.choices,
              targets: widget.targets,
              endImageUrl: node.endImageSourceUrl,
              busy: widget.busy,
              onZoneMoved: widget.onZoneMoved,
              onZoneAdded: widget.onZoneAdded,
              onZoneRemoved: widget.onZoneRemoved,
              onLabelChanged: widget.onChoiceLabelChanged,
              onIconChanged: widget.onChoiceIconChanged,
              onIconColorChanged: widget.onChoiceIconColorChanged,
            ),
          ),
        if (!node.isEnding) ...[
          const SizedBox(height: 4),
          Align(
            alignment: .centerRight,
            child: TextButton(
              key: ValueKey('save-zones-${node.nodeId}'),
              onPressed: widget.busy ? null : widget.onZonesSaved,
              child: const Text('Save zones'),
            ),
          ),
          for (var i = 0; i < node.choices.length; i++) ...[
            const SizedBox(height: 8),
            _DecisionCard(
              choice: node.choices[i],
              index: i,
              slot: node.choices[i].slot ?? String.fromCharCode(65 + i),
              targetLabel:
                  widget.choiceTargets[node.choices[i].choiceId] ?? 'Scene —',
              targetTitle: widget.targetTitles[node.choices[i].choiceId],
              busy: widget.busy,
              labelController: _labels[node.choices[i].choiceId],
              onLabelChanged: (label) => widget.onChoiceLabelChanged?.call(
                node.choices[i].choiceId,
                label,
              ),
              onTune: _scrollToPreview,
            ),
          ],
        ],
        const SizedBox(height: 24),
        _buildAddOption(),
        const SizedBox(height: 24),
        _buildProduction(node),
        if (!widget.isRoot) ...[const SizedBox(height: 24), _buildDelete(node)],
      ],
    );
  }

  /// Suite section header over the scene preview: title plus the live
  /// count of placed hotspots.
  Widget _buildHotspotHeader(DraftNode node) {
    return Row(
      children: [
        const Icon(Icons.touch_app, color: RamificaColors.hotspot, size: 20),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Hotspot & HUD Mapping',
            style: TextStyle(
              fontFamily: RamificaText.display,
              fontWeight: .w600,
              fontSize: 18,
              height: 24 / 18,
              color: RamificaColors.textPrimary,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: RamificaColors.containerBase,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: .min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: RamificaColors.hotspot,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '${node.choices.length} Active Points',
                style: RamificaText.caption.copyWith(
                  color: RamificaColors.hotspot,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Everything the suite flow does not show but publishing still needs:
  /// visibility, the missing checklist, frames, video, voice, save, and
  /// delete — grouped in one production card under the episode tree.
  Widget _buildProduction(DraftNode node) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RamificaColors.containerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RamificaColors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          Row(
            children: [
              const Text('Secret', style: RamificaText.meta),
              const SizedBox(width: 8),
              Switch(
                value: node.secret,
                onChanged: widget.busy
                    ? null
                    : (secret) => widget.onVisibilityChanged?.call(
                        secret ? 'secret' : 'visible',
                      ),
              ),
            ],
          ),
          if (widget.missing.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final item in widget.missing)
              Padding(
                padding: const .symmetric(vertical: 2),
                child: Text(item, style: RamificaText.meta),
              ),
          ],
          const SizedBox(height: 16),
          const Text('Frames', style: RamificaText.label),
          const SizedBox(height: 8),
          FrameCompare(
            startImageUrl: widget.isRoot
                ? node.startImageSourceUrl
                : widget.parent?.endImageSourceUrl,
            endImageUrl: node.endImageSourceUrl,
          ),
          const SizedBox(height: 8),
          if (widget.isRoot)
            _frameControls(
              which: 'start',
              approved: node.startImageApproved,
              status: node.startImageStatus,
              hasImage: node.startImageSourceUrl != null,
            ),
          _frameControls(
            which: 'end',
            approved: node.endImageApproved,
            status: node.endImageStatus,
            hasImage: node.endImageSourceUrl != null,
          ),
          const SizedBox(height: 16),
          const Text('Video', style: RamificaText.label),
          const SizedBox(height: 8),
          Row(
            children: [
              _videoStatusPill(node),
              if (widget.videoDesynced) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Out of sync — regenerate to re-inherit.',
                    style: RamificaText.meta.copyWith(
                      color: RamificaColors.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (widget.videoGateMessage != null) ...[
            const SizedBox(height: 4),
            Text(widget.videoGateMessage!, style: RamificaText.meta),
          ],
          const SizedBox(height: 8),
          OutlinedButton(
            key: ValueKey('gen-video-${node.nodeId}'),
            onPressed: widget.busy || widget.videoGateMessage != null
                ? null
                : widget.onVideoGenerate,
            child: Text(
              node.videoUrl == null ? 'Generate video' : 'Another take',
            ),
          ),
          if (widget.onUploadVideo != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              key: ValueKey('upload-video-${node.nodeId}'),
              onPressed: widget.busy || widget.uploadProgress != null
                  ? null
                  : widget.onUploadVideo,
              child: const Text('Upload video'),
            ),
          ],
          if (widget.uploadProgress != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: widget.uploadProgress!.clamp(0, 1),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(widget.uploadProgress!.clamp(0, 1) * 100).round()}%',
                  style: RamificaText.meta,
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          const Text('Voice', style: RamificaText.label),
          const SizedBox(height: 8),
          _lineApprovalRow(node),
          const SizedBox(height: 8),
          Row(
            children: [
              _voiceStatusPill(node),
              if (node.ttsApproved) ...[
                const SizedBox(width: 8),
                const StatusPill(status: StatusPillState.approved),
              ],
              if (node.ttsAudioUrl == null) ...[
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'No narrator voice yet.',
                    style: RamificaText.meta,
                  ),
                ),
              ],
            ],
          ),
          if (!_voiceGateOpen(node)) ...[
            const SizedBox(height: 4),
            const Text(
              'Approve the narrator line to generate voice.',
              style: RamificaText.meta,
            ),
          ],
          const SizedBox(height: 8),
          OutlinedButton(
            key: ValueKey('gen-voice-${node.nodeId}'),
            onPressed: widget.busy || !_voiceGateOpen(node)
                ? null
                : widget.onVoiceGenerate,
            child: Text(
              node.ttsAudioUrl == null ? 'Generate voice' : 'Another take',
            ),
          ),
          if (node.ttsAudioUrl != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: VoicePreview(
                    nodeId: node.nodeId,
                    audioUrl: node.ttsAudioUrl!,
                    busy: widget.busy,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: ValueKey('approve-voice-${node.nodeId}'),
                  onPressed: widget.busy || node.ttsApproved
                      ? null
                      : () => widget.onVoiceApprovalChanged?.call(true),
                  child: const Text('Approve'),
                ),
                TextButton(
                  key: ValueKey('reject-voice-${node.nodeId}'),
                  onPressed: widget.busy || !node.ttsApproved
                      ? null
                      : () => widget.onVoiceApprovalChanged?.call(false),
                  child: const Text('Reject'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Suite AI card: prompt box, static model pills, and the generate CTA.
  /// Sends the textarea through [NodeInspector.onPromptGenerate]; an empty
  /// prompt means unguided, like the old bare generate. The Autocomplete
  /// chip in the prompt header reuses [NodeInspector.onRegenerate]: Spark
  /// fills (or overwrites) the scene text without a prompt.
  Widget _buildAiCard(DraftNode node) {
    final generate = widget.onPromptGenerate;
    return Container(
      decoration: BoxDecoration(
        color: RamificaColors.containerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RamificaColors.outlineVariant),
        boxShadow: const [
          BoxShadow(
            color: Color(0x99000000),
            blurRadius: 32,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Positioned(
              top: -48,
              right: -32,
              child: Container(
                width: 176,
                height: 176,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      RamificaColors.hotspot.withValues(alpha: 0.16),
                      RamificaColors.hotspot.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: -32,
              left: -32,
              child: Container(
                width: 176,
                height: 176,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      RamificaColors.nodeActive.withValues(alpha: 0.16),
                      RamificaColors.nodeActive.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: .stretch,
                mainAxisSize: .min,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.psychology,
                        color: RamificaColors.hotspot,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'AI Script Assistant',
                          style: RamificaText.label.copyWith(
                            color: RamificaColors.hotspot,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: RamificaColors.containerLowest.withValues(
                        alpha: 0.8,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: .stretch,
                      mainAxisSize: .min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Describe what happens in this scene and its choices',
                                style: RamificaText.labelSM.copyWith(
                                  fontSize: 10,
                                  color: RamificaColors.textSecondary,
                                ),
                              ),
                            ),
                            InkWell(
                              key: ValueKey('regen-text-${node.nodeId}'),
                              onTap: widget.busy ? null : widget.onRegenerate,
                              child: Row(
                                mainAxisSize: .min,
                                children: [
                                  const Icon(
                                    Icons.auto_awesome,
                                    size: 12,
                                    color: RamificaColors.hotspot,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Autocomplete',
                                    style: RamificaText.labelSM.copyWith(
                                      fontSize: 10,
                                      color: RamificaColors.hotspot,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          key: ValueKey('ai-prompt-${node.nodeId}'),
                          controller: _prompt,
                          enabled: !widget.busy,
                          minLines: 3,
                          maxLines: 3,
                          style: RamificaText.bodySM.copyWith(height: 1.6),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: .zero,
                            hintText: 'The protagonist finds an ancient terminal in the derelict ship. Choose: hack the core or overload the shields…',
                            hintStyle: RamificaText.bodySM.copyWith(
                              color: RamificaColors.textSecondary.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'MODELS',
                    style: RamificaText.labelSM.copyWith(
                      fontSize: 10,
                      letterSpacing: 0.5,
                      color: RamificaColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Row(
                    crossAxisAlignment: .start,
                    children: [
                      _ModelPill(
                        icon: Icons.videocam,
                        iconColor: RamificaColors.hotspot,
                        name: 'HeyGen Video',
                        detail: '9:16 · 6s clips',
                      ),
                      SizedBox(width: 4),
                      _ModelPill(
                        icon: Icons.image,
                        iconColor: RamificaColors.nodeActive,
                        name: 'Muse Image',
                        detail: '480x854 stills',
                      ),
                      SizedBox(width: 4),
                      _ModelPill(
                        icon: Icons.bolt,
                        iconColor: RamificaColors.rewardGold,
                        name: 'Muse Spark',
                        detail: 'Script text',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: _GradientCta(
                      buttonKey: ValueKey('gen-text-${node.nodeId}'),
                      icon: Icons.auto_awesome,
                      label: 'Generate Variations with AI',
                      onPressed: widget.busy || generate == null
                          ? null
                          : () => generate(_prompt.text.trim()),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Scrolls the hotspot preview into view. Tune buttons call this; the
  /// zone itself is edited by drag on the preview.
  void _scrollToPreview() {
    final context = _previewKey.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 300),
      );
    }
  }

  /// Standalone add-branch button: the only action above production.
  /// Same event as the canvas mini; the author opens the new scene there.
  Widget _buildAddOption() {
    return SizedBox(
      height: 48,
      child: FilledButton(
        onPressed: widget.busy ? null : widget.onAddBranch,
        style: FilledButton.styleFrom(
          backgroundColor: RamificaColors.containerBase,
          foregroundColor: RamificaColors.textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: const Row(
          mainAxisAlignment: .center,
          mainAxisSize: .min,
          children: [
            Icon(Icons.add_circle, size: 20, color: RamificaColors.hotspot),
            SizedBox(width: 8),
            Text('Add New Option (+)', style: RamificaText.label),
          ],
        ),
      ),
    );
  }

  /// Full-width red delete at the bottom. The caller skips it on the root
  /// (which can never be deleted). Tapping asks for confirmation first;
  /// the reason explains a disabled button on targeted nodes.
  Widget _buildDelete(DraftNode node) {
    final blocked = widget.busy || widget.deleteBlockedReason != null;
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        if (widget.deleteBlockedReason != null)
          Text(widget.deleteBlockedReason!, style: RamificaText.meta),
        if (widget.deleteBlockedReason != null) const SizedBox(height: 4),
        SizedBox(
          height: 48,
          width: double.infinity,
          child: FilledButton(
            key: ValueKey('delete-node-${node.nodeId}'),
            onPressed: blocked ? null : () => _confirmDelete(node),
            style: FilledButton.styleFrom(
              backgroundColor: RamificaColors.danger,
              foregroundColor: RamificaColors.textPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Delete node'),
          ),
        ),
      ],
    );
  }

  /// Delete confirmation for a non-root node. Confirming calls
  /// [onDelete]; dismissing does nothing.
  Future<void> _confirmDelete(DraftNode node) async {
    final title = node.title.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete node?'),
        content: Text(
          title.isEmpty
              ? 'Delete this scene? This cannot be undone.'
              : 'Delete "$title"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: ValueKey('confirm-delete-${node.nodeId}'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              'Delete',
              style: TextStyle(color: RamificaColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onDelete?.call();
  }

  /// One frame row: label, approval [StatusPill], and approve / reject /
  /// generate buttons. Approve needs a generated frame; reject flips an
  /// approval back off; generate (re-)requests the frame server-side.
  Widget _frameControls({
    required String which,
    required bool approved,
    required String? status,
    required bool hasImage,
  }) {
    final nodeId = widget.node.nodeId;
    final pill = approved
        ? StatusPillState.approved
        : switch (status) {
            'pending' => StatusPillState.running,
            'ready' => StatusPillState.ready,
            'failed' => StatusPillState.failed,
            _ => StatusPillState.idle,
          };
    return Padding(
      padding: const .symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  which == 'start' ? 'Start' : 'End',
                  style: RamificaText.meta,
                ),
              ),
              StatusPill(status: pill),
            ],
          ),
          Row(
            children: [
              TextButton(
                key: ValueKey('approve-$which-$nodeId'),
                onPressed: widget.busy || !hasImage || approved
                    ? null
                    : () => widget.onImageApprovalChanged?.call(which, true),
                child: const Text('Approve'),
              ),
              TextButton(
                key: ValueKey('reject-$which-$nodeId'),
                onPressed: widget.busy || !approved
                    ? null
                    : () => widget.onImageApprovalChanged?.call(which, false),
                child: const Text('Reject'),
              ),
              TextButton(
                key: ValueKey('gen-image-$which-$nodeId'),
                onPressed: widget.busy
                    ? null
                    : () => widget.onImageGenerate?.call(which),
                child: Text(hasImage ? 'Another take' : 'Generate'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Video job pill from the server [videoStatus]: ready / pending /
  /// failed, idle otherwise (including gated and desynced idles).
  StatusPill _videoStatusPill(DraftNode node) {
    final status = switch (node.videoStatus) {
      'ready' => StatusPillState.ready,
      'pending' => StatusPillState.running,
      'failed' => StatusPillState.failed,
      _ => StatusPillState.idle,
    };
    return StatusPill(status: status);
  }

  /// Voice pill from the server [ttsStatus]: ready / pending / failed,
  /// idle otherwise. Generation dispatches `generateNodeVoice` through
  /// [NodeInspector.onVoiceGenerate] (gated on the approved line); the
  /// pill itself stays display-only.
  StatusPill _voiceStatusPill(DraftNode node) {
    final status = switch (node.ttsStatus) {
      'ready' => StatusPillState.ready,
      'pending' => StatusPillState.running,
      'failed' => StatusPillState.failed,
      _ => StatusPillState.idle,
    };
    return StatusPill(status: status);
  }

  /// True when the voice gate is open: the line is approved and non-blank,
  /// mirroring the `generateNodeVoice` failed-precondition.
  bool _voiceGateOpen(DraftNode node) {
    return node.lineApproved && node.ttsText.trim().isNotEmpty;
  }

  /// Narrator line approval row. Approve needs a non-blank line; reject
  /// flips an approval back off. Both write bloc state and persist with
  /// the inspector Save (the backend clears line approval when the text
  /// itself changes in the same save).
  Widget _lineApprovalRow(DraftNode node) {
    final nodeId = node.nodeId;
    final hasLine = node.ttsText.trim().isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: Text(
            node.lineApproved ? 'Line approved.' : 'Line not approved.',
            style: RamificaText.meta,
          ),
        ),
        TextButton(
          key: ValueKey('approve-line-$nodeId'),
          onPressed: widget.busy || !hasLine || node.lineApproved
              ? null
              : () => widget.onLineApprovalChanged?.call(true),
          child: const Text('Approve line'),
        ),
        TextButton(
          key: ValueKey('reject-line-$nodeId'),
          onPressed: widget.busy || !node.lineApproved
              ? null
              : () => widget.onLineApprovalChanged?.call(false),
          child: const Text('Reject'),
        ),
      ],
    );
  }

  /// Choice label controllers follow the choice list: new choices get a
  /// controller, removed ones are disposed. Values resync only when the
  /// text differs, so typing keeps its caret.
  void _syncLabels({bool force = false}) {
    final ids = {for (final choice in widget.node.choices) choice.choiceId};
    for (final id in _labels.keys.toList()) {
      if (!ids.contains(id)) _labels.remove(id)?.dispose();
    }
    for (final choice in widget.node.choices) {
      final controller = _labels.putIfAbsent(
        choice.choiceId,
        () => TextEditingController(text: choice.label),
      );
      if (force || controller.text != choice.label) {
        controller.text = choice.label;
      }
    }
  }
}

void _setIfDifferent(TextEditingController controller, String value) {
  if (controller.text != value) controller.text = value;
}

/// Creator input styling: 6% white fill with a hotspot focus edge.
InputDecoration _inspectorInputDecoration({
  required String labelText,
  required String hintText,
}) {
  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    filled: true,
    fillColor: RamificaColors.inputFill,
    enabledBorder: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      borderSide: RamificaColors.inputBorder,
    ),
    focusedBorder: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      borderSide: RamificaColors.inputFocusedBorder,
    ),
  );
}

/// Gradient CTA reusing the existing generate event: same callback, suite
/// cyan-to-blue treatment. Disabled state falls back to a flat glass fill.
class _GradientCta extends StatelessWidget {
  const _GradientCta({
    required this.label,
    required this.onPressed,
    this.icon,
    this.buttonKey,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: enabled
            ? const LinearGradient(
                colors: [
                  RamificaColors.hotspot,
                  Color(0xFF3196E6),
                  RamificaColors.nodeActive,
                ],
              )
            : null,
        color: enabled ? null : RamificaColors.glass,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        boxShadow: enabled
            ? const [
                BoxShadow(
                  color: Color(0x6600F2FE),
                  blurRadius: 24,
                  offset: Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: TextButton(
        key: buttonKey,
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF003256),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        child: Row(
          mainAxisAlignment: .center,
          mainAxisSize: .min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 22),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  fontFamily: RamificaText.display,
                  fontWeight: .w600,
                  fontSize: 18,
                  height: 24 / 18,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stitch-style decision card: slot badge, editable label, and the target
/// scene it leads to. The tune action scrolls the hotspot preview into
/// view, where the zone itself is edited by drag.
class _DecisionCard extends StatelessWidget {
  const _DecisionCard({
    required this.choice,
    required this.index,
    required this.slot,
    required this.targetLabel,
    this.targetTitle,
    required this.busy,
    required this.labelController,
    required this.onLabelChanged,
    this.onTune,
  });

  final DraftChoice choice;
  final int index;
  final String slot;
  final String targetLabel;

  /// Full `Scene M (Title)` destination, or null to show [targetLabel].
  final String? targetTitle;
  final bool busy;
  final TextEditingController? labelController;
  final ValueChanged<String> onLabelChanged;

  /// Scrolls the hotspot preview into view. Null hides the tune button.
  final VoidCallback? onTune;

  static const _accents = [RamificaColors.hotspot, RamificaColors.nodeActive];

  @override
  Widget build(BuildContext context) {
    final accent = _accents[index % _accents.length];
    final icon = choiceIconData(choice.icon, index);
    return Container(
      key: ValueKey('choice-card-${choice.choiceId}'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: RamificaColors.containerBase,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.2),
            ),
            child: Icon(
              icon,
              size: 18,
              color: choiceIconColor(choice.iconColor, accent),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: .start,
              mainAxisSize: .min,
              children: [
                TextField(
                  key: ValueKey('choice-${choice.choiceId}'),
                  controller: labelController,
                  enabled: !busy,
                  maxLength: 24,
                  style: const TextStyle(
                    fontFamily: RamificaText.display,
                    fontWeight: .w700,
                    fontSize: 13,
                    color: RamificaColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: .zero,
                    counterText: '',
                    hintText: 'Choice ${slot.isEmpty ? '' : slot}',
                    hintStyle: RamificaText.caption,
                  ),
                  onChanged: onLabelChanged,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Icon(
                      Icons.alt_route,
                      size: 13,
                      color: RamificaColors.nodeActive,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Leads to: ${targetTitle ?? targetLabel}',
                        style: RamificaText.bodySM.copyWith(
                          fontSize: 12,
                          color: RamificaColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (onTune != null)
            IconButton(
              icon: const Icon(Icons.tune, size: 18),
              tooltip: 'Edit hotspot',
              onPressed: busy ? null : onTune,
              color: RamificaColors.textSecondary,
              style: IconButton.styleFrom(
                backgroundColor: RamificaColors.containerHigh,
                fixedSize: const Size(32, 32),
                minimumSize: const Size(32, 32),
                padding: .zero,
              ),
            ),
        ],
      ),
    );
  }
}

/// Static model pill for the AI card: which provider powers what. Display
/// only — model choice is a deploy-time contract, not a runtime toggle.
class _ModelPill extends StatelessWidget {
  const _ModelPill({
    required this.icon,
    required this.iconColor,
    required this.name,
    required this.detail,
  });

  final IconData icon;
  final Color iconColor;
  final String name;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: RamificaColors.containerBase,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: .min,
          children: [
            Row(
              mainAxisAlignment: .center,
              mainAxisSize: .min,
              children: [
                Icon(icon, size: 16, color: iconColor),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    name,
                    style: RamificaText.labelSM.copyWith(fontSize: 10),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              style: RamificaText.caption.copyWith(fontSize: 9),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
