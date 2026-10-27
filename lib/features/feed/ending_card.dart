import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/ending_badge.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';

/// Card over the last frame of an ending. Name, badge, see map,
/// try another path. Reward and saga unlock arrive in a later slice.
class EndingCard extends StatelessWidget {
  const EndingCard({
    super.key,
    required this.name,
    required this.type,
    required this.onSeeMap,
    required this.onTryAnotherPath,
  });

  final String name;
  final String? type;
  final VoidCallback onSeeMap;
  final VoidCallback onTryAnotherPath;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      child: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .start,
        children: [
          Text(
            name,
            maxLines: 2,
            overflow: .ellipsis,
            style: RamificaText.screenTitle.copyWith(fontSize: 22, height: 28 / 22),
          ),
          const SizedBox(height: 8),
          EndingBadge(type: type),
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
