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

/// S1 Script: scene direction (typed or dictated) plus a reviewable Spark
/// proposal, then the manual title / ending name editors. New scenes are
/// secret until the player reveals them; there is no visibility toggle.
/// [showErrors] renders error text under each manual field; correcting a
/// field clears its own error live.
///
/// Format is proposal-only: [propose] calls `generateNodeText` and the
/// answer stays in widget state as an editable accordion — the node is
/// never mutated. [onApplyProposal] sends the reviewed [SceneProposal]
/// (every non-empty field plus up to two branches); Apply overwrites with
/// each non-empty reviewed value and creates missing branches.
/// Null [propose] hides the whole proposal block.
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
    this.onApplyProposal,
    this.onTitleChanged,
    this.onEndingNameChanged,
  });

  final DraftNode node;
  final bool isRoot;
  final bool busy;
  final bool showErrors;

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

  /// Proposal-only `generateNodeText` call for the direction text. Null
  /// hides the Format block. Never writes the node.
  final Future<GeneratedNodeText> Function(String direction)? propose;

  /// Reviewed proposal from the accordion. The screen dispatches
  /// `SceneProposalApplied` with it.
  final ValueChanged<SceneProposal>? onApplyProposal;

  final ValueChanged<String>? onTitleChanged;
  final ValueChanged<String>? onEndingNameChanged;

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
  final TextEditingController _direction = TextEditingController();
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
  var _formatOpen = false;
  String? _hint;

  /// Last formatted proposal, normalized for this node (child start is
  /// null, endings carry no choices). Null until Format succeeds.
  SceneProposal? _proposal;

  // Editable accordion copies, seeded from [_proposal] on Format.
  // Every non-empty reviewed value overwrites on Apply; blanks are skipped.
  final TextEditingController _pTitle = TextEditingController();
  final TextEditingController _pLine = TextEditingController();
  final TextEditingController _pStart = TextEditingController();
  final TextEditingController _pVideo = TextEditingController();
  final TextEditingController _pEnding = TextEditingController();
  final List<_ChoiceEdit> _pChoices = [];

  /// Stops an open take, keeping it (transcribe-on-stop). The wizard
  /// calls this before step changes; dispose covers screen exits. Late
  /// socket/transcribe events after the stop are ignored.
  Future<void> stopDictation() {
    if (!_dictation.recording) return Future<void>.value();
    return _dictation.stop(send: true);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dictation.onBegin = () {
      _beforeDictation = _direction.text;
      _clearProposal();
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
    _dictation.onFinal = (text) =>
        _direction.text = text.trim().isEmpty ? _beforeDictation : text;
    _dictation.onEmptyTake = () {
      if (_direction.text == listeningPlaceholder) {
        _direction.text = _beforeDictation;
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
      _direction.clear();
      _clearProposal();
      _title.text = widget.node.title;
      _endingName.text = widget.node.endingName ?? '';
    } else {
      _setIfDifferent(_title, widget.node.title);
      _setIfDifferent(_endingName, widget.node.endingName ?? '');
    }
  }

  void _clearProposal() {
    _proposal = null;
    _formatOpen = false;
    _pTitle.clear();
    _pLine.clear();
    _pStart.clear();
    _pVideo.clear();
    _pEnding.clear();
    _disposeChoices();
  }

  void _disposeChoices() {
    for (final choice in _pChoices) {
      choice.label.dispose();
    }
    _pChoices.clear();
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
    _pTitle.dispose();
    _pLine.dispose();
    _pStart.dispose();
    _pVideo.dispose();
    _pEnding.dispose();
    _disposeChoices();
    super.dispose();
  }

  Future<void> _format() async {
    final propose = widget.propose;
    final direction = _direction.text.trim();
    if (propose == null ||
        _proposing ||
        direction.isEmpty ||
        direction == listeningPlaceholder) {
      return;
    }
    final gen = ++_proposalGen;
    setState(() {
      _proposing = true;
      _hint = null;
    });
    try {
      final answer = await propose(direction);
      if (!mounted || gen != _proposalGen) return;
      // Late node switches reset the generation, so this answer belongs
      // to the open node.
      final start = widget.isRoot ? answer.startImagePrompt : null;
      final rawChoices = widget.node.isEnding
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
        title: _clip(answer.title, 40),
        ttsText: _clip(answer.ttsText, 280),
        startImagePrompt: _clip(start, 2000),
        videoPrompt: _clip(answer.videoPrompt, 2000),
        endingName: widget.node.isEnding ? _clip(answer.endingName, 40) : null,
        choices: choices,
      );
      if (_isEmptyProposal(proposal)) {
        setState(() => _hint = 'Spark returned nothing usable. Try again.');
        return;
      }
      setState(() {
        _proposal = proposal;
        _pTitle.text = proposal.title ?? '';
        _pLine.text = proposal.ttsText ?? '';
        _pStart.text = proposal.startImagePrompt ?? '';
        _pVideo.text = proposal.videoPrompt ?? '';
        _pEnding.text = proposal.endingName ?? '';
        _disposeChoices();
        for (final choice in proposal.choices) {
          _pChoices.add(_ChoiceEdit(choice));
        }
        _formatOpen = true;
      });
    } catch (error) {
      if (!mounted || gen != _proposalGen) return;
      setState(
        () => _hint = dictationHintFor(
          error,
          'Could not propose a scene. Try again.',
        ),
      );
    } finally {
      if (mounted && gen == _proposalGen) {
        setState(() => _proposing = false);
      }
    }
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

  /// Counts what Apply WILL write: every non-empty reviewed text field plus
  /// every non-empty proposed option (overwrite or new branch, max two).
  /// Endings never carry branches; child start prompts are forced null.
  ({int fields, int branches}) _applyCounts() {
    if (_proposal == null) return (fields: 0, branches: 0);
    final node = widget.node;
    var fields = 0;
    if (_pTitle.text.trim().isNotEmpty) fields++;
    if (_pLine.text.trim().isNotEmpty) fields++;
    if (widget.isRoot && _pStart.text.trim().isNotEmpty) fields++;
    if (_pVideo.text.trim().isNotEmpty) fields++;
    if (node.isEnding && _pEnding.text.trim().isNotEmpty) fields++;
    var branches = 0;
    if (!node.isEnding) {
      for (final choice in _pChoices) {
        if (choice.label.text.trim().isNotEmpty) {
          branches++;
          if (branches >= 2) break;
        }
      }
    }
    return (fields: fields, branches: branches);
  }

  void _apply() {
    final counts = _applyCounts();
    if (_proposal == null || counts.fields + counts.branches == 0) return;
    final node = widget.node;
    final choices = node.isEnding
        ? const <SceneProposalChoice>[]
        : [
            for (final choice in _pChoices)
              if (choice.label.text.trim().isNotEmpty)
                SceneProposalChoice(
                  label: _clipLabel(choice.label.text.trim()),
                  icon: choice.icon,
                  iconColor: choice.iconColor,
                ),
          ].take(2).toList();
    widget.onApplyProposal?.call(
      SceneProposal(
        title: _clip(_nullIfBlank(_pTitle.text), 40),
        ttsText: _clip(_nullIfBlank(_pLine.text), 280),
        startImagePrompt: widget.isRoot
            ? _clip(_nullIfBlank(_pStart.text), 2000)
            : null,
        videoPrompt: _clip(_nullIfBlank(_pVideo.text), 2000),
        endingName: node.isEnding
            ? _clip(_nullIfBlank(_pEnding.text), 40)
            : null,
        choices: choices,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final nodeId = node.nodeId;
    final title = node.title.trim();
    final titleError =
        widget.showErrors && (title.isEmpty || node.title.length > 40);
    final transcribing = _dictation.busy;
    final directionReady =
        _direction.text.trim().isNotEmpty &&
        _direction.text.trim() != listeningPlaceholder;
    final counts = _applyCounts();
    final applicable = counts.fields + counts.branches;
    final canApply =
        _proposal != null &&
        !widget.busy &&
        !_proposing &&
        !transcribing &&
        applicable > 0;
    final direction = TextField(
      key: ValueKey('script-direction-$nodeId'),
      controller: _direction,
      focusNode: _directionFocus,
      enabled: !widget.busy,
      readOnly: transcribing,
      expands: true,
      maxLines: null,
      minLines: null,
      textAlignVertical: .top,
      decoration: _scriptInputDecoration(
        hintText: 'Dictate or type what Spark should propose…',
      ),
      onChanged: (_) => setState(() {
        _proposalGen++;
        _clearProposal();
      }),
    );
    Widget accordion() => _ProposalAccordion(
      nodeId: nodeId,
      node: node,
      isRoot: widget.isRoot,
      busy: widget.busy,
      title: _pTitle,
      line: _pLine,
      start: _pStart,
      video: _pVideo,
      ending: _pEnding,
      choices: _pChoices,
      onChanged: () => setState(() {}),
      onAddChoice: _pChoices.length >= 2
          ? null
          : () => setState(() => _pChoices.add(_ChoiceEdit.empty())),
      onRemoveChoice: (index) => setState(() {
        _pChoices[index].label.dispose();
        _pChoices.removeAt(index);
      }),
    );
    // Bounded (the app step area): the direction field fills the leftover
    // height with no outer scroll; the open proposal accordion scrolls
    // within its own share. Unbounded (a scrollable parent): a fixed tall
    // direction box, page scrolls as before.
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
            if (widget.propose != null) ...[
              const SizedBox(height: 8),
              _ProposalBar(
                nodeId: nodeId,
                proposing: _proposing,
                hasProposal: _proposal != null,
                open: _formatOpen,
                onFormat: widget.busy || transcribing || _proposing
                    ? null
                    : (directionReady ? _format : null),
                onToggle: () => setState(() => _formatOpen = !_formatOpen),
              ),
              if (_proposal != null && _formatOpen) ...[
                const SizedBox(height: 8),
                bounded
                    ? Expanded(child: SingleChildScrollView(child: accordion()))
                    : accordion(),
                const SizedBox(height: 8),
                FilledButton(
                  key: ValueKey('script-apply-$nodeId'),
                  onPressed: canApply ? _apply : null,
                  child: Text(_applyLabel(counts)),
                ),
              ] else if (_proposal != null && !_formatOpen) ...[
                const SizedBox(height: 8),
                FilledButton(
                  key: ValueKey('script-apply-$nodeId'),
                  onPressed: canApply ? _apply : null,
                  child: Text(_applyLabel(counts)),
                ),
              ],
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
          ],
        );
      },
    );
  }
}

