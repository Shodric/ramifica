import 'package:ramifica/data/models/draft_node.dart';

/// Wizard step predicates: the single definition of "complete", used by the
/// step footer (Continue) and the stepper chips. Steps after Idea:
/// Info, Scenes, Voice, Clip, Options. Idea is a root-only chip.
/// Options sits last so zones land on the finished clip's last frame.
///
/// Step ids are logical and stable: Scenes is always 1, even though
/// children skip it (see [wizardSteps]). Chips keep logical keys so
/// Voice is `wizard-step-2` on every node.
const wizardStepTitles = <String>['Info', 'Scenes', 'Voice', 'Clip', 'Options'];

const wizardStepCount = 5;

/// Logical steps visible in the wizard, in order. Children skip Scenes:
/// they inherit the start frame from the parent clip, so the step has
/// no action and never gates Continue.
List<int> wizardSteps({required bool isRoot}) =>
    isRoot ? const [0, 1, 2, 3, 4] : const [0, 2, 3, 4];

/// Position of logical [step] among the visible steps, for IndexedStack.
int wizardDisplayIndex({required int step, required bool isRoot}) =>
    wizardSteps(isRoot: isRoot).indexOf(step);

/// The first missing piece of [step] for [node], in UI-facing words, or
/// null when the step is complete.
///
/// * Info needs a title. The narrator line, prompts, and options are
///   optional on-demand fills (the AppBar spark); Voice still gates
///   the line where it is edited.
/// * Scenes needs the root S ready. Children skip the step entirely
///   and inherit S from the parent clip's last frame; the Clip gate
///   enforces the parent clip instead.
/// * Voice needs a non-blank narrator line plus a generated voice
///   (`ttsStatus` ready).
/// * Options is vacuous on endings (no choices by design).
String? firstMissingForStep({
  required int step,
  required DraftNode node,
  required bool isRoot,
}) {
  switch (step) {
    case 0:
      final title = node.title.trim();
      if (title.isEmpty || title.length > 40) {
        return 'a scene title (1-40 characters)';
      }
      return null;
    case 1:
      if (isRoot && node.startImageStatus != 'ready') {
        return 'a generated start frame';
      }
      return null;
    case 2:
      if (node.ttsText.trim().isEmpty) {
        return 'the narrator line';
      }
      if (node.ttsStatus != 'ready') {
        return 'a generated voice';
      }
      return null;
    case 3:
      if (node.videoStatus != 'ready') {
        return 'a generated clip';
      }
      return null;
    case 4:
      if (node.isEnding) return null;
      if (node.choices.isEmpty) {
        return 'at least one Option';
      }
      for (final choice in node.choices) {
        final label = choice.label.trim();
        if (label.isEmpty || label.length > 24) {
          return 'each Option label (1-24 characters)';
        }
      }
      return null;
    default:
      return null;
  }
}

/// True when [step] has nothing missing.
bool isStepComplete({
  required int step,
  required DraftNode node,
  required bool isRoot,
}) => firstMissingForStep(step: step, node: node, isRoot: isRoot) == null;

/// Index of the first incomplete step, or [wizardStepCount] when all pass.
int firstIncompleteStep({required DraftNode node, required bool isRoot}) {
  for (var step = 0; step < wizardStepCount; step++) {
    if (!isStepComplete(step: step, node: node, isRoot: isRoot)) return step;
  }
  return wizardStepCount;
}
