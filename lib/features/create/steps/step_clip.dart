import 'package:flutter/material.dart';
import 'package:ramifica/features/create/clip_preview.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/data/models/draft_node.dart';

/// S4 Clip: video prompt editor, status, desync notice, gate hint under
/// the disabled control, generate, and optional mp4/mov upload with
/// progress. The video Generate button stays outlined so the gated
/// state keeps its existing contract. Once a clip is ready the prompt
/// and actions hide and the player takes the whole area: no takes.
///
/// The clip prompt edits stay local through [onVideoPromptChanged] and
/// Generate sends the revised value through [onVideoGenerate]. Polling
/// reloads never clobber an in-flight edit: the editor only syncs while
/// unfocused.
class StepClip extends StatefulWidget {
  const StepClip({
    super.key,
    required this.node,
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
    this.continueAction,
  });

  final DraftNode node;

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

  /// Continue action placed at the step's end; mounted only while
  /// [active]. Null renders nothing.
  final Widget? continueAction;

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
    final generating =
        widget.generating ||
        node.videoStatus == 'pending' ||
        (node.generationKind == 'video' && node.generationPhase != null);
    final pendingJob =
        node.videoStatus == 'pending' &&
        (node.videoJobId?.startsWith('or_') ?? false);
    // Bounded (the app step area): the player fills the leftover height
    // with no outer scroll. Unbounded (a scrollable parent): the fixed
    // player box, page scrolls as before.
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded = constraints.maxHeight.isFinite;
        Widget player() => ClipPreview(
          key: ValueKey('clip-preview-$nodeId'),
          url: node.videoUrl!,
          active: widget.active,
          generating: generating,
          phase: widget.phase ?? node.generationPhase,
          width: node.videoWidth,
          height: node.videoHeight,
          durationSeconds: node.durationSeconds,
          expand: bounded,
        );
        // A ready clip is final: the player takes the area and the
        // prompt plus actions hide. An actively generating or uploading
        // clip also hides the editor: only the loader square, the upload
        // progress, and Continue stay, until the job fails or ends.
        final finished =
            (node.videoUrl?.isNotEmpty ?? false) && node.videoStatus == 'ready';
        // Keyed off the live operation signals, not `generating`: an idle
        // pending job still needs its editor for the resume button.
        final promptHidden =
            (widget.generating || widget.uploadProgress != null) &&
            node.videoStatus != 'failed';
        return Column(
          crossAxisAlignment: .stretch,
          mainAxisSize: bounded ? .max : .min,
          children: [
            if (node.videoUrl?.isNotEmpty == true) ...[
              bounded ? Expanded(child: player()) : player(),
              if (!finished) const SizedBox(height: 12),
            ] else if (generating)
              bounded
                  ? const Expanded(child: _GeneratingPlaceholder())
                  : const SizedBox(
                      height: 180,
                      child: _GeneratingPlaceholder(),
                    ),
            if (!finished && !promptHidden) ...[
              if (node.videoUrl?.isNotEmpty == true || generating)
                const SizedBox(height: 12),
              _PromptCard(
                child: Column(
                  crossAxisAlignment: .stretch,
                  mainAxisSize: .min,
                  children: [
                    if (widget.videoGateMessage != null) ...[
                      Text(widget.videoGateMessage!, style: RamificaText.meta),
                      const SizedBox(height: 8),
                    ],
                    const Text('Video prompt', style: RamificaText.label),
                    const SizedBox(height: 8),
                    TextField(
                      key: ValueKey('video-prompt-$nodeId'),
                      controller: _prompt,
                      focusNode: _focus,
                      enabled: !widget.busy && !pendingJob,
                      maxLength: 2000,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'How the clip should move…',
                        filled: true,
                        fillColor: RamificaColors.inputFill,
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                          borderSide: RamificaColors.inputBorder,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                          borderSide: RamificaColors.inputFocusedBorder,
                        ),
                      ),
                      onChanged: widget.onVideoPromptChanged,
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: ValueKey('gen-video-$nodeId'),
                      onPressed: widget.busy || widget.videoGateMessage != null
                          ? null
                          : () => widget.onVideoGenerate?.call(
                              pendingJob
                                  ? (node.videoPrompt ?? '')
                                  : _prompt.text,
                            ),
                      icon: const Icon(Icons.movie_outlined, size: 18),
                      label: Text(
                        generating && widget.busy
                            ? "Generating video…"
                            : pendingJob
                            ? 'Continue generation'
                            : 'Generate video',
                      ),
                    ),
                    if (widget.onUploadVideo != null) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: ValueKey('upload-video-$nodeId'),
                        onPressed: widget.busy || widget.uploadProgress != null
                            ? null
                            : widget.onUploadVideo,
                        icon: const Icon(Icons.upload, size: 18),
                        label: const Text('Upload clip'),
                      ),
                    ],
                    if (node.videoStatus == 'failed') ...[
                      const SizedBox(height: 8),
                      const Text('Video generation failed. Retry Generate.'),
                    ],
                    if (widget.showErrors && node.videoStatus != 'ready') ...[
                      const SizedBox(height: 8),
                      const Text(
                        '⚠ Generate the clip',
                        style: TextStyle(
                          color: RamificaColors.error,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            // Upload progress lives outside the prompt card so it stays
            // visible while the editor hides during the upload.
            if (!finished && widget.uploadProgress != null) ...[
              const SizedBox(height: 12),
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
            if (finished &&
                (node.durationSeconds == null ||
                    node.durationSeconds! <= 0)) ...[
              const SizedBox(height: 8),
              const Text(
                'This clip has no measured duration.',
                style: RamificaText.meta,
              ),
            ],
            if (widget.active && widget.continueAction != null) ...[
              const SizedBox(height: 16),
              widget.continueAction!,
            ],
          ],
        );
      },
    );
  }
}

/// Card grouping the prompt editor with its actions.
class _PromptCard extends StatelessWidget {
  const _PromptCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: RamificaColors.containerBase,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RamificaColors.outlineVariant),
      ),
      child: child,
    );
  }
}

/// Full-area wash while the clip renders: the container fill with a slow
/// accent pulse behind the centered spinner. No text: the button label
/// already names the running job.
class _GeneratingPlaceholder extends StatefulWidget {
  const _GeneratingPlaceholder();

  @override
  State<_GeneratingPlaceholder> createState() => _GeneratingPlaceholderState();
}

class _GeneratingPlaceholderState extends State<_GeneratingPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Container(
        decoration: BoxDecoration(
          borderRadius: RamificaLayout.cardBorderRadius,
          border: Border.fromBorderSide(RamificaColors.inputBorder),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              RamificaColors.hotspot.withValues(
                alpha: 0.05 + 0.06 * _pulse.value,
              ),
              RamificaColors.primaryContainer.withValues(
                alpha: 0.12 + 0.12 * _pulse.value,
              ),
            ],
          ),
        ),
        child: child,
      ),
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}
