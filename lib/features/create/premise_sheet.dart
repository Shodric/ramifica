import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/app_snackbar.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/dictation/dictation_controller.dart';
import 'package:ramifica/features/create/dictation/dictation_controls.dart';
import 'package:ramifica/features/create/voice_recorder.dart';
import 'package:ramifica/features/create/asr_socket.dart';

export 'package:ramifica/features/create/dictation/dictation_controller.dart'
    show listeningPlaceholder, TranscribeAudio;

/// One proposed outline from speech: editable fields plus ≤2 options.
/// Wired to `proposeStoryOutline`; null hides the Format bar.
typedef ProposePremise =
    Future<
      ({
        String? title,
        String? synopsis,
        String? narratorLine,
        List<OutlineOption> options,
      })
    >
    Function(String transcript);

/// Latest title, idea text, and proposed options. The idea text is the
/// only narration field: typing and dictation both write it.
typedef PremiseDraftChanged = void Function({
  required String title,
  required String idea,
  required List<OutlineOption> options,
});

/// Step 0 premise: a title plus one idea field. Dictation and typing
/// write that same field. While recording it reads [listeningPlaceholder];
/// stopping sends the audio to [transcribe] and the returned text
/// replaces the field. Format reads the field and keeps the outline in
/// an accordion. The field fills the height it is given.
class PremiseSheet extends StatefulWidget {
  const PremiseSheet({
    super.key,
    this.initialTitle = '',
    this.initialIdea = '',
    this.recorder,
    this.socketFactory,
    this.getIdToken,
    this.getAppCheckToken,
    this.transcribe,
    this.propose,
    this.onApply,
    this.onDraft,
    this.embedded = false,
  });

  final String initialTitle;

  /// The single premise field. Narration and "Tell your idea" are this text.
  final String initialIdea;

  /// Test seam. Null builds the platform recorder (web only).
  final VoiceRecorder? recorder;

  /// Builds the realtime socket. Null disables live dictation (legacy
  /// single-shot flow through [transcribe]).
  final AsrSocketFactory? socketFactory;

  /// Firebase ID token for the relay auth frame. Null provider (or a null
  /// token) means signed-out: no socket, record-only with WAV fallback.
  final AuthTokenProvider? getIdToken;

  /// App Check token for the relay auth frame. Null provider sends null.
  final AuthTokenProvider? getAppCheckToken;

  final TranscribeAudio? transcribe;
  final ProposePremise? propose;

  final void Function({
    required String title,
    required String synopsis,
    required String narratorLine,
    List<OutlineOption> options,
  })?
  onApply;

  /// Fires when the title, the idea, or the proposed options change.
  /// The wizard footer commits this draft. Typing and dictation share it.
  final PremiseDraftChanged? onDraft;

  /// Inside the node wizard the sheet renders bare: the screen pads
  /// the Idea step itself, so this must not add its own padding.
  final bool embedded;

  @override
  State<PremiseSheet> createState() => _PremiseSheetState();
}

