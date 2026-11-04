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
/// Wired to `proposeStoryOutline`; null means section fill is unavailable.
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

/// A Spark premise proposal: title plus the polished idea plus up to
/// two opening options. Proposal-only: [PremiseSheetState.proposeIdea]
/// returns it without writing the fields; the section preview shows it
/// for Accept/Discard and [PremiseSheetState.applyProposal] writes it.
class PremiseProposal {
  const PremiseProposal({this.title, this.idea, this.options = const []});

  final String? title;
  final String? idea;
  final List<OutlineOption> options;

  /// True when the proposal carries nothing usable.
  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (idea == null || idea!.isEmpty) &&
      options.isEmpty;
}

/// Step 0 premise: a title plus one idea field. Dictation and typing
/// write that same field. While recording it reads [listeningPlaceholder];
/// stopping sends the audio to [transcribe] and the returned text
/// replaces the field. The section proposal runs from the AppBar spark:
/// the wizard calls [PremiseSheetState.proposeIdea], previews the answer
/// for Accept/Discard, and applies it through
/// [PremiseSheetState.applyProposal]. The field fills the height it is
/// given.
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
  PremiseSheetState createState() => PremiseSheetState();
}

class PremiseSheetState extends State<PremiseSheet>
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
  var _proposalGen = 0;
  var _options = const <OutlineOption>[];

  /// Local proposal errors. Dictation hints live on the controller; the
  /// hint line shows whichever is set.
  String? _hint;

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
    // Invalidates an in-flight proposal; the stale answer is discarded.
    _proposalGen++;
    widget.onDraft?.call(
      title: _title.text,
      idea: _ideaText(),
      options: _options,
    );
  }

  void _writeIdea(String value) {
    if (_transcript.text != value) _transcript.text = value;
    _publish();
  }

  String _ideaText() {
    final text = _transcript.text.trim();
    if (text == listeningPlaceholder) return '';
    return text;
  }

  /// Stops an open take, keeping it (transcribe-on-stop). Late
  /// socket/transcribe events after the stop are ignored.
  Future<void> stopDictation() {
    if (!_dictation.recording) return Future<void>.value();
    return _dictation.stop(send: true);
  }

  /// True when the idea field holds proposable text.
  bool get ideaReady {
    final text = _transcript.text.trim();
    return text.isNotEmpty && text != listeningPlaceholder;
  }

  /// Takes the pending proposal failure for the wizard snackbar and
  /// clears the inline hint, so the error shows once. Null when the
  /// last proposal did not fail.
  String? takeProposalError() {
    final error = _hint;
    if (error != null && mounted) setState(() => _hint = null);
    return error;
  }

  /// Proposes an outline for the current idea without writing the
  /// fields. Stops an open dictation take first so its words join the
  /// idea. Returns null when the idea is empty, generation is
  /// unavailable or fails, the idea changed mid-flight, or Spark
  /// returned nothing usable; the reason waits in [takeProposalError]
  /// for the wizard snackbar.
  Future<PremiseProposal?> proposeIdea() async {
    final propose = widget.propose;
    if (_proposing) return null;
    if (_dictation.recording) await stopDictation();
    if (!mounted) return null;
    if (_dictation.busy) {
      setState(
        () => _hint = 'Wait for transcription to finish, then try again.',
      );
      return null;
    }
    final text = _transcript.text.trim();
    if (text.isEmpty || text == listeningPlaceholder) {
      setState(() => _hint = 'Describe your idea to format it.');
      return null;
    }
    if (propose == null) {
      setState(() => _hint = 'Idea generation is unavailable.');
      return null;
    }
    final gen = ++_proposalGen;
    setState(() {
      _proposing = true;
      _hint = null;
    });
    try {
      final outline = await propose(text);
      if (!mounted || gen != _proposalGen) return null;
      final spoken = (outline.narratorLine ?? '').trim();
      final summary = (outline.synopsis ?? '').trim();
      final idea = spoken.isNotEmpty ? spoken : summary;
      final options = <OutlineOption>[];
      for (final option in outline.options) {
        if (options.length >= 2) break;
        final label = option.label.trim();
        if (label.isEmpty) continue;
        options.add(
          OutlineOption(
            label: label.length > 24 ? label.substring(0, 24) : label,
            icon: option.icon,
            iconColor: option.iconColor,
          ),
        );
      }
      final proposal = PremiseProposal(
        title: _clip(outline.title, 40),
        idea: idea.isEmpty ? null : idea,
        options: options,
      );
      if (proposal.isEmpty) {
        if (mounted && gen == _proposalGen) {
          setState(() => _hint = 'Spark returned nothing usable. Try again.');
        }
        return null;
      }
      return proposal;
    } catch (error) {
      if (!mounted || gen != _proposalGen) return null;
      setState(
        () => _hint = dictationHintFor(
          error,
          'Could not propose an outline. Try again.',
        ),
      );
      return null;
    } finally {
      if (mounted && gen == _proposalGen) {
        setState(() => _proposing = false);
      }
    }
  }

  /// Writes a reviewed [proposal] into the fields: the title, the idea,
  /// and the proposed options. The wizard footer commits them.
  void applyProposal(PremiseProposal proposal) {
    if (!mounted) return;
    setState(() {
      if (proposal.title != null && proposal.title!.isNotEmpty) {
        _title.text = proposal.title!;
      }
      if (proposal.idea != null && proposal.idea!.isNotEmpty) {
        _transcript.text = proposal.idea!;
      }
      _options = List<OutlineOption>.unmodifiable(proposal.options);
    });
    _publish();
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
            onChanged: (_) => _publish(),
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
              if (widget.onApply != null) ...[
                const SizedBox(height: 8),
                FilledButton(
                  key: const ValueKey('premise-apply'),
                  onPressed: _dictation.busy
                      ? null
                      : () {
                          final idea = _ideaText();
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

String? _clip(String? value, int max) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length <= max) return trimmed;
  return trimmed.substring(0, max);
}
