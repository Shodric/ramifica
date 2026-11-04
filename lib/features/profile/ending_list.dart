import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/ending_badge.dart';

import 'package:ramifica/data/models/unlocked_ending.dart';

export 'package:ramifica/data/models/unlocked_ending.dart' show UnlockedEnding;

/// Unlocked endings as rows: scene title plus [EndingBadge]. Tapping a row
/// reports its story id through [onOpen]; the owner navigates. Pure: data
/// in via params, actions out via callback. No bloc, no router, no
/// repository. Empty shows text only, no CTA.
class EndingList extends StatelessWidget {
  const EndingList({super.key, required this.endings, required this.onOpen});

  final List<UnlockedEnding> endings;

  /// Called with the tapped ending's [UnlockedEnding.storyId].
  final void Function(String storyId) onOpen;

  @override
  Widget build(BuildContext context) {
    if (endings.isEmpty) {
      return const EmptyState(message: 'No endings unlocked yet.');
    }
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: .stretch,
      children: [
        for (var i = 0; i < endings.length; i++) ...[
          _Row(ending: endings[i], onOpen: () => onOpen(endings[i].storyId)),
          if (i != endings.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.ending, required this.onOpen});

  final UnlockedEnding ending;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Ending ${ending.name}',
      button: true,
      child: GestureDetector(
        onTap: onOpen,
        behavior: .opaque,
        child: Container(
          padding: const .all(12),
          decoration: BoxDecoration(
            color: RamificaColors.containerLow,
            borderRadius: .circular(16),
            border: .all(color: RamificaColors.glassBorder),
          ),
          child: Row(
            children: [
              if (ending.badgeUrl != null) ...[
                ClipRRect(
                  borderRadius: .circular(8),
                  child: Image.network(
                    ending.badgeUrl!,
                    key: const ValueKey('ending-thumbnail'),
                    width: 40,
                    height: 40,
                    fit: .cover,
                    errorBuilder: (context, error, stack) => const SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(Icons.emoji_events_outlined, size: 24),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  ending.name,
                  style: RamificaText.label,
                  maxLines: 2,
                  overflow: .ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              EndingBadge(type: ending.type),
            ],
          ),
        ),
      ),
    );
  }
}
