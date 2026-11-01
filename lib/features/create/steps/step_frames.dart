import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/draft_node.dart';

/// S2 Scenes: one frame panel per image. Each panel shows its prompt
/// editor (2000 chars) before Generate / Another take, so the author
/// revises the prompt that generation sends. The prompt edits stay local
/// through [onStartPromptChanged]/[onEndPromptChanged]; the Generate
/// buttons send the freshly edited text through [onImageGenerate].
///
/// Non-root nodes inherit S from their parent E: the start panel renders
/// read-only with the [inheritedPrompt]. Busy blocks every control. A
/// failed generation keeps the last image: panels render whatever URL
/// the node carries.
class StepFrames extends StatefulWidget {
  const StepFrames({
    super.key,
    required this.node,
    this.isRoot = false,
    this.inheritedImageUrl,
    this.inheritedCaption,
    this.inheritedPrompt,
    required this.busy,
    this.generatingWhich,
    this.phase,
    required this.showErrors,
    this.onImageGenerate,
    this.onImageApprovalChanged,
    this.onStartPromptChanged,
    this.onEndPromptChanged,
  });

  final DraftNode node;

  /// Root nodes own S; children inherit it read-only.
  final bool isRoot;
  final String? inheritedImageUrl;
  final String? inheritedCaption;

  /// Parent E prompt behind the inherited S, shown read-only.
  final String? inheritedPrompt;
  final bool busy;
  final String? generatingWhich, phase;
  final bool showErrors;

  /// Sends `which` (`start` or `end`) with the freshly edited prompt.
  final void Function(String which, String prompt)? onImageGenerate;
  final void Function(String which, bool approved)? onImageApprovalChanged;

  /// Local edits; Save or Generate persists these values.
  final ValueChanged<String>? onStartPromptChanged;
  final ValueChanged<String>? onEndPromptChanged;

  @override
  State<StepFrames> createState() => _StepFramesState();
}

class _StepFramesState extends State<StepFrames> {
  late final TextEditingController _start = TextEditingController(
    text: widget.node.startImagePrompt ?? '',
  );
  late final TextEditingController _end = TextEditingController(
    text: widget.node.endImagePrompt ?? '',
  );
  late final FocusNode _startFocus = FocusNode();
  late final FocusNode _endFocus = FocusNode();

  @override
  void didUpdateWidget(covariant StepFrames oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.nodeId != widget.node.nodeId) {
      _start.text = widget.node.startImagePrompt ?? '';
      _end.text = widget.node.endImagePrompt ?? '';
      return;
    }
    // Polling reloads must not clobber in-flight edits: only sync a prompt
    // the author is not editing.
    if (!_startFocus.hasFocus) {
      _setIfDifferent(_start, widget.node.startImagePrompt ?? '');
    }
    if (!_endFocus.hasFocus) {
      _setIfDifferent(_end, widget.node.endImagePrompt ?? '');
    }
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _startFocus.dispose();
    _endFocus.dispose();
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
        if (widget.isRoot)
          _FramePanel(
            nodeId: nodeId,
            which: 'start',
            locallyGenerating: widget.generatingWhich == 'start',
            phase: widget.phase ?? node.generationPhase,
            title: 'Start frame',
            focus: _startFocus,
            prompt: _start,
            imageUrl: node.startImageSourceUrl,
            status: node.startImageStatus,
            approved: node.startImageApproved,
            busy: widget.busy,
            showError: widget.showErrors && !node.startImageApproved,
            onGenerate: widget.onImageGenerate,
            onApprovalChanged: widget.onImageApprovalChanged,
            onPromptChanged: widget.onStartPromptChanged,
          )
        else
          _InheritedPanel(
            nodeId: nodeId,
            title: 'Start frame',
            caption: widget.inheritedCaption,
            imageUrl: widget.inheritedImageUrl,
            prompt: widget.inheritedPrompt,
          ),
        const SizedBox(height: 16),
        _FramePanel(
          nodeId: nodeId,
          which: 'end',
          locallyGenerating: widget.generatingWhich == 'end',
          phase: widget.phase ?? node.generationPhase,
          title: 'End frame',
          focus: _endFocus,
          prompt: _end,
          imageUrl: node.endImageSourceUrl,
          status: node.endImageStatus,
          approved: node.endImageApproved,
          busy: widget.busy,
          showError: widget.showErrors && !node.endImageApproved,
          onGenerate: widget.onImageGenerate,
          onApprovalChanged: widget.onImageApprovalChanged,
          onPromptChanged: widget.onEndPromptChanged,
        ),
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
/// Another take plus Approve / Reject chips below. Gate/approval hints
/// sit under the disabled control.
class _FramePanel extends StatelessWidget {
  const _FramePanel({
    required this.nodeId,
    this.locallyGenerating = false,
    this.phase,
    required this.which,
    required this.title,
    required this.focus,
    required this.prompt,
    required this.imageUrl,
    required this.status,
    required this.approved,
    required this.busy,
    required this.showError,
    required this.onGenerate,
    required this.onApprovalChanged,
    required this.onPromptChanged,
  });

