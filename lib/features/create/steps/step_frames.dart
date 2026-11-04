import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/draft_node.dart';

/// S2 Scenes: the root-only S panel. It shows its prompt editor
/// (2000 chars) before Generate / Another take, so the author revises
/// the prompt that generation sends. The prompt edits stay local through
/// [onStartPromptChanged]; the Generate buttons send the freshly edited
/// text through [onImageGenerate].
///
/// Children skip this step: they inherit S from their parent clip's
/// extracted last frame. Busy blocks every control. A failed generation
/// keeps the last image: panels render whatever URL the node carries.
/// Generated media is accepted as-is: regen replaces it. Approval fields
/// are ignored (kept for compat until callers drop them).
///
/// The panel also hosts the optional reference still: the author picks
/// an image, frames it 9:16, and the client uploads it direct to
/// Storage, storing its URL on the node. The stored still overwrites
/// the generated image in the frame slot, badged as Reference.
class StepFrames extends StatefulWidget {
  const StepFrames({
    super.key,
    required this.node,
    required this.busy,
    this.generatingWhich,
    this.phase,
    required this.showErrors,
    this.onImageGenerate,
    this.onImageApprovalChanged,
    this.onStartPromptChanged,
    this.uploadProgress,
    this.onUploadReference,
    this.onReferenceRemoved,
    this.active = true,
    this.continueAction,
  });

  final DraftNode node;
  final bool busy;

  /// Offstage steps skip the continue action so a single one mounts.
  final bool active;

  /// Continue action placed at the step's end. Null renders nothing.
  final Widget? continueAction;
  final String? generatingWhich, phase;
  final bool showErrors;

  /// Sends `which` (`start` only) with the freshly edited prompt.
  final void Function(String which, String prompt)? onImageGenerate;

  /// Legacy approval callback, ignored. Kept for compat until callers drop it.
  final void Function(String which, bool approved)? onImageApprovalChanged;

  /// Local edits; Save or Generate persists these values.
  final ValueChanged<String>? onStartPromptChanged;

  /// Reference-upload progress 0..1 while this node's still goes up.
  final double? uploadProgress;

  /// Opens the pick-and-frame flow. Null hides the upload button.
  final VoidCallback? onUploadReference;

  /// Clears the stored reference URL. Null hides the remove button.
  final VoidCallback? onReferenceRemoved;

  @override
  State<StepFrames> createState() => _StepFramesState();
}

class _StepFramesState extends State<StepFrames> {
  late final TextEditingController _start = TextEditingController(
    text: widget.node.startImagePrompt ?? '',
  );
  late final FocusNode _startFocus = FocusNode();

  @override
  void didUpdateWidget(covariant StepFrames oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.nodeId != widget.node.nodeId) {
      _start.text = widget.node.startImagePrompt ?? '';
      return;
    }
    // Polling reloads must not clobber in-flight edits: only sync a prompt
    // the author is not editing.
    if (!_startFocus.hasFocus) {
      _setIfDifferent(_start, widget.node.startImagePrompt ?? '');
    }
  }

  @override
  void dispose() {
    _start.dispose();
    _startFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final nodeId = node.nodeId;
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        _FramePanel(
          nodeId: nodeId,
          which: 'start',
          locallyGenerating: widget.generatingWhich == 'start',
          error: node.mediaError,
          phase: widget.phase ?? node.generationPhase,
          title: 'Start frame',
          focus: _startFocus,
          prompt: _start,
          imageUrl: node.startImageSourceUrl,
          status: node.generationExpired && node.startImageStatus == 'pending'
              ? 'failed'
              : node.startImageStatus,
          approved: node.startImageApproved,
          busy: widget.busy,
          showError: widget.showErrors && node.startImageStatus != 'ready',
          onGenerate: widget.onImageGenerate,
          onApprovalChanged: widget.onImageApprovalChanged,
          onPromptChanged: widget.onStartPromptChanged,
          referenceUrl: node.startImageReferenceUrl,
          uploadProgress: widget.uploadProgress,
          onUploadReference: widget.onUploadReference,
          onReferenceRemoved: widget.onReferenceRemoved,
        ),
        if (widget.active && widget.continueAction != null) ...[
          const SizedBox(height: 16),
          widget.continueAction!,
        ],
      ],
    );
  }
}

