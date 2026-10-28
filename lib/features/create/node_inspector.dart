import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/frame_compare.dart';
import 'package:ramifica/features/create/window_picker.dart';
import 'package:ramifica/features/create/zone_marker.dart';
import 'package:ramifica/features/create/voice_preview.dart';

/// Inspector for the open draft node: manual editing fields, the
/// per-node [StatusPill], and what is missing for publish.
///
/// Manual editing is the point. Every keystroke writes bloc state through
/// the callbacks; nothing reaches the server until [onSave]. Controllers
/// resync from [node] only when the text differs (a proposal or a
/// reload), so typing never loses its caret: the bloc echoes each
/// keystroke back unchanged.
class NodeInspector extends StatefulWidget {
  const NodeInspector({
    super.key,
    required this.node,
    required this.status,
    required this.missing,
    this.busy = false,
    this.isRoot = false,
    this.parent,
    this.targets = const [],
    this.videoGateMessage,
    this.videoDesynced = false,
    this.onTitleChanged,
    this.onLineChanged,
    this.onChoiceLabelChanged,
    this.onVisibilityChanged,
    this.onWindowChanged,
    this.onZoneMoved,
    this.onZoneAdded,
    this.onZoneRemoved,
    this.onZonesSaved,
    this.onWindowSaved,
    this.onSave,
    this.onGenerate,
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
  final StatusPillState status;
  final List<String> missing;

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
  final ValueChanged<String>? onVisibilityChanged;
  final ValueChanged<int>? onWindowChanged;
  final void Function(String choiceId, double x, double y)? onZoneMoved;
  final ValueChanged<String>? onZoneAdded;
  final ValueChanged<String>? onZoneRemoved;
  final VoidCallback? onZonesSaved;
  final VoidCallback? onWindowSaved;
  final VoidCallback? onSave;
  final VoidCallback? onGenerate;
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
    for (final controller in _labels.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    return GlassPanel(
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  node.title.trim().isEmpty ? '(untitled)' : node.title,
                  style: RamificaText.label,
                  maxLines: 1,
                  overflow: .ellipsis,
                ),
              ),
              StatusPill(status: widget.status),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: ValueKey('title-${node.nodeId}'),
            controller: _title,
            enabled: !widget.busy,
            maxLength: 40,
            decoration: const InputDecoration(
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
            decoration: const InputDecoration(
              labelText: 'Narrator line',
              hintText: 'What should they do next?',
            ),
            onChanged: widget.onLineChanged,
          ),
          for (final choice in node.choices) ...[
            const SizedBox(height: 8),
            TextField(
              key: ValueKey('choice-${choice.choiceId}'),
              controller: _labels[choice.choiceId],
              enabled: !widget.busy,
              maxLength: 24,
              decoration: const InputDecoration(
                labelText: 'Choice',
                hintText: 'Enter the temple',
              ),
              onChanged: (label) =>
                  widget.onChoiceLabelChanged?.call(choice.choiceId, label),
            ),
          ],
          const SizedBox(height: 8),
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
          const Text('Zones', style: RamificaText.label),
          const SizedBox(height: 8),
          if (node.isEnding)
            const Text(
              'Endings hold no choices, so there are no zones.',
              style: RamificaText.meta,
            )
          else
            ZoneMarker(
              nodeId: node.nodeId,
              choices: node.choices,
              targets: widget.targets,
              endImageUrl: node.endImageSourceUrl,
              busy: widget.busy,
              onZoneMoved: widget.onZoneMoved,
              onZoneAdded: widget.onZoneAdded,
              onZoneRemoved: widget.onZoneRemoved,
              onLabelChanged: widget.onChoiceLabelChanged,
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
          ],
          const SizedBox(height: 16),
          const Text('Window', style: RamificaText.label),
          const SizedBox(height: 8),
          if (node.isEnding)
            const Text(
              'Endings decide nothing, so there is no window.',
              style: RamificaText.meta,
            )
          else
            WindowPicker(
              nodeId: node.nodeId,
              value: node.windowSeconds ?? WindowPicker.defaultSeconds,
              busy: widget.busy,
              onChanged: widget.onWindowChanged,
            ),
          if (!node.isEnding)
            Align(
              alignment: .centerRight,
              child: TextButton(
                key: ValueKey('save-window-${node.nodeId}'),
                onPressed: widget.busy ? null : widget.onWindowSaved,
                child: const Text('Save window'),
              ),
            ),
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
                      : () =>
                          widget.onVoiceApprovalChanged?.call(true),
                  child: const Text('Approve'),
                ),
                TextButton(
                  key: ValueKey('reject-voice-${node.nodeId}'),
                  onPressed: widget.busy || !node.ttsApproved
                      ? null
                      : () =>
                          widget.onVoiceApprovalChanged?.call(false),
                  child: const Text('Reject'),
                ),
              ],
            ),
          ],
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: widget.busy ? null : widget.onSave,
                  child: const Text('Save'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.busy ? null : widget.onGenerate,
                  child: const Text('Spark'),
                ),
              ),
              TextButton(
                onPressed: widget.busy ? null : widget.onRegenerate,
                child: const Text('Regenerate'),
              ),
            ],
          ),
        ],
      ),
    );
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