String _applyLabel(({int fields, int branches}) counts) {
  final total = counts.fields + counts.branches;
  if (total == 0) return 'Apply';
  final parts = <String>[];
  if (counts.fields > 0) {
    parts.add('${counts.fields} field${counts.fields == 1 ? '' : 's'}');
  }
  if (counts.branches > 0) {
    parts.add('${counts.branches} branch${counts.branches == 1 ? '' : 'es'}');
  }
  return 'Apply (${parts.join(', ')})';
}

void _setIfDifferent(TextEditingController controller, String value) {
  if (controller.text != value) controller.text = value;
}

String? _nullIfBlank(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _clip(String? value, int max) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length <= max) return trimmed;
  return trimmed.substring(0, max);
}

String _clipLabel(String label) {
  final trimmed = label.trim();
  if (trimmed.length <= 24) return trimmed;
  return trimmed.substring(0, 24);
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

class _ChoiceEdit {
  _ChoiceEdit(SceneProposalChoice choice)
    : label = TextEditingController(text: choice.label),
      icon = choice.icon,
      iconColor = choice.iconColor;

  _ChoiceEdit.empty()
    : label = TextEditingController(),
      icon = null,
      iconColor = null;

  final TextEditingController label;
  String? icon;
  String? iconColor;
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

/// Proposal bar: the Format CTA until Spark answers, then a chevron that
/// opens the editable proposal. Format never writes the node — the
/// accordion below holds the answer for review.
class _ProposalBar extends StatelessWidget {
  const _ProposalBar({
    required this.nodeId,
    required this.proposing,
    required this.hasProposal,
    required this.open,
    required this.onFormat,
    required this.onToggle,
  });

  final String nodeId;
  final bool proposing;
  final bool hasProposal;
  final bool open;
  final VoidCallback? onFormat;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('script-proposal-bar-$nodeId'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: RamificaColors.containerBase,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RamificaColors.outlineVariant),
      ),
      child: Padding(
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
              child: Text('Scene proposal', style: RamificaText.label),
            ),
            if (hasProposal)
              IconButton(
                key: ValueKey('script-proposal-toggle-$nodeId'),
                tooltip: open ? 'Hide proposal' : 'Show proposal',
                onPressed: onToggle,
                icon: Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  color: RamificaColors.textPrimary,
                ),
              )
            else
              TextButton(
                key: ValueKey('script-format-$nodeId'),
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
    );
  }
}

