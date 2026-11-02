import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/voice_preview.dart';

/// S3 Voice owns the line heard when the player is about to choose.
/// Write or generate the text, then generate audio. Generated media is
/// accepted as-is: regen replaces it. Approval fields are ignored
/// (kept for compat until callers drop them).
class StepVoice extends StatefulWidget {
  const StepVoice({
    super.key,
    required this.node,
    required this.busy,
    this.active = true,
    this.generating = false,
    this.generatingLine = false,
    this.phase,
    required this.showErrors,
    this.onLineChanged,
    this.onLineGenerate,
    this.onLineApprovalChanged,
    this.onVoiceGenerate,
    this.onVoiceApprovalChanged,
  });

  final DraftNode node;
  final bool busy;
  final bool active, generating;
  final bool generatingLine;
  final String? phase;
  final bool showErrors;
  final ValueChanged<String>? onLineChanged;
  final VoidCallback? onLineGenerate;
  // Legacy approval callback, ignored. Kept for compat until callers drop it.
  final ValueChanged<bool>? onLineApprovalChanged;
  final VoidCallback? onVoiceGenerate;
  // Legacy approval callback, ignored. Kept for compat until callers drop it.
  final ValueChanged<bool>? onVoiceApprovalChanged;

  /// True when the voice gate is open: the line is non-blank.
  /// Regen replaces the take; no approval step remains.
  static bool gateOpen(DraftNode node) => node.ttsText.trim().isNotEmpty;

  @override
  State<StepVoice> createState() => _StepVoiceState();
}

class _StepVoiceState extends State<StepVoice> {
  late final _line = TextEditingController(text: widget.node.ttsText);
  final _focus = FocusNode();

  @override
  void didUpdateWidget(covariant StepVoice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.nodeId != widget.node.nodeId ||
        oldWidget.node.ttsText != widget.node.ttsText) {
      if (_line.text != widget.node.ttsText) _line.text = widget.node.ttsText;
    }
  }

  @override
  void dispose() {
    _line.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final busy = widget.busy;
    final showErrors = widget.showErrors;
    final nodeId = node.nodeId;
    final generating =
        widget.generating ||
        (node.ttsStatus == 'pending' && !node.generationExpired);
    final gate = StepVoice.gateOpen(node);
    final status = switch (node.ttsStatus) {
      'ready' => StatusPillState.ready,
      'pending' => StatusPillState.running,
      'failed' => StatusPillState.failed,
      _ => StatusPillState.idle,
    };
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        Text(
          node.isEnding ? 'The narrator closes this ending after the clip.' : 'The narrator speaks after the clip, just before the player chooses an Option.',
          style: RamificaText.meta,
        ),
        const SizedBox(height: 8),
        TextField(
          key: ValueKey('line-$nodeId'),
          controller: _line,
          focusNode: _focus,
          enabled: !busy,
          maxLength: 280,
          minLines: 3,
          maxLines: 5,
          decoration: InputDecoration(
            labelText: 'Narrator line',
            hintText: node.isEnding
                ? 'Close this ending in a short line…'
                : 'What will you choose?',
            filled: true,
            fillColor: RamificaColors.inputFill,
            border: const OutlineInputBorder(),
            errorText: showErrors && node.ttsText.trim().isEmpty
                ? 'Write the narrator line'
                : null,
          ),
          onChanged: widget.onLineChanged,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: ValueKey('gen-line-$nodeId'),
          onPressed: busy || widget.onLineGenerate == null
              ? null
              : () {
                  _focus.unfocus();
                  widget.onLineGenerate?.call();
                },
          icon: widget.generatingLine
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome, size: 18),
          label: Text(
            widget.generatingLine
                ? widget.phase == 'saving'
                      ? 'Saving changes…'
                      : 'Suggesting line…'
                : 'Suggest line',
          ),
        ),
        const SizedBox(height: 16),
        // No status row once audio exists: the preview below is the
        // state, and regen is just Generate voice again.
        if (node.ttsAudioUrl == null)
          Row(
            children: [
              StatusPill(status: status),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('No narrator voice yet.', style: RamificaText.meta),
              ),
            ],
          ),
        if (!gate) ...[
          const SizedBox(height: 8),
          const Text(
            'Write the narrator line to generate voice.',
            style: RamificaText.meta,
          ),
        ],
        const SizedBox(height: 8),
        FilledButton(
          key: ValueKey('gen-voice-$nodeId'),
          onPressed: busy || !gate ? null : widget.onVoiceGenerate,
          child: const Text('Generate voice'),
        ),
        if (generating) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                widget.phase == 'saving'
                    ? 'Saving changes…'
                    : (widget.phase ?? node.generationPhase) == 'processing'
                    ? 'Processing audio…'
                    : 'Generating voice…',
              ),
            ],
          ),
        ],
        if (node.generationExpired && node.ttsStatus == 'pending') ...[
          const SizedBox(height: 8),
          const Text('The voice request timed out. Retry Generate voice.'),
        ],
        if (node.ttsStatus == 'failed') ...[
          const SizedBox(height: 8),
          Text(
            node.mediaError ?? 'Voice generation failed. Retry Generate voice.',
          ),
        ],
        if (showErrors && node.ttsStatus != 'ready') ...[
          const SizedBox(height: 8),
          const Text(
            '⚠ Generate the voice',
            style: TextStyle(color: RamificaColors.error, fontSize: 12),
          ),
        ],
        if (node.ttsAudioUrl != null) ...[
          const SizedBox(height: 8),
          VoicePreview(
            nodeId: nodeId,
            audioUrl: node.ttsAudioUrl!,
            active: widget.active,
            busy: busy || generating,
            durationSeconds: node.ttsDurationSeconds,
          ),
        ],
      ],
    );
  }
}
