import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/ending_badge.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';

/// Card over the last frame of an ending. Name, badge, the reward code
/// (when the ending granted one). Actions live on the right rail.
class EndingCard extends StatelessWidget {
  const EndingCard({
    super.key,
    required this.name,
    required this.type,
    this.rewardCode,
    this.unlockedTitle,
    this.badgeUrl,
    // Kept optional so existing callers still compile; the card no longer
    // renders its own buttons because the right rail covers the actions.
    this.onSeeMap,
    this.onTryAnotherPath,
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

  final VoidCallback? onSeeMap;
  final VoidCallback? onTryAnotherPath;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      child: Row(
        spacing: 8,
        mainAxisSize: .min,
        crossAxisAlignment: .end,
        children: [
          if (badgeUrl?.isNotEmpty ?? false) ...[
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
          ],
          Expanded(
            child: Column(
              spacing: 8,
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                EndingBadge(type: type),
                Text(
                  name,
                  maxLines: 2,
                  overflow: .ellipsis,
                  style: RamificaText.screenTitle.copyWith(
                    fontSize: 22,
                    height: 28 / 22,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
