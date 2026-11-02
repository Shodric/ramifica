import 'package:ramifica/data/models/app_failure.dart';

import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/status_pill.dart';
import 'package:ramifica/features/create/asr_socket.dart';
import 'package:ramifica/features/create/create_bloc.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/premise_sheet.dart';
import 'package:ramifica/features/create/steps/wizard_gates.dart';
import 'package:uuid/uuid.dart';

/// Sticky wizard chrome: tappable stepper, and the footer with save status
/// plus Back/Continue. Never toasts: the step reports its first missing
/// piece as an inline red banner above the footer, and field errors render
/// under their own control.
///
/// Scene titles live in the AppBar now. [sceneNumber], [sceneTotal],
/// [title], and [status] are unused by the header itself and are kept only
/// for test compat; the stepper chips below are unchanged.
class WizardHeader extends StatelessWidget {
  const WizardHeader({
    super.key,
    required this.sceneNumber,
    required this.sceneTotal,
    required this.title,
    required this.status,
    required this.stepIndex,
    required this.firstIncomplete,
    required this.onStepTap,
    required this.isRoot,
    this.showIdea = false,
    this.ideaCurrent = false,
    this.ideaDone = false,
    this.onIdea,
  });

  final int sceneNumber;
  final int sceneTotal;
  final String title;
  final StatusPillState status;

  /// Logical step ids; [onStepTap] receives the logical id.
  final int stepIndex;
  final int firstIncomplete;
  final ValueChanged<int> onStepTap;
  final bool isRoot;

  /// Root-only Idea chip, before Script.
  final bool showIdea;
  final bool ideaCurrent;
  final bool ideaDone;
  final VoidCallback? onIdea;

  @override
  Widget build(BuildContext context) {
    final steps = wizardSteps(isRoot: isRoot);
    return Row(
      children: [
        if (showIdea)
          Expanded(
            child: _StepChip(
              index: -1,
              label: 'Idea',
              current: ideaCurrent,
              done: ideaDone,
              enabled: true,
              onTap: onIdea ?? () {},
            ),
          ),
        for (var position = 0; position < steps.length; position++) ...[
          if (showIdea || position > 0) const SizedBox(width: 6),
          Expanded(
            child: _StepChip(
              index: steps[position],
              current: steps[position] == stepIndex,
              done: steps[position] < firstIncomplete,
              enabled: steps[position] <= firstIncomplete,
              onTap: () => onStepTap(steps[position]),
            ),
          ),
        ],
      ],
    );
  }
}

class _StepChip extends StatelessWidget {
  const _StepChip({
    required this.index,
    required this.current,
    required this.done,
    required this.enabled,
    required this.onTap,
    this.label,
  });

  final int index;
  final String? label;
  final bool current;
  final bool done;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = this.label ?? wizardStepTitles[index];
    return InkWell(
      key: ValueKey(index < 0 ? 'wizard-step-idea' : 'wizard-step-$index'),
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: current
              ? RamificaColors.containerBase
              : RamificaColors.containerLow,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: current
                ? RamificaColors.hotspot
                : RamificaColors.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisAlignment: .center,
          mainAxisSize: .min,
          children: [
            if (done)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.check,
                  size: 12,
                  color: RamificaColors.nodeActive,
                ),
              ),
            Flexible(
              child: Text(
                label,
                style: RamificaText.labelSM.copyWith(
                  fontSize: 10,
                  color: enabled
                      ? RamificaColors.textPrimary
                      : RamificaColors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline red banner over the footer: the first missing piece of the
/// current step. Stays on screen until the author fixes it.
class WizardBanner extends StatelessWidget {
  const WizardBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('wizard-banner'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: RamificaColors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: RamificaColors.error),
      ),
      child: Text(
        'Still missing: $text',
        style: RamificaText.bodySM.copyWith(color: RamificaColors.error),
      ),
    );
  }
}

/// Full-width rectangular Continue, placed inside each step's own
/// layout instead of a shell footer. Step changes go through the
/// stepper chips; there is no Back. While busy the label swaps for
/// a spinner.
///
/// The screen builds one instance and hands it to every step; each
/// step mounts it only while active, so a single `wizard-continue`
/// exists at a time.
class WizardContinueButton extends StatelessWidget {
  const WizardContinueButton({
    super.key,
    required this.busy,
    required this.onContinue,
    required this.isLastStep,
    this.continueLabel,
  });