void _setIfDifferent(TextEditingController controller, String value) {
  if (controller.text != value) controller.text = value;
}

/// One frame panel: prompt editor first, then the image (or its
/// placeholder) with the [StatusPill] overlaid in the corner, a centered
/// primary Generate while empty, and — once an image exists — a corner
/// Another take. Gate hints for missing frames sit under the panel.
class _FramePanel extends StatelessWidget {
  const _FramePanel({
    required this.nodeId,
    this.locallyGenerating = false,
    this.error,
    this.phase,
    required this.which,
    required this.title,
    required this.focus,
    required this.prompt,
    required this.imageUrl,
    required this.status,
    this.approved = false,
    required this.busy,
    required this.showError,
    required this.onGenerate,
    this.onApprovalChanged,
    required this.onPromptChanged,
    this.referenceUrl,
    this.uploadProgress,
    this.onUploadReference,
    this.onReferenceRemoved,
  });

  final String nodeId;
  final String which;
  final bool locallyGenerating;
  final String? error;
  final String? phase;
  final String title;
  final FocusNode focus;
  final TextEditingController prompt;
  final String? imageUrl;
  final String? status;
  // Legacy approval flag, ignored: generated media is accepted as-is.
  final bool approved;
  final bool busy;
  final bool showError;
  final void Function(String which, String prompt)? onGenerate;
  // Legacy approval callback, ignored. Kept for compat until callers drop it.
  final void Function(String which, bool approved)? onApprovalChanged;
  final ValueChanged<String>? onPromptChanged;
  final String? referenceUrl;
  final double? uploadProgress;
  final VoidCallback? onUploadReference;
  final VoidCallback? onReferenceRemoved;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    // The uploaded reference overwrites the generated still in the frame
    // slot; generation controls still key off the generated image, which
    // is what the step gate requires.
    final displayUrl = referenceUrl ?? url;
    final showingReference = referenceUrl != null;
    // Backend reports 'pending' while the still is rendering.
    final generating = locallyGenerating || status == 'pending';
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: RamificaText.label)),
            if (showError)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Text('⚠', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          key: ValueKey('prompt-$which-$nodeId'),
          controller: prompt,
          focusNode: focus,
          enabled: !busy,
          maxLength: 2000,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Image prompt',
            hintText: 'How this frame should look…',
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
          onChanged: onPromptChanged,
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            borderRadius: RamificaLayout.cardBorderRadius,
            border: showError
                ? Border.all(color: RamificaColors.error, width: 1.5)
                : Border.fromBorderSide(RamificaColors.inputBorder),
          ),
          child: ClipRRect(
            borderRadius: RamificaLayout.cardBorderRadius,
            child: AspectRatio(
              aspectRatio: 9 / 16,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (displayUrl == null)
                    Container(
                      color: RamificaColors.inputFill,
                      child: Center(
                        child: generating
                            // First render: spinner instead of the CTA.
                            ? const CircularProgressIndicator(
                                key: ValueKey('generating-indicator'),
                              )
                            : FilledButton(
                                key: ValueKey('gen-image-$which-$nodeId'),
                                onPressed: busy
                                    ? null
                                    : () =>
                                          onGenerate?.call(which, prompt.text),
                                child: const Text('Generate'),
                              ),
                      ),
                    )
                  else
                    Image.network(
                      displayUrl,
                      fit: BoxFit.cover,
                      loadingBuilder: (context, child, progress) =>
                          progress == null
                          ? child
                          : Stack(
                              alignment: Alignment.center,
                              children: [
                                child,
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircularProgressIndicator(
                                      value: progress.expectedTotalBytes == null
                                          ? null
                                          : progress.cumulativeBytesLoaded /
                                                progress.expectedTotalBytes!,
                                    ),
                                    const Text('Loading image…'),
                                  ],
                                ),
                              ],
                            ),
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: RamificaColors.inputFill,
                        child: Center(child: Text('Missing')),
                      ),
                    ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: StatusPill(
                      status: switch (status) {
                        'pending' => StatusPillState.running,
                        'ready' => StatusPillState.ready,
                        'failed' => StatusPillState.failed,
                        _ => StatusPillState.idle,
                      },
                    ),
                  ),
                  if (url != null)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: OutlinedButton(
                        key: ValueKey('gen-image-$which-$nodeId'),
                        onPressed: busy || generating
                            ? null
                            : () => onGenerate?.call(which, prompt.text),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.black54,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Another take'),
                      ),
                    ),
                  if (showingReference)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: Container(
                        key: ValueKey('reference-badge-$nodeId'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Reference',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                  if (generating && displayUrl != null)
                    // Re-render: dim the stale still with a centered spinner.
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black45,
                        child: Center(
                          child: CircularProgressIndicator(
                            key: ValueKey('generating-indicator'),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        // Reference set but no generated frame yet: the step still needs
        // its S, so Generate stays a full-width CTA under the panel. It
        // never coexists with the in-panel CTAs (same key, one mounts).
        if (showingReference && url == null && !generating)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: ValueKey('gen-image-$which-$nodeId'),
                onPressed: busy
                    ? null
                    : () => onGenerate?.call(which, prompt.text),
                child: const Text('Generate'),
              ),
            ),
          ),
        if (onUploadReference != null ||
            referenceUrl != null ||
            uploadProgress != null)
          _ReferenceRow(
            nodeId: nodeId,
            referenceUrl: referenceUrl,
            uploadProgress: uploadProgress,
            busy: busy,
            onUpload: onUploadReference,
            onRemove: onReferenceRemoved,
          ),
        if (generating)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              phase == 'saving'
                  ? 'Saving changes…'
                  : phase == 'processing'
                  ? 'Processing image…'
                  : 'Generating image…',
            ),
          ),
        if (showError)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              '⚠ Generate this frame',
              style: TextStyle(color: RamificaColors.error, fontSize: 12),
            ),
          ),
        if (status == 'failed')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error ?? 'Generation failed — try again.',
              style: RamificaText.meta,
            ),
          ),
      ],
    );
  }
}

