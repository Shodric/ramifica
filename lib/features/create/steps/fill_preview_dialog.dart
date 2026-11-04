import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/features/create/create_event.dart';
import 'package:ramifica/features/create/premise_sheet.dart';

/// Dialog title for a per-section fill proposal.
String fillPreviewTitle(int step) {
  switch (step) {
    case 0:
      return 'Proposed Info';
    case 1:
      return 'Proposed start frame';
    case 2:
      return 'Proposed voice line';
    case 3:
      return 'Proposed clip';
    case 4:
      return 'Proposed options';
    default:
      return 'Proposed values';
  }
}

/// Narrows a full scene [proposal] to the fields of [step], or null when
/// the section carries nothing usable. Endings never take options.
SceneProposal? sliceProposalForStep(
  SceneProposal proposal, {
  required int step,
  required bool isEnding,
}) {
  late final SceneProposal sliced;
  switch (step) {
    case 0:
      sliced = SceneProposal(title: proposal.title, ttsText: proposal.ttsText);
    case 1:
      sliced = SceneProposal(startImagePrompt: proposal.startImagePrompt);
    case 2:
      sliced = SceneProposal(ttsText: proposal.ttsText);
    case 3:
      sliced = SceneProposal(videoPrompt: proposal.videoPrompt);
    case 4:
      if (isEnding) return null;
      sliced = SceneProposal(choices: proposal.choices);
    default:
      return null;
  }
  final empty =
      (sliced.title == null || sliced.title!.isEmpty) &&
      (sliced.ttsText == null || sliced.ttsText!.isEmpty) &&
      (sliced.startImagePrompt == null || sliced.startImagePrompt!.isEmpty) &&
      (sliced.videoPrompt == null || sliced.videoPrompt!.isEmpty) &&
      sliced.choices.isEmpty;
  return empty ? null : sliced;
}

/// Previews the values a fill would assign. True applies them, false or
/// null (dismiss) discards them.
Future<bool?> showFillPreview({
  required BuildContext context,
  required int step,
  required SceneProposal proposal,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('fill-preview-dialog'),
      title: Text(fillPreviewTitle(step)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          children: [
            for (final row in _rows(step, proposal)) ...[
              Text(row.label, style: RamificaText.meta),
              const SizedBox(height: 2),
              Text(row.value, style: RamificaText.body),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('fill-discard'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Discard'),
        ),
        FilledButton(
          key: const ValueKey('fill-accept'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Accept'),
        ),
      ],
    ),
  );
}

/// Previews the values an Idea fill would assign. True applies them,
/// false or null (dismiss) discards them.
Future<bool?> showPremisePreview({
  required BuildContext context,
  required PremiseProposal proposal,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('fill-preview-dialog'),
      title: const Text('Proposed idea'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          children: [
            for (final row in _premiseRows(proposal)) ...[
              Text(row.label, style: RamificaText.meta),
              const SizedBox(height: 2),
              Text(row.value, style: RamificaText.body),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('fill-discard'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Discard'),
        ),
        FilledButton(
          key: const ValueKey('fill-accept'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Accept'),
        ),
      ],
    ),
  );
}

({String label, String value}) _row(String label, String value) =>
    (label: label, value: value);

List<({String label, String value})> _premiseRows(PremiseProposal proposal) {
  final rows = <({String label, String value})>[];
  if (proposal.title != null && proposal.title!.isNotEmpty) {
    rows.add(_row('Title', proposal.title!));
  }
  if (proposal.idea != null && proposal.idea!.isNotEmpty) {
    rows.add(_row('Idea', proposal.idea!));
  }
  for (var i = 0; i < proposal.options.length && i < 2; i++) {
    final option = proposal.options[i];
    final icon = option.icon?.trim() ?? '';
    rows.add(
      _row(
        'Option ${i == 0 ? 'A' : 'B'}',
        icon.isEmpty ? option.label : '${option.label} · $icon',
      ),
    );
  }
  return rows;
}

List<({String label, String value})> _rows(int step, SceneProposal proposal) {
  final rows = <({String label, String value})>[];
  if (proposal.title != null && proposal.title!.isNotEmpty) {
    rows.add(_row('Title', proposal.title!));
  }
  if (proposal.ttsText != null && proposal.ttsText!.isNotEmpty) {
    rows.add(
      _row(step == 2 ? 'Voice line' : 'Narrator line', proposal.ttsText!),
    );
  }
  if (proposal.startImagePrompt != null &&
      proposal.startImagePrompt!.isNotEmpty) {
    rows.add(_row('Start frame prompt', proposal.startImagePrompt!));
  }
  if (proposal.videoPrompt != null && proposal.videoPrompt!.isNotEmpty) {
    rows.add(_row('Clip prompt', proposal.videoPrompt!));
  }
  for (var i = 0; i < proposal.choices.length && i < 2; i++) {
    final choice = proposal.choices[i];
    final icon = choice.icon?.trim() ?? '';
    rows.add(
      _row(
        'Option ${i == 0 ? 'A' : 'B'}',
        icon.isEmpty ? choice.label : '${choice.label} · $icon',
      ),
    );
  }
  return rows;
}