class _PremiseSheetState extends State<PremiseSheet>
    with WidgetsBindingObserver {
  late final TextEditingController _title = TextEditingController(
    text: widget.initialTitle,
  );
  late final TextEditingController _transcript = TextEditingController(
    text: widget.initialIdea,
  );
  late final FocusNode _transcriptFocus = FocusNode();
  late final DictationController _dictation = DictationController(
    seedRecorder: widget.recorder,
    socketFactory: widget.socketFactory,
    getIdToken: widget.getIdToken,
    getAppCheckToken: widget.getAppCheckToken,
    transcribe: widget.transcribe,
  );
  String _beforeDictation = '';
  var _proposing = false;
  var _formatOpen = false;
  var _options = const <OutlineOption>[];

  /// Local Format errors. Dictation hints live on the controller; the
  /// hint line shows whichever is set.
  String? _hint;

  /// Narration Spark returned. Null until Format succeeds. Editing the
  /// idea clears it and brings the Format button back.
  String? _formatted;

  /// Accordion copy: narration, or the title, plus option labels.
  String? _formatPreview;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dictation.onBegin = () {
      _beforeDictation = _transcript.text;
      _writeIdea(listeningPlaceholder);
    };
    _dictation.onPartial = (text) {
      // A tap into the field claims it: live captions stop overwriting.
      if (_transcriptFocus.hasFocus) return;
      _writeIdea(text);
    };
    // Finals always win, even over a focused field.
    _dictation.onFinal = (text) =>
        _writeIdea(text.trim().isEmpty ? _beforeDictation : text);
    _dictation.onEmptyTake = () {
      if (_transcript.text == listeningPlaceholder) {
        _writeIdea(_beforeDictation);
      }
    };
    _dictation.onCap = () {
      if (!mounted) return;
      showNoticeSnackBar(context, 'Recording stopped at the 90-second limit.');
    };
    _dictation.addListener(_onDictation);
  }

  void _onDictation() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding collapses the FAB: finish the live take (or the WAV
    // fallback) instead of recording into the background.
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        _dictation.recording) {
      unawaited(_dictation.stop(send: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dictation.removeListener(_onDictation);
    _dictation.dispose();
    _title.dispose();
    _transcript.dispose();
    _transcriptFocus.dispose();
    super.dispose();
  }

  void _publish() {
    widget.onDraft?.call(
      title: _title.text,
      idea: _draftIdea(),
      options: _options,
    );
  }

  /// Formatted narration when Format has a result; otherwise the field.
  String _draftIdea() {
    final formatted = _formatted?.trim() ?? '';
    if (formatted.isNotEmpty) return formatted;
    return _ideaText();
  }

  void _writeIdea(String value) {
    if (_transcript.text != value) _transcript.text = value;
    _formatted = null;
    _formatPreview = null;
    _formatOpen = false;
    _publish();
  }

  String _ideaText() {
    final text = _transcript.text.trim();
    if (text == listeningPlaceholder) return '';
    return text;
  }

  Future<void> _propose() async {
    final propose = widget.propose;
    final text = _transcript.text.trim();
    if (propose == null ||
        _proposing ||
        text.isEmpty ||
        text == listeningPlaceholder) {
      return;
    }
    setState(() {
      _proposing = true;
      _hint = null;
    });
    try {
      final outline = await propose(text);
      if (!mounted) return;
      final spoken = (outline.narratorLine ?? '').trim();
      final summary = (outline.synopsis ?? '').trim();
      final idea = spoken.isNotEmpty ? spoken : summary;
      final title = (outline.title ?? '').trim();
      final lines = <String>[];
      if (idea.isNotEmpty) {
        lines.add(idea);
      } else if (title.isNotEmpty) {
        lines.add(title);
      }
      for (final option in outline.options) {
        final label = option.label.trim();
        if (label.isNotEmpty) lines.add(label);
      }
      setState(() {
        if (title.isNotEmpty) _title.text = title;
        _formatted = idea.isNotEmpty ? idea : null;
        _formatPreview = lines.isEmpty ? null : lines.join('\n');
        _formatOpen = false;
        _options = List<OutlineOption>.unmodifiable(outline.options);
      });
      _publish();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _hint = dictationHintFor(
          error,
          'Could not propose an outline. Try again.',
        ),
      );
    } finally {
      if (mounted) setState(() => _proposing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = _hint ?? _dictation.hint;
    final fields = Column(
      crossAxisAlignment: .stretch,
      children: [
        TextField(
          key: const ValueKey('premise-title'),
          controller: _title,
          maxLength: 40,
          decoration: _wizardField(
            labelText: 'Title',
            hintText: 'The temple door',
          ),
          onChanged: (_) => _publish(),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TextField(
            key: const ValueKey('premise-transcript'),
            controller: _transcript,
            focusNode: _transcriptFocus,
            readOnly: _dictation.busy,
            expands: true,
            maxLines: null,
            textAlignVertical: .top,
            keyboardType: TextInputType.multiline,
            decoration: _wizardField(
              labelText: 'Tell your idea',
              hintText: 'Record your idea with the mic, or type it here…',
            ).copyWith(alignLabelWithHint: true),
            onChanged: (_) {
              if (_formatted != null || _formatPreview != null) {
                setState(() {
                  _formatted = null;
                  _formatPreview = null;
                  _formatOpen = false;
                });
              }
              _publish();
            },
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 8),
          Text(
            hint,
            style: RamificaText.meta.copyWith(color: RamificaColors.error),
          ),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: .stretch,
            children: [
              DictationVoiceBar(
                prefix: 'premise',
                label: 'Tell your idea out loud',
                recording: _dictation.recording,
                waves: _dictation.waves,
                elapsed: _dictation.elapsed,
                onTap: _dictation.sending ? null : _dictation.toggle,
              ),
              if (widget.propose != null) ...[
                const SizedBox(height: 8),
                _FormatBar(
                  proposing: _proposing,
                  preview: _formatPreview,
                  open: _formatOpen,
                  onFormat: _dictation.busy || _proposing ? null : _propose,
                  onToggle: () => setState(() => _formatOpen = !_formatOpen),
                ),
              ],
              if (widget.onApply != null) ...[
                const SizedBox(height: 8),
                FilledButton(
                  key: const ValueKey('premise-apply'),
                  onPressed: _dictation.busy
                      ? null
                      : () {
                          final idea = _draftIdea();
                          widget.onApply!(
                            title: _title.text.trim(),
                            synopsis: idea,
                            narratorLine: idea,
                            options: _options,
                          );
                        },
                  child: const Text('Apply'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    if (widget.embedded) return fields;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: fields,
      ),
    );
  }
}

/// Same filled field as the other wizard steps.
InputDecoration _wizardField({
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

/// Full-width Format bar. Spark and the label sit on the left. The
/// right control is Format until Spark answers, then a chevron that
/// opens the formatted text.
class _FormatBar extends StatelessWidget {
  const _FormatBar({
    required this.proposing,
    required this.preview,
    required this.open,
    required this.onFormat,
    required this.onToggle,
  });

  final bool proposing;
  final String? preview;
  final bool open;
  final VoidCallback? onFormat;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final ready = preview != null;
    return Container(
      key: const ValueKey('premise-format-bar'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: RamificaColors.containerBase,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RamificaColors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
            child: Row(
              children: [
                const SizedBox(width: 12),
                const Icon(
                  Icons.auto_awesome,
                  size: 20,
                  color: RamificaColors.hotspot,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Order text style', style: RamificaText.label),
                ),
                if (ready)
                  IconButton(
                    key: const ValueKey('premise-format-toggle'),
                    tooltip: open
                        ? 'Hide formatted text'
                        : 'Show formatted text',
                    onPressed: onToggle,
                    icon: Icon(
                      open ? Icons.expand_less : Icons.expand_more,
                      color: RamificaColors.textPrimary,
                    ),
                  )
                else
                  TextButton(
                    key: const ValueKey('premise-propose'),
                    onPressed: proposing ? null : onFormat,
                    child: proposing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Format'),
                  ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: open && preview != null
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Text(
                      preview!,
                      key: const ValueKey('premise-formatted'),
                      style: RamificaText.bodySM,
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
