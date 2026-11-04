import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Ending type pill. Feed card, map, and profile share it.
class EndingBadge extends StatelessWidget {
  const EndingBadge({super.key, required this.type});

  /// One of the nine ending types (`open`, `tragic`, `secret`,
  /// `heroic`, `mysterious`, `bittersweet`, `dark`, `epic`, `incomplete`).
  /// Legacy Spanish codes render their English label too.
  /// Unknown values render as-is.
  final String? type;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: RamificaColors.glass,
        borderRadius: .circular(999),
        border: .all(color: RamificaColors.glassBorder),
      ),
      child: Padding(
        padding: const .symmetric(horizontal: 10, vertical: 4),
        child: Text(
          '$_label final',
          style: RamificaText.meta.copyWith(color: _color),
        ),
      ),
    );
  }

  String get _label {
    return switch (type?.trim().toLowerCase()) {
      'abierto' || 'open' => 'Open',
      'tragico' || 'tragic' => 'Tragic',
      'secreto' || 'secret' => 'Secret',
      'heroico' || 'heroic' => 'Heroic',
      'misterioso' || 'mysterious' => 'Mysterious',
      'agridulce' || 'bittersweet' => 'Bittersweet',
      'oscuro' || 'dark' => 'Dark',
      'epico' || 'epic' => 'Epic',
      'incompleto' || 'incomplete' => 'Incomplete',
      null || '' => 'Ending',
      _ => type!,
    };
  }

  Color get _color {
    return switch (type?.trim().toLowerCase()) {
      'tragico' || 'tragic' => RamificaColors.error,
      'secreto' || 'secret' => RamificaColors.nodeActive,
      'heroico' || 'heroic' => RamificaColors.rewardGold,
      'misterioso' || 'mysterious' => RamificaColors.brandViolet,
      'agridulce' || 'bittersweet' => RamificaColors.danger,
      'oscuro' || 'dark' => RamificaColors.textPrimary,
      'incompleto' || 'incomplete' => RamificaColors.textSecondary,
      _ => RamificaColors.hotspot,
    };
  }
}