/// Optional reference still controls under the S frame: a progress bar
/// while the still goes up; once stored, Change/Remove (the frame slot
/// above shows the still itself); otherwise an upload button. Busy
/// blocks every control.
class _ReferenceRow extends StatelessWidget {
  const _ReferenceRow({
    required this.nodeId,
    required this.referenceUrl,
    required this.uploadProgress,
    required this.busy,
    required this.onUpload,
    required this.onRemove,
  });

  final String nodeId;
  final String? referenceUrl;
  final double? uploadProgress;
  final bool busy;
  final VoidCallback? onUpload;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final progress = uploadProgress;
    final url = referenceUrl;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          Text('Reference', style: RamificaText.label),
          const SizedBox(height: 8),
          if (progress != null) ...[
            LinearProgressIndicator(
              key: ValueKey('reference-upload-progress-$nodeId'),
              value: progress.clamp(0, 1),
            ),
            const SizedBox(height: 4),
            Text(
              'Uploading reference… ${(progress.clamp(0, 1) * 100).round()}%',
              style: RamificaText.meta,
            ),
          ] else if (url != null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Showing in the frame above.',
                    style: RamificaText.meta,
                  ),
                ),
                if (onUpload != null)
                  TextButton(
                    key: ValueKey('upload-reference-$nodeId'),
                    onPressed: busy ? null : onUpload,
                    child: const Text('Change'),
                  ),
                if (onRemove != null)
                  IconButton(
                    key: ValueKey('remove-reference-$nodeId'),
                    tooltip: 'Remove reference',
                    onPressed: busy ? null : onRemove,
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
              ],
            ),
          ] else ...[
            OutlinedButton.icon(
              key: ValueKey('upload-reference-$nodeId'),
              onPressed: busy ? null : onUpload,
              icon: const Icon(Icons.upload, size: 18),
              label: const Text('Upload reference'),
            ),
          ],
        ],
      ),
    );
  }
}
