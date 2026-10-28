import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Neutral meta badge: a count, duration, or tag that carries no state.
/// State-colored pills stay in [StatusPill]; ending types stay in
/// [EndingBadge]. Static translucency: no blur, no animation.
class MetaBadge extends StatelessWidget {
  const MetaBadge({super.key, required this.label, this.icon, this.color})
    : _fill = null,
      _border = null;

  /// Accent badge for the active selection: primary-container fill with
  /// on-primary-container ink.
  const MetaBadge.accent({super.key, required this.label, this.icon})
    : color = RamificaColors.onPrimaryContainer,
      _fill = RamificaColors.primaryContainer,
      _border = null;

  /// Reward badge: gold ink on a gold wash.
  const MetaBadge.reward({super.key, required this.label, this.icon})
    : color = RamificaColors.rewardGold,
      _fill = null,
      _border = RamificaColors.rewardGold;

  final String label;
  final IconData? icon;

  /// Ink. Defaults to [RamificaColors.textSecondary].
  final Color? color;

  final Color? _fill;
  final Color? _border;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? RamificaColors.textSecondary;
    return Semantics(
      label: label,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _fill ?? RamificaColors.glass,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _border ?? RamificaColors.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 12, color: ink),
                const SizedBox(width: 4),
              ],
              Text(label, style: RamificaText.caption.copyWith(color: ink)),
            ],
          ),
        ),
      ),
    );
  }
}
