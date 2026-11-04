import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/ending_badge.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';

/// Card over the last frame of an ending. Name, badge, the reward code
/// (when the ending granted one), see map, try another path.
class EndingCard extends StatelessWidget {
  const EndingCard({
    super.key,
    required this.name,
    required this.type,
    this.rewardCode,
    this.unlockedTitle,
    this.badgeUrl,
    required this.onSeeMap,
    required this.onTryAnotherPath,
  });

  final String name;
  final String? type;

  /// The displayable reward code for this ending. Null while the grant
  /// has no code (older grants); the block hides. Display only.
  final String? rewardCode;

  /// The ending name announced as `Unlocked {title}`. Null hides the line.
  final String? unlockedTitle;

  /// The unlocked prize image. Null hides the badge block. Display only.
  final String? badgeUrl;

  final VoidCallback onSeeMap;
  final VoidCallback onTryAnotherPath;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .start,
        children: [
          if (badgeUrl != null) ...[
            ClipRRect(
              borderRadius: .circular(16),
              child: Image.network(
                badgeUrl!,
                key: const ValueKey('ending-badge'),
                width: 120,
                height: 120,
                fit: .cover,
                errorBuilder: (context, error, stack) => const SizedBox(
                  width: 120,
                  height: 120,
                  child: Icon(Icons.emoji_events_outlined, size: 48),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Desbloqueaste $name',
              key: const ValueKey('desbloqueaste-title'),
              style: RamificaText.label,
            ),
            const SizedBox(height: 8),
          ],
          Text(
            name,
            maxLines: 2,
            overflow: .ellipsis,
            style: RamificaText.screenTitle.copyWith(
              fontSize: 22,
              height: 28 / 22,
            ),
          ),
          const SizedBox(height: 8),
          EndingBadge(type: type),
          if (rewardCode != null || unlockedTitle != null) ...[
            const SizedBox(height: 12),
            if (unlockedTitle != null)
              Text(
                'Unlocked ${unlockedTitle!}',
                key: const ValueKey('unlocked-title'),
                style: RamificaText.label,
              ),
            if (rewardCode != null)
              SelectableText(
                rewardCode!,
                key: const ValueKey('reward-code'),
                style: RamificaText.body,
              ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onSeeMap,
                  child: const Text('See map'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: onTryAnotherPath,
                  child: const Text('Try another path'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
