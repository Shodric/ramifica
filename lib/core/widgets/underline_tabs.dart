import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Stitch underline tabs: labels in a row, the selected one in hotspot with
/// a 2 px underline. Determinate and static: no controllers, no animation.
class UnderlineTabs extends StatelessWidget {
  const UnderlineTabs({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Tabs',
      explicitChildNodes: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  child: _Tab(
                    label: labels[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelected(i),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 1),
          Container(height: 1, color: RamificaColors.outline),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: RamificaText.labelSM.copyWith(
                  color: selected
                      ? RamificaColors.hotspot
                      : RamificaColors.textSecondary,
                ),
              ),
            ),
            Container(
              height: 2,
              color: selected
                  ? RamificaColors.hotspot
                  : const Color(0x00000000),
            ),
          ],
        ),
      ),
    );
  }
}
