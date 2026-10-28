import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Determinate, static progress bar. No animation controllers: the fill is a
/// plain [FractionallySizedBox], so it never schedules frames on its own.
///
/// Wiring point for a later phase: `lib/features/graph/node_sheet.dart`
/// renders its own [LinearProgressIndicator] for path shares today; re-point
/// it at [ConsensusBar] when that feature adapts.
class RamificaProgressBar extends StatelessWidget {
  const RamificaProgressBar({
    super.key,
    required this.value,
    this.color = RamificaColors.nodeActive,
    this.trackColor = RamificaColors.secondaryContainer,
    this.minHeight = 6,
  });

  /// 0..1 fill. Clamped.
  final double value;
  final Color color;
  final Color trackColor;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final fill = value.clamp(0.0, 1.0);
    return Semantics(
      value: '${(fill * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: minHeight,
          color: trackColor,
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: fill,
            child: Container(height: minHeight, color: color),
          ),
        ),
      ),
    );
  }
}

/// Consensus row: `$count/$sum ($percent%)` over a [RamificaProgressBar].
/// Same display contract as the graph path rows; pure and static.
class ConsensusBar extends StatelessWidget {
  const ConsensusBar({
    super.key,
    required this.share,
    required this.count,
    required this.sum,
    this.color = RamificaColors.nodeActive,
  });

  final double share;
  final int count;
  final int sum;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final clamped = share.clamp(0.0, 1.0);
    final percent = (clamped * 100).round();
    return Semantics(
      label: 'Consensus',
      value: '$count of $sum, $percent percent',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$count/$sum ($percent%)',
            style: RamificaText.caption.copyWith(
              color: RamificaColors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          RamificaProgressBar(value: clamped, color: color),
        ],
      ),
    );
  }
}
