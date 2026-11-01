import 'package:flutter/material.dart';
import 'package:ramifica/features/create/clip_preview.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/draft_node.dart';

/// S5 Clip: video prompt editor, status, desync notice, gate hint under
/// the disabled control, generate / another-take, and optional mp4/mov
/// upload with progress. The video Generate button stays outlined so the
/// gated state keeps its existing contract.
///
/// The clip prompt edits stay local through [onVideoPromptChanged] and
/// Generate sends the revised value through [onVideoGenerate]. Polling
/// reloads never clobber an in-flight edit: the editor only syncs while
/// unfocused.
class StepClip extends StatefulWidget {
  const StepClip({
    super.key,
    required this.node,
    this.inheritedPrompt,
    required this.busy,
    this.active = true,
    this.generating = false,
    this.phase,
    required this.showErrors,
    this.videoGateMessage,
    this.videoDesynced = false,
    this.uploadProgress,
    this.onVideoPromptChanged,
    this.onVideoGenerate,
    this.onUploadVideo,
  });

  final DraftNode node;

  /// Parent E prompt behind the inherited S, shown as the fallback hint.
  final String? inheritedPrompt;
  final bool busy;
  final bool active, generating;
  final String? phase;
  final bool showErrors;
  final String? videoGateMessage;
  final bool videoDesynced;
  final double? uploadProgress;

  /// Local prompt edits; persisted only by Save or generation.
  final ValueChanged<String>? onVideoPromptChanged;

  /// Sends the revised clip prompt.
  final ValueChanged<String>? onVideoGenerate;
  final VoidCallback? onUploadVideo;

  @override
  State<StepClip> createState() => _StepClipState();
}

class _StepClipState extends State<StepClip> {
  late final TextEditingController _prompt = TextEditingController(
    text: widget.node.videoPrompt ?? '',
  );
  late final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant StepClip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.nodeId != widget.node.nodeId) {
      _prompt.text = widget.node.videoPrompt ?? '';
      return;
    }
    // Polling reloads must not clobber an in-flight edit: only sync the
    // prompt while the author is not editing it.
    if (!_focus.hasFocus) {
      final value = widget.node.videoPrompt ?? '';
      if (_prompt.text != value) _prompt.text = value;
    }
  }

  @override
  void dispose() {
    _prompt.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final nodeId = node.nodeId;
    final status = switch (node.videoStatus) {
      'ready' => StatusPillState.ready,
      'pending' => StatusPillState.running,
      'failed' => StatusPillState.failed,
      _ => StatusPillState.idle,
    };
    final generating = widget.generating || node.videoStatus == 'pending';
    final inherited = widget.inheritedPrompt?.trim() ?? '';
    final pendingJob =
        node.videoStatus == 'pending' &&
        (node.videoJobId?.startsWith('or_') ?? false);
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        if (node.videoUrl?.isNotEmpty == true) ...[
          ClipPreview(
            key: ValueKey('clip-preview-$nodeId'),
            url: node.videoUrl!,
            active: widget.active,
            generating: generating,
            phase: widget.phase ?? node.generationPhase,
            width: node.videoWidth,
            height: node.videoHeight,
            durationSeconds: node.durationSeconds,
          ),
          const SizedBox(height: 12),
        ] else if (generating)
          const SizedBox(
            height: 180,
            child: Center(child: CircularProgressIndicator()),
          ),
        if (generating)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  (widget.phase ?? node.generationPhase) == 'saving'
                      ? 'Saving changes…'
                      : (widget.phase ?? node.generationPhase) == 'processing'
                      ? 'Processing video…'
                      : 'Generating video…',
                ),
              ],
            ),
          ),
        if (node.videoStatus == 'failed')
          const Text(
            'Video generation failed. Retry Generate or Another take.',
          ),
        if (node.videoStatus == 'ready' &&
            (node.videoWidth != 480 ||
                node.videoHeight != 854 ||
                (node.videoSource == 'generated' &&
                    ((node.durationSeconds ?? 0) - 10).abs() > 1 / 30)))
          const Text(
            'Replace this clip before publishing: new clips must be 480 × 854; AI clips must last 10 seconds.',
          ),
        Row(
          children: [
            StatusPill(status: status),
            if (widget.videoDesynced) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Out of sync — regenerate to inherit again.',
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
        TextField(
          key: ValueKey('video-prompt-$nodeId'),
          controller: _prompt,
          focusNode: _focus,
          enabled: !widget.busy && !pendingJob,
          maxLength: 2000,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: 'Video prompt',
            hintText: inherited.isNotEmpty
                ? 'Inherited S: $inherited'
                : 'How the clip should move…',
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
          ),
          onChanged: widget.onVideoPromptChanged,
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: ValueKey('gen-video-$nodeId'),
          onPressed: widget.busy || widget.videoGateMessage != null
              ? null
              : () => widget.onVideoGenerate?.call(
                  pendingJob ? (node.videoPrompt ?? '') : _prompt.text,
                ),
          child: Text(
            generating && widget.busy
                ? "Generating video…"
                : pendingJob
                ? 'Continue generation'
                : (node.videoUrl == null ? 'Generate video' : 'Another take'),
          ),
        ),
        if (widget.onUploadVideo != null) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            key: ValueKey('upload-video-$nodeId'),
            onPressed: widget.busy || widget.uploadProgress != null
                ? null
                : widget.onUploadVideo,
            child: const Text('Upload clip'),
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
        if (widget.showErrors && node.videoStatus != 'ready') ...[
          const SizedBox(height: 4),
          const Text(
            '⚠ Generate the clip',
            style: TextStyle(color: RamificaColors.error, fontSize: 12),
          ),
        ],
      ],
    );
  }
}
