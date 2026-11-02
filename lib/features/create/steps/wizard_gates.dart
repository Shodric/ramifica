import 'package:ramifica/data/models/draft_node.dart';

/// Wizard step predicates: the single definition of "complete", used by the
/// step footer (Continue) and the stepper chips. Steps after Idea:
/// Script, Scenes, Voice, Clip, Options. Idea is a root-only chip.
/// Options sits last so zones land on the finished clip's last frame.
const wizardStepTitles = <String>[
  'Script',
  'Scenes',
  'Voice',
  'Clip',
  'Options',
];

const wizardStepCount = 5;

/// The first missing piece of [step] for [node], in UI-facing words, or
/// null when the step is complete.
///
/// * Script needs a title plus the narrator line; generated media is
///   accepted as-is (regen replaces it).
/// * Scenes needs the root S ready. Any other node inherits S read-only
///   from its parent clip's last frame, so Scenes is vacuous for it;
///   the Clip gate enforces the parent clip instead.
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
      if (node.ttsText.trim().isEmpty) {
        return 'the narrator line';
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