  final String nodeId;
  final String which;
  final bool locallyGenerating;
  final String? phase;
  final String title;
  final FocusNode focus;
  final TextEditingController prompt;
  final String? imageUrl;
  final String? status;
  final bool approved;
  final bool busy;
  final bool showError;
  final void Function(String which, String prompt)? onGenerate;
  final void Function(String which, bool approved)? onApprovalChanged;
  final ValueChanged<String>? onPromptChanged;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    // Backend reports 'pending' while the still is rendering.
    final generating = locallyGenerating || status == 'pending';
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: RamificaText.label)),
            if (showError && !approved)
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
            border: showError && !approved
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
                  if (url == null)
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
                      url,
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
                      status: approved
                          ? StatusPillState.approved
                          : switch (status) {
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
                  if (generating && url != null)
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
        if (url != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: ValueKey('approve-$which-$nodeId'),
                  onPressed: busy || approved
                      ? null
                      : () => onApprovalChanged?.call(which, true),
                  child: const Text('Approve'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: ValueKey('reject-$which-$nodeId'),
                onPressed: busy || !approved
                    ? null
                    : () => onApprovalChanged?.call(which, false),
                child: const Text('Reject'),
              ),
            ],
          ),
        ],
        if (showError && !approved)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              '⚠ Approve this frame',
              style: TextStyle(color: RamificaColors.error, fontSize: 12),
            ),
          ),
        if (status == 'failed' && !approved)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Generation failed — try again.',
              style: RamificaText.meta,
            ),
          ),
      ],
    );
  }
}

/// Read-only inherited S for non-root nodes, with the parent E prompt
/// behind it when available.
class _InheritedPanel extends StatefulWidget {
  const _InheritedPanel({
    required this.nodeId,
    required this.title,
    this.caption,
    this.imageUrl,
    this.prompt,
  });

  final String nodeId;
  final String title;
  final String? caption;
  final String? imageUrl;
  final String? prompt;

  @override
  State<_InheritedPanel> createState() => _InheritedPanelState();
}

class _InheritedPanelState extends State<_InheritedPanel> {
  late final TextEditingController _prompt = TextEditingController(
    text: widget.prompt ?? '',
  );

  @override
  void didUpdateWidget(covariant _InheritedPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.prompt != widget.prompt) {
      _prompt.text = widget.prompt ?? '';
    }
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.imageUrl;
    final inherited = _prompt.text.trim();
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        Row(
          children: [
            Expanded(child: Text(widget.title, style: RamificaText.label)),
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Text('Inherited', style: RamificaText.meta),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (inherited.isNotEmpty)
          TextField(
            key: ValueKey('prompt-start-${widget.nodeId}'),
            controller: _prompt,
            readOnly: true,
            enabled: false,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Image prompt',
              filled: true,
              fillColor: RamificaColors.inputFill,
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                borderSide: RamificaColors.inputBorder,
              ),
            ),
          ),
        if (inherited.isNotEmpty) const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            borderRadius: RamificaLayout.cardBorderRadius,
            border: Border.fromBorderSide(RamificaColors.inputBorder),
          ),
          child: ClipRRect(
            borderRadius: RamificaLayout.cardBorderRadius,
            child: AspectRatio(
              aspectRatio: 9 / 16,
              child: url == null
                  ? Container(
                      color: RamificaColors.inputFill,
                      child: Center(
                        child: Text(
                          widget.caption ?? 'No parent frame yet.',
                          style: RamificaText.caption,
                        ),
                      ),
                    )
                  : Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: RamificaColors.inputFill,
                        child: const Center(
                          child: Text('Missing', style: RamificaText.caption),
                        ),
                      ),
                    ),
            ),
          ),
        ),
        if (widget.caption != null) ...[
          const SizedBox(height: 4),
          Text(widget.caption!, style: RamificaText.meta),
        ],
      ],
    );
  }
}
