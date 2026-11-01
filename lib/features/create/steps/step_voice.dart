import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/features/create/voice_preview.dart';

/// S4 Voice owns the line heard when the player is about to choose.
/// Write or generate the text, approve it, then generate and approve audio.
class StepVoice extends StatefulWidget {
  const StepVoice({
    super.key,
    required this.node,
    required this.busy,
    this.active = true,
    this.generating = false,
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
  final String? phase;
  final bool showErrors;
  final ValueChanged<String>? onLineChanged;
  final VoidCallback? onLineGenerate;
  final ValueChanged<bool>? onLineApprovalChanged;
  final VoidCallback? onVoiceGenerate;
  final ValueChanged<bool>? onVoiceApprovalChanged;

  /// True when the voice gate is open: the line is approved and non-blank,
  /// mirroring the `generateNodeVoice` failed-precondition.
  static bool gateOpen(DraftNode node) =>
      node.lineApproved && node.ttsText.trim().isNotEmpty;

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
    final generating = widget.generating || node.ttsStatus == 'pending';
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
        const SizedBox(height: 12),
        TextField(
          key: ValueKey('line-$nodeId'),
          controller: _line,
          focusNode: _focus,
          enabled: !busy,
          maxLength: 280,
          minLines: 2,
          maxLines: 4,
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
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: const Text('Generate line'),
        ),
        _LineApprovalRow(
          node: node,
          busy: busy,
          showError:
              showErrors &&
              node.ttsText.trim().isNotEmpty &&
              !node.lineApproved,
          onLineApprovalChanged: widget.onLineApprovalChanged,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            StatusPill(status: status),
            if (node.ttsApproved) ...[
              const SizedBox(width: 8),
              const StatusPill(status: StatusPillState.approved),
            ],
            if (node.ttsAudioUrl == null) ...[
              const SizedBox(width: 8),
              const Expanded(
                child: Text('No narrator voice yet.', style: RamificaText.meta),
              ),
            ],
          ],
        ),
        if (!gate) ...[
          const SizedBox(height: 4),
          const Text(
            'Approve the narrator line to generate voice.',
            style: RamificaText.meta,
          ),
        ],
        const SizedBox(height: 8),
        if (node.ttsAudioUrl == null)
          FilledButton(
            key: ValueKey('gen-voice-$nodeId'),
            onPressed: busy || !gate ? null : widget.onVoiceGenerate,
            child: const Text('Generate voice'),
          )
        else
          OutlinedButton(
            key: ValueKey('gen-voice-$nodeId'),
            onPressed: busy || !gate ? null : widget.onVoiceGenerate,
            child: const Text('Another take'),
          ),
        if (generating)
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
        if (node.ttsStatus == 'failed')
          const Text(
            'Voice generation failed. Retry Generate or Another take.',
          ),
        if (showErrors && node.ttsStatus != 'ready') ...[
          const SizedBox(height: 4),
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
          Row(
            children: [
              const SizedBox(width: 8),
              FilledButton(
                key: ValueKey('approve-voice-$nodeId'),
                onPressed: busy || node.ttsApproved
                    ? null
                    : () => widget.onVoiceApprovalChanged?.call(true),
                child: const Text('Approve'),
              ),
              const SizedBox(width: 4),
              TextButton(
                key: ValueKey('reject-voice-$nodeId'),
                onPressed: busy || !node.ttsApproved
                    ? null
                    : () => widget.onVoiceApprovalChanged?.call(false),
                child: const Text('Reject'),
              ),
            ],
          ),
        ],
        if (showErrors && node.ttsStatus == 'ready' && !node.ttsApproved) ...[
          const SizedBox(height: 4),
          const Text(
            '⚠ Approve the voice',
            style: TextStyle(color: RamificaColors.error, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

/// Narrator line approval row. Approve needs a non-blank line; reject
/// flips an approval back off. [showError] adds the inline warning.
class _LineApprovalRow extends StatelessWidget {
  const _LineApprovalRow({
    required this.node,
    required this.busy,
    required this.showError,
    required this.onLineApprovalChanged,
  });

  final DraftNode node;
  final bool busy;
  final bool showError;
  final ValueChanged<bool>? onLineApprovalChanged;

  @override
  Widget build(BuildContext context) {
    final nodeId = node.nodeId;
    final hasLine = node.ttsText.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                node.lineApproved ? 'Line approved.' : 'Line not approved.',
                style: RamificaText.meta,
              ),
            ),
            TextButton(
              key: ValueKey('approve-line-$nodeId'),
              onPressed: busy || !hasLine || node.lineApproved
                  ? null
                  : () => onLineApprovalChanged?.call(true),
              child: const Text('Approve line'),
            ),
            TextButton(
              key: ValueKey('reject-line-$nodeId'),
              onPressed: busy || !node.lineApproved
                  ? null
                  : () => onLineApprovalChanged?.call(false),
              child: const Text('Reject'),
            ),
          ],
        ),
        if (showError)
          const Text(
            '⚠ Approve the line to continue',
            style: TextStyle(color: RamificaColors.error, fontSize: 12),
          ),
      ],
    );
  }
}
