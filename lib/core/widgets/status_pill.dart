import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

class StatusPill extends StatelessWidget {
  final StatusPillState status;

  const StatusPill({super.key, required this.status});

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
          status.label,
          style: RamificaText.meta.copyWith(color: status.color),
        ),
      ),
    );
  }
}

enum StatusPillState {
  idle('Idle'),
  running('Running'),
  ready('Ready'),
  failed('Failed');

  final String label;

  const StatusPillState(this.label);

  Color get color {
    return switch (this) {
      .idle => RamificaColors.textSecondary,
      .running => RamificaColors.nodeActive,
      .ready => RamificaColors.hotspot,
      .failed => RamificaColors.error,
    };
  }
}
