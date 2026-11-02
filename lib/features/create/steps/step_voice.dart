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
    this.continueAction,
  });

  final DraftNode node;
  final bool busy;
  final bool active, generating;

  /// Continue action placed at the step's end; mounted only while
  /// [active]. Null renders nothing.
  final Widget? continueAction;
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
    final voiceLabel = generating
        ? widget.phase == 'saving'
              ? 'Saving changes…'
              : (widget.phase ?? node.generationPhase) == 'processing'
              ? 'Processing audio…'
              : 'Generating voice…'
        : 'Generate voice';
    // Bounded (the app step area): the content scrolls internally and
    // the continue action pins to the bottom. Unbounded (a scrollable
    // parent): a single min column, page scrolls as before.
    final content = <Widget>[
      _InfoBox(
        text: node.isEnding
            ? 'The narrator closes this ending after the clip.'
            : 'The narrator speaks after the clip, just before the player chooses an Option.',
      ),
      const SizedBox(height: 12),
      _SectionCard(
        child: Column(
          crossAxisAlignment: .stretch,
          mainAxisSize: .min,
          children: [
            const Text('Narrator line', style: RamificaText.label),
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
                hintText: node.isEnding
                    ? 'Close this ending in a short line…'
                    : 'What will you choose?',
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
                errorText: showErrors && node.ttsText.trim().isEmpty
                    ? 'Write the narrator line'
                    : null,
              ),
              onChanged: widget.onLineChanged,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: .end,
              children: [
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
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _SectionCard(
        child: Column(
          crossAxisAlignment: .stretch,
          mainAxisSize: .min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Voice take', style: RamificaText.label),
                ),
                if (node.ttsAudioUrl == null) StatusPill(status: status),
              ],
            ),
            // No pill once audio exists: the preview below is
            // the state, and regen is just Generate voice again.
            if (node.ttsAudioUrl == null) ...[
              const SizedBox(height: 8),
              const Text('No narrator voice yet.', style: RamificaText.meta),
            ],
            if (!gate) ...[
              const SizedBox(height: 8),
              const Text(
                'Write the narrator line to generate voice.',
                style: RamificaText.meta,
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              key: ValueKey('gen-voice-$nodeId'),
              onPressed: busy || !gate ? null : widget.onVoiceGenerate,
              icon: generating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: RamificaColors.textPrimary,
                      ),
                    )
                  : const Icon(Icons.record_voice_over, size: 18),
              label: Text(voiceLabel),
            ),
            if (node.generationExpired && node.ttsStatus == 'pending') ...[
              const SizedBox(height: 8),
              const Text('The voice request timed out. Retry Generate voice.'),
            ],
            if (node.ttsStatus == 'failed') ...[
              const SizedBox(height: 8),
              Text(
                node.mediaError ??
                    'Voice generation failed. Retry Generate voice.',
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
        ),
      ),
    ];
    final action = <Widget>[
      if (widget.active && widget.continueAction != null) ...[
        const SizedBox(height: 16),
        widget.continueAction!,
      ],
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxHeight.isFinite) {
          return Column(
            crossAxisAlignment: .stretch,
            mainAxisSize: .min,
            children: [...content, ...action],
          );
        }
        return Column(
          crossAxisAlignment: .stretch,
          mainAxisSize: .max,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: .stretch,
                  mainAxisSize: .min,
                  children: content,
                ),
              ),
            ),
            ...action,
          ],
        );
      },
    );
  }
}

/// Info callout over the voice sections.
class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: RamificaColors.nodeActive.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: RamificaColors.nodeActive.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: .start,
        children: [
          const Icon(
            Icons.info_outline,
            size: 16,
            color: RamificaColors.nodeActive,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: RamificaText.meta)),
        ],
      ),
    );
  }
}

/// Card grouping one voice section: line editor or voice take.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

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
