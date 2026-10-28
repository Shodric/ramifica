import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Decision-window stepper: 3 to 15 seconds, default 6.
///
/// STATIC: a slider plus step buttons, no animation loops. The value
/// commits through [onChanged] per step; the bloc clamps to 3..15 and the
/// window persists through `saveNode` with the inspector Save. Hidden on
/// endings (the checklist forbids `windowSeconds` there).
class WindowPicker extends StatelessWidget {
  const WindowPicker({
    super.key,
    required this.nodeId,
    required this.value,
    this.busy = false,
    this.onChanged,
  });

  /// Minimum, maximum, and default decision window in seconds.
  static const int minSeconds = 3;
  static const int maxSeconds = 15;
  static const int defaultSeconds = 6;

  final String nodeId;

  /// Current window in seconds. Values outside 3..15 display clamped.
  final int value;
  final bool busy;

  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final shown = value.clamp(minSeconds, maxSeconds).toInt();
    final enabled = !busy && onChanged != null;
    return Row(
      children: [
        IconButton(
          key: ValueKey('window-minus-$nodeId'),
          icon: const Icon(Icons.remove),
          onPressed: enabled && shown > minSeconds
              ? () => onChanged!(shown - 1)
              : null,
        ),
        Expanded(
          child: Slider(
            key: ValueKey('window-slider-$nodeId'),
            value: shown.toDouble(),
            min: minSeconds.toDouble(),
            max: maxSeconds.toDouble(),
            divisions: maxSeconds - minSeconds,
            label: '${shown}s',
            onChanged: enabled
                ? (picked) => onChanged!(picked.round().clamp(
                      minSeconds,
                      maxSeconds,
                    ))
                : null,
          ),
        ),
        IconButton(
          key: ValueKey('window-plus-$nodeId'),
          icon: const Icon(Icons.add),
          onPressed: enabled && shown < maxSeconds
              ? () => onChanged!(shown + 1)
              : null,
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${shown}s',
            key: ValueKey('window-value-$nodeId'),
            style: RamificaText.label,
            textAlign: .right,
          ),
        ),
      ],
    );
  }
}
