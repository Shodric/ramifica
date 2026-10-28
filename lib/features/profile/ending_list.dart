import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/empty_state.dart';
import 'package:ramifica/core/widgets/ending_badge.dart';

/// One unlocked ending: which story it belongs to plus its display name
/// and type. Profile state carries no endings today (backend read lands in
/// a later slice), so the profile view takes these in as data until a
/// reachable source exists.
class UnlockedEnding {
  const UnlockedEnding({
    required this.storyId,
    required this.name,
    this.type,
  });

  /// The story whose graph opens on tap (`/graph/{storyId}`).
  final String storyId;

  final String name;

  /// `abierto`, `tragico`, or `secreto`; see [EndingBadge].
  final String? type;
}

/// Unlocked endings as rows: ending name plus [EndingBadge]. Tapping a row
/// reports its story id through [onOpen]; the owner navigates. Pure: data
/// in via params, actions out via callback. No bloc, no router, no
/// repository. Empty shows text only, no CTA.
class EndingList extends StatelessWidget {
  const EndingList({
    super.key,
    required this.endings,
    required this.onOpen,
  });

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
          _Row(
            ending: endings[i],
            onOpen: () => onOpen(endings[i].storyId),
          ),
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
        child: Row(
          children: [
            Expanded(
              child: Text(
                ending.name,
                style: RamificaText.label,
                maxLines: 1,
                overflow: .ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            EndingBadge(type: ending.type),
          ],
        ),
      ),
    );
  }
}
