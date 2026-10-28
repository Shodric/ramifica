import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Publish readiness bar: the story-level missing list plus the publish
/// CTA.
///
/// [problems] mirrors `validateStory` (via `CreateState.publishProblems`):
/// one message per unmet condition, empty when the story can publish. The
/// button stays disabled until [problems] is empty; even then [onPublish]
/// only reports readiness — the real publish call lands in #51, so this
/// bar never touches the network.
class PublishBar extends StatelessWidget {
  const PublishBar({super.key, required this.problems, this.onPublish});

  final List<String> problems;

  /// Readiness report hook (the view shows a confirmation note). Null
  /// keeps the CTA disabled.
  final VoidCallback? onPublish;

  @override
  Widget build(BuildContext context) {
    final ready = problems.isEmpty;
    return Column(
      key: const ValueKey('publish-bar'),
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        Text(
          ready
              ? 'Ready to publish.'
              : '${problems.length} item${problems.length == 1 ? '' : 's'} left to publish.',
          key: const ValueKey('publish-status'),
          style: RamificaText.label,
        ),
        if (!ready) ...[
          const SizedBox(height: 4),
          for (final problem in problems)
            Padding(
              padding: const .symmetric(vertical: 2),
              child: Text(problem, style: RamificaText.meta),
            ),
        ],
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('publish-button'),
          onPressed: ready && onPublish != null ? onPublish : null,
          child: Text(ready ? 'Publish' : 'Publish (${problems.length} left)'),
        ),
      ],
    );
  }
}