/// Editable proposal: every field stays editable and Apply overwrites with
/// each non-empty reviewed value. The start prompt row hides on children
/// (S is inherited); options hide on endings.
class _ProposalAccordion extends StatelessWidget {
  const _ProposalAccordion({
    required this.nodeId,
    required this.node,
    required this.isRoot,
    required this.busy,
    required this.title,
    required this.line,
    required this.start,
    required this.video,
    required this.ending,
    required this.choices,
    required this.onChanged,
    required this.onAddChoice,
    required this.onRemoveChoice,
  });

  final String nodeId;
  final DraftNode node;
  final bool isRoot;
  final bool busy;
  final TextEditingController title;
  final TextEditingController line;
  final TextEditingController start;
  final TextEditingController video;
  final TextEditingController ending;
  final List<_ChoiceEdit> choices;
  final VoidCallback onChanged;
  final VoidCallback? onAddChoice;
  final void Function(int index) onRemoveChoice;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('script-proposal-$nodeId'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: RamificaColors.containerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: RamificaColors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: .stretch,
          mainAxisSize: .min,
          children: [
            _ProposalField(
              fieldKey: ValueKey('script-prop-title-$nodeId'),
              controller: title,
              label: 'Title',
              busy: busy,
              maxLength: 40,
              maxLines: 1,
              onChanged: onChanged,
            ),
            const SizedBox(height: 8),
            _ProposalField(
              fieldKey: ValueKey('script-prop-line-$nodeId'),
              controller: line,
              label: 'Narrator line',
              busy: busy,
              maxLength: 280,
              maxLines: 3,
              onChanged: onChanged,
            ),
            if (isRoot) ...[
              const SizedBox(height: 8),
              _ProposalField(
                fieldKey: ValueKey('script-prop-start-$nodeId'),
                controller: start,
                label: 'Start image prompt',
                busy: busy,
                maxLength: 2000,
                maxLines: 4,
                onChanged: onChanged,
              ),
            ],
            const SizedBox(height: 8),
            _ProposalField(
              fieldKey: ValueKey('script-prop-video-$nodeId'),
              controller: video,
              label: 'Video prompt',
              busy: busy,
              maxLength: 2000,
              maxLines: 4,
              onChanged: onChanged,
            ),
            if (!node.isEnding) ...[
              const SizedBox(height: 16),
              Text('Options', style: RamificaText.labelSM),
              const SizedBox(height: 8),
              for (var i = 0; i < choices.length; i++)
                _OptionRow(
                  nodeId: nodeId,
                  index: i,
                  edit: choices[i],
                  busy: busy,
                  onChanged: onChanged,
                  onRemove: () => onRemoveChoice(i),
                ),
              if (onAddChoice != null)
                TextButton.icon(
                  key: ValueKey('script-prop-add-opt-$nodeId'),
                  onPressed: busy ? null : onAddChoice,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add option'),
                ),
            ],
            if (node.isEnding) ...[
              const SizedBox(height: 8),
              _ProposalField(
                fieldKey: ValueKey('script-prop-ending-$nodeId'),
                controller: ending,
                label: 'Ending name',
                busy: busy,
                maxLength: 40,
                maxLines: 1,
                onChanged: onChanged,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One editable option row: label plus icon/color catalog selects.
/// All three always stay editable; Apply overwrites per slot.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.nodeId,
    required this.index,
    required this.edit,
    required this.busy,
    required this.onChanged,
    required this.onRemove,
  });

  final String nodeId;
  final int index;
  final _ChoiceEdit edit;
  final bool busy;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          Row(
            children: [
              Expanded(
                child: _ProposalField(
                  fieldKey: ValueKey('script-prop-opt-label-$nodeId-$index'),
                  controller: edit.label,
                  label: 'Option ${index == 0 ? 'A' : 'B'}',
                  busy: busy,
                  maxLength: 24,
                  maxLines: 1,
                  onChanged: onChanged,
                ),
              ),
              IconButton(
                key: ValueKey('script-prop-opt-remove-$nodeId-$index'),
                tooltip: 'Remove option',
                onPressed: busy ? null : onRemove,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  key: ValueKey('script-prop-opt-icon-$nodeId-$index'),
                  initialValue: edit.icon,
                  decoration: _scriptInputDecoration(
                    labelText: 'Icon',
                    hintText: 'None',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('None'),
                    ),
                    for (final option in choiceIconOptions)
                      DropdownMenuItem<String?>(
                        value: option.name,
                        child: Text(option.label),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) {
                          edit.icon = value;
                          onChanged();
                        },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  key: ValueKey('script-prop-opt-color-$nodeId-$index'),
                  initialValue: edit.iconColor,
                  decoration: _scriptInputDecoration(
                    labelText: 'Color',
                    hintText: 'Auto',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Auto'),
                    ),
                    for (final option in choiceColorOptions)
                      DropdownMenuItem<String?>(
                        value: option.name,
                        child: Text(option.label),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) {
                          edit.iconColor = value;
                          onChanged();
                        },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProposalField extends StatelessWidget {
  const _ProposalField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.busy,
    required this.maxLength,
    required this.maxLines,
    required this.onChanged,
  });
  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final bool busy;
  final int maxLength;
  final int maxLines;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      enabled: !busy,
      maxLength: maxLength,
      maxLines: maxLines,
      decoration: _scriptInputDecoration(labelText: label, hintText: ''),
      onChanged: (_) => onChanged(),
    );
  }
}
