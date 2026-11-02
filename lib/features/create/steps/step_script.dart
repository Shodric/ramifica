import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/choice_icon.dart';
import 'package:ramifica/data/models/draft_node.dart';
import 'package:ramifica/data/repositories/create_repository.dart';
import 'package:ramifica/features/create/asr_socket.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/dictation/dictation_controller.dart';
import 'package:ramifica/features/create/dictation/dictation_controls.dart';
import 'package:ramifica/features/create/voice_recorder.dart';

/// S1 Script: scene direction (typed or dictated) plus the manual title /
/// ending name editors. New scenes are secret until the player reveals
/// them; there is no visibility toggle. [showErrors] renders error text
/// under each manual field; correcting a field clears its own error live.
///
/// The scene proposal runs automatically on Continue: the wizard calls
/// [StepScriptState.proposeDirection], which calls [propose] with the
/// direction text and returns the normalized [SceneProposal] without
/// writing the node. The manual title and ending name are preserved
/// (returned null) so auto-apply never overwrites them.
class StepScript extends StatefulWidget {
  const StepScript({
    super.key,
    required this.node,
    required this.isRoot,
    required this.busy,
    required this.showErrors,
    this.recorder,
    this.socketFactory,
    this.getIdToken,
    this.getAppCheckToken,
    this.transcribe,
    this.propose,
    this.onTitleChanged,
    this.onEndingNameChanged,
    this.onDirectionChanged,
    this.active = true,
    this.continueAction,
  });

  final DraftNode node;
  final bool isRoot;
  final bool busy;
  final bool showErrors;

  /// Offstage steps skip the continue action so a single one mounts.
  final bool active;

  /// Continue action placed at the step's end. Null renders nothing.
  final Widget? continueAction;

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

  /// Proposal-only `generateNodeText` call for the direction text. Never
  /// writes the node.
  final Future<GeneratedNodeText> Function(String direction)? propose;

  final ValueChanged<String>? onTitleChanged;
  final ValueChanged<String>? onEndingNameChanged;

  /// Direction edits, persisted like any other node field. Dictated
  /// finals report here too; the listening placeholder never does.
  final ValueChanged<String>? onDirectionChanged;

  @override
  StepScriptState createState() => StepScriptState();
}

class StepScriptState extends State<StepScript> with WidgetsBindingObserver {
  late final TextEditingController _title = TextEditingController(
    text: widget.node.title,
  );
  late final TextEditingController _endingName = TextEditingController(
    text: widget.node.endingName ?? '',
  );
  String _beforeDictation = '';
  late final TextEditingController _direction = TextEditingController(
    text: widget.node.sceneDirection ?? '',
  );
  late final FocusNode _directionFocus = FocusNode();
  late final DictationController _dictation = DictationController(
    seedRecorder: widget.recorder,
    socketFactory: widget.socketFactory,
    getIdToken: widget.getIdToken,
    getAppCheckToken: widget.getAppCheckToken,
    transcribe: widget.transcribe,
  );

  var _proposing = false;
  var _proposalGen = 0;
  String? _hint;

  /// Stops an open take, keeping it (transcribe-on-stop). The wizard
  /// calls this before step changes; dispose covers screen exits. Late
  /// socket/transcribe events after the stop are ignored.
  Future<void> stopDictation() {
    if (!_dictation.recording) return Future<void>.value();
    return _dictation.stop(send: true);
  }

  /// True when the direction field holds proposable text.
  bool get directionReady {
    final text = _direction.text.trim();
    return text.isNotEmpty && text != listeningPlaceholder;
  }

  /// Shows an inline step error. The wizard calls this when the
  /// Continue-time apply fails.
  void showError(String message) {
    if (!mounted) return;
    setState(() => _hint = message);
  }

