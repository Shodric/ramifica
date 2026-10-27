import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Ending type pill. Feed card, map, and profile share it.
class EndingBadge extends StatelessWidget {
  const EndingBadge({super.key, required this.type});

  /// `abierto`, `tragico`, or `secreto`. Unknown values render as-is.
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
          _label,
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
      null || '' => 'Ending',
      _ => type!,
    };
  }

  Color get _color {
    return switch (type?.trim().toLowerCase()) {
      'tragico' || 'tragic' => RamificaColors.error,
      'secreto' || 'secret' => RamificaColors.nodeActive,
      _ => RamificaColors.hotspot,
    };
  }
}
