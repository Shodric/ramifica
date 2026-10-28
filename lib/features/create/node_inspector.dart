import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/frame_compare.dart';
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
    this.videoGateMessage,
    this.videoDesynced = false,
    this.onTitleChanged,
    this.onLineChanged,
    this.onChoiceLabelChanged,
    this.onVisibilityChanged,
    this.onSave,
    this.onGenerate,
    this.onRegenerate,
    this.onImageApprovalChanged,
    this.onImageGenerate,
    this.onVideoGenerate,
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

  /// Why video generation is gated, or null when the gate is open.
  final String? videoGateMessage;

  /// True when this node's video is stale (parent E regenerated).
  final bool videoDesynced;

  final ValueChanged<String>? onTitleChanged;
  final ValueChanged<String>? onLineChanged;
  final void Function(String choiceId, String label)? onChoiceLabelChanged;
  final ValueChanged<String>? onVisibilityChanged;
  final VoidCallback? onSave;
  final VoidCallback? onGenerate;
  final VoidCallback? onRegenerate;

  /// Frame approval flip: `which` is `start` or `end`.
  final void Function(String which, bool approved)? onImageApprovalChanged;

  /// Frame generation request: `which` is `start` or `end`.
  final ValueChanged<String>? onImageGenerate;

  final VoidCallback? onVideoGenerate;

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
              node.videoUrl == null ? 'Generate video' : 'Regenerate video',
            ),
          ),
          const SizedBox(height: 12),
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
                child: const Text('Generate'),
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