  /// Proposes scene text for the current direction without writing the
  /// node. Stops an open dictation take first so its words join the
  /// direction. Returns null (with an inline hint) when the direction is
  /// empty, generation is unavailable or fails, the direction changed
  /// mid-flight, or Spark returned nothing usable.
  Future<SceneProposal?> proposeDirection() async {
    final propose = widget.propose;
    if (_proposing) return null;
    if (_dictation.recording) await stopDictation();
    if (!mounted) return null;
    if (_dictation.busy) {
      setState(
        () => _hint = 'Wait for transcription to finish, then Continue again.',
      );
      return null;
    }
    final direction = _direction.text.trim();
    if (direction.isEmpty || direction == listeningPlaceholder) {
      setState(() => _hint = 'Describe the scene to generate it.');
      return null;
    }
    if (propose == null) {
      setState(() => _hint = 'Scene generation is unavailable.');
      return null;
    }
    final gen = ++_proposalGen;
    setState(() {
      _proposing = true;
      _hint = null;
    });
    try {
      final answer = await propose(direction);
      if (!mounted || gen != _proposalGen) return null;
      // Late node switches reset the generation, so this answer belongs
      // to the open node.
      final node = widget.node;
      final start = widget.isRoot ? answer.startImagePrompt : null;
      final rawChoices = node.isEnding
          ? const <GeneratedChoice>[]
          : answer.choices;
      final choices = <SceneProposalChoice>[];
      for (final choice in rawChoices) {
        if (choices.length >= 2) break;
        final label = choice.label.trim();
        if (label.isEmpty) continue;
        choices.add(
          SceneProposalChoice(
            label: label.length > 24 ? label.substring(0, 24) : label,
            icon: _knownIcon(choice.icon),
            iconColor: _knownColor(choice.iconColor),
          ),
        );
      }
      final proposal = SceneProposal(
        title: node.title.trim().isNotEmpty ? null : _clip(answer.title, 40),
        ttsText: _clip(answer.ttsText, 280),
        startImagePrompt: _clip(start, 2000),
        videoPrompt: _clip(answer.videoPrompt, 2000),
        endingName: node.isEnding
            ? ((node.endingName?.trim().isNotEmpty ?? false)
                  ? null
                  : _clip(answer.endingName, 40))
            : null,
        choices: choices,
      );
      if (_isEmptyProposal(proposal)) {
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
          'Could not propose a scene. Try again.',
        ),
      );
      return null;
    } finally {
      if (mounted && gen == _proposalGen) {
        setState(() => _proposing = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dictation.onBegin = () {
      _beforeDictation = _direction.text;
      if (_direction.text != listeningPlaceholder) {
        _direction.text = listeningPlaceholder;
      }
    };
    _dictation.onPartial = (text) {
      // A tap into the field claims it: live captions stop overwriting.
      if (_directionFocus.hasFocus) return;
      _direction.text = text;
    };
    // Finals always win, even over a focused field.
    _dictation.onFinal = (text) {
      _direction.text = text.trim().isEmpty ? _beforeDictation : text;
      _notifyDirection();
    };
    _dictation.onEmptyTake = () {
      if (_direction.text == listeningPlaceholder) {
        _direction.text = _beforeDictation;
        _notifyDirection();
      }
    };
    _dictation.onCap = () {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recording stopped: 90 second limit.'),
          duration: Duration(seconds: 2),
        ),
      );
    };
    _dictation.addListener(_onDictation);
  }