  final bool busy;
  final VoidCallback onContinue;
  final bool isLastStep;

  /// Null uses Continue, or Finish on the last step.
  final String? continueLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: FilledButton(
        key: const ValueKey('wizard-continue'),
        onPressed: busy ? null : onContinue,
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: RamificaColors.textPrimary,
                ),
              )
            : Text(continueLabel ?? (isLastStep ? 'Finish' : 'Continue')),
      ),
    );
  }
}

/// Step 0, before Script. The root stepper leads with an Idea chip.
/// The body is one title plus the idea field, in the same inputs as the
/// other steps. Typing and Continue keep the premise local. Save or Apply persists it.
class WizardPremise extends StatefulWidget {
  const WizardPremise({super.key, this.continueAction});

  /// Continue action placed under the premise fields. Null renders
  /// the fields alone.
  final Widget? continueAction;

  @override
  State<WizardPremise> createState() => WizardPremiseState();
}

class WizardPremiseState extends State<WizardPremise> {
  final _sessionId = const Uuid().v4();
  var _seeded = false;
  var _title = '';
  var _idea = '';
  var _seedTitle = '';
  var _seedIdea = '';
  var _options = const <OutlineOption>[];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    final state = context.read<CreateBloc>().state;
    final story = state.story;
    if (story == null) return;
    _title = story.title;
    var idea = story.synopsis.trim();
    if (idea.isEmpty) {
      for (final node in state.nodes) {
        if (node.nodeId == story.rootNodeId) {
          idea = node.ttsText;
          break;
        }
      }
    }
    _idea = idea;
    _seedTitle = _title;
    _seedIdea = _idea;
  }

  /// Saves the premise as the story synopsis; the decision narration
  /// belongs to S3. Skips unchanged drafts with no proposed options.
  void commit() {
    final bloc = context.read<CreateBloc>();
    if (bloc.state.story == null) return;
    final title = _title.trim();
    final idea = _idea.trim() == listeningPlaceholder ? '' : _idea.trim();
    final unchanged =
        title == _seedTitle.trim() &&
        idea == _seedIdea.trim() &&
        _options.isEmpty;
    if (unchanged && !bloc.hasUnsavedStoryEdits) return;
    bloc.add(OutlineApplied(title: title, synopsis: idea, options: _options));
  }

  Future<String?> _idToken() async {
    try {
      return await FirebaseAuth.instance.currentUser?.getIdToken();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _appCheckToken() async {
    try {
      return await FirebaseAppCheck.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  void _onDraft({
    required String title,
    required String idea,
    required List<OutlineOption> options,
  }) {
    _title = title;
    _idea = idea;
    _options = options;
    context.read<CreateBloc>().add(
      StoryFieldChanged(title: title, synopsis: idea),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<CreateBloc>();
    final story = bloc.state.story;
    if (story == null) return const SizedBox.shrink();
    final repository = bloc.repository;
    return Column(
      crossAxisAlignment: .stretch,
      children: [
        Expanded(
          child: PremiseSheet(
            key: const ValueKey('wizard-premise'),
            embedded: true,
            onApply: null,
            initialTitle: _title,
            initialIdea: _idea,
            onDraft: _onDraft,
            socketFactory: AsrSocket.new,
            getIdToken: _idToken,
            getAppCheckToken: _appCheckToken,
            transcribe: (bytes) async {
              final slice = await repository.transcribeVoice(
                sessionId: _sessionId,
                seq: 0,
                audioBase64: base64Encode(bytes),
                format: 'wav',
                last: true,
              );
              return slice.text;
            },
            propose: (transcript) async {
              if (!await bloc.flushNode(story.rootNodeId!)) {
                throw const AppFailure(.failed);
              }
              final outline = await repository.proposeStoryOutline(
                storyId: story.storyId,
                transcript: transcript,
              );
              return (
                title: outline.title,
                synopsis: outline.synopsis,
                narratorLine: outline.narratorLine,
                options: [
                  for (final option in outline.options)
                    OutlineOption(
                      label: option.label,
                      icon: option.icon,
                      iconColor: option.iconColor,
                    ),
                ],
              );
            },
          ),
        ),
        if (widget.continueAction != null) ...[
          const SizedBox(height: 16),
          widget.continueAction!,
        ],
      ],
    );
  }
}