  void _onDictation() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        _dictation.recording) {
      unawaited(_dictation.stop(send: true));
    }
  }

  @override
  void didUpdateWidget(covariant StepScript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.nodeId != widget.node.nodeId) {
      _proposalGen++;
      _proposing = false;
      _dictation.cancel();
      _direction.text = widget.node.sceneDirection ?? '';
      _title.text = widget.node.title;
      _endingName.text = widget.node.endingName ?? '';
    } else {
      _setIfDifferent(_title, widget.node.title);
      _setIfDifferent(_endingName, widget.node.endingName ?? '');
      // Never clobber typing, live captions, or the placeholder.
      if (!_directionFocus.hasFocus && !_dictation.recording) {
        _setIfDifferent(_direction, widget.node.sceneDirection ?? '');
      }
    }
  }

  /// Reports the field to the node, except the listening placeholder.
  void _notifyDirection() {
    final text = _direction.text;
    if (text == listeningPlaceholder) return;
    widget.onDirectionChanged?.call(text);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _proposalGen++;
    _dictation.removeListener(_onDictation);
    _dictation.dispose();
    _title.dispose();
    _endingName.dispose();
    _direction.dispose();
    _directionFocus.dispose();
    super.dispose();
  }

  bool _isEmptyProposal(SceneProposal proposal) {
    return (proposal.title == null || proposal.title!.isEmpty) &&
        (proposal.ttsText == null || proposal.ttsText!.isEmpty) &&
        (proposal.startImagePrompt == null ||
            proposal.startImagePrompt!.isEmpty) &&
        (proposal.videoPrompt == null || proposal.videoPrompt!.isEmpty) &&
        (proposal.endingName == null || proposal.endingName!.isEmpty) &&
        proposal.choices.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final nodeId = node.nodeId;
    final title = node.title.trim();
    final titleError =
        widget.showErrors && (title.isEmpty || node.title.length > 40);
    final transcribing = _dictation.busy;
    final direction = TextField(
      key: ValueKey('script-direction-$nodeId'),
      controller: _direction,
      focusNode: _directionFocus,
      enabled: !widget.busy,
      readOnly: transcribing,
      expands: true,
      maxLines: null,
      minLines: null,
      maxLength: 2000,
      buildCounter:
          (
            _, {
            required int currentLength,
            required bool isFocused,
            required int? maxLength,
          }) => currentLength >= (maxLength ?? 2000)
          ? Text(
              '$currentLength/${maxLength ?? 2000}',
              style: RamificaText.meta,
            )
          : null,
      textAlignVertical: .top,
      decoration: _scriptInputDecoration(
        hintText: 'Dictate or type what Spark should propose…',
      ),
      onChanged: (_) {
        // Invalidates an in-flight proposal; the stale answer is discarded.
        _proposalGen++;
        _notifyDirection();
      },
    );
    // Bounded (the app step area): the direction field fills the leftover
    // height with no outer scroll. Unbounded (a scrollable parent): a
    // fixed tall direction box, page scrolls as before.
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded = constraints.maxHeight.isFinite;
        return Column(
          crossAxisAlignment: .stretch,
          mainAxisSize: bounded ? .max : .min,
          children: [
            TextField(
              key: ValueKey('title-$nodeId'),
              controller: _title,
              enabled: !widget.busy,
              maxLength: 40,
              buildCounter:
                  (
                    _, {
                    required int currentLength,
                    required bool isFocused,
                    required int? maxLength,
                  }) => currentLength >= (maxLength ?? 40)
                  ? Text(
                      '$currentLength/${maxLength ?? 40}',
                      style: RamificaText.meta,
                    )
                  : null,
              decoration:
                  _scriptInputDecoration(
                    labelText: 'Scene title',
                    hintText: 'The temple door',
                  ).copyWith(
                    errorText: titleError
                        ? 'Give it a title (1-40 characters)'
                        : null,
                  ),
              onChanged: widget.onTitleChanged,
            ),
            const SizedBox(height: 8),
            bounded
                ? Expanded(child: direction)
                : SizedBox(height: 320, child: direction),
            const SizedBox(height: 8),
            DictationVoiceBar(
              prefix: 'script-direction',
              label: 'Dictate direction',
              recording: _dictation.recording,
              waves: _dictation.waves,
              elapsed: _dictation.elapsed,
              onTap: widget.busy || _dictation.sending || _proposing
                  ? null
                  : _dictation.toggle,
            ),
            if (_dictation.hint != null || _hint != null) ...[
              const SizedBox(height: 8),
              Text(
                _hint ?? _dictation.hint ?? '',
                style: RamificaText.meta.copyWith(color: RamificaColors.error),
              ),
            ],
            if (_proposing) ...[
              const SizedBox(height: 8),
              Row(
                key: ValueKey('script-proposing-$nodeId'),
                children: const [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Proposing scene…', style: RamificaText.meta),
                ],
              ),
            ],
            if (node.isEnding) ...[
              const SizedBox(height: 8),
              TextField(
                key: ValueKey('ending-name-$nodeId'),
                controller: _endingName,
                enabled: !widget.busy,
                maxLength: 40,
                decoration: _scriptInputDecoration(
                  labelText: 'Ending name',
                  hintText: 'Dawn',
                ),
                onChanged: widget.onEndingNameChanged,
              ),
              const SizedBox(height: 8),
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

void _setIfDifferent(TextEditingController controller, String value) {
  if (controller.text != value) controller.text = value;
}

String? _clip(String? value, int max) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length <= max) return trimmed;
  return trimmed.substring(0, max);
}

String? _knownIcon(String? name) {
  if (name == null || name.isEmpty) return null;
  for (final option in choiceIconOptions) {
    if (option.name == name) return name;
  }
  return null;
}

String? _knownColor(String? name) {
  if (name == null || name.isEmpty) return null;
  for (final option in choiceColorOptions) {
    if (option.name == name) return name;
  }
  return null;
}

InputDecoration _scriptInputDecoration({
  String? labelText,
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
