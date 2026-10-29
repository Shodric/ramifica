import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Fixed mini geometry, centered on its canvas position.
const createMiniWidth = 120.0;
const createMiniHeight = 84.0;

/// Stitch-style `+` mini-node: one per missing choice slot on a parent.
/// Tapping creates the child through `NodeAdded(parentNodeId:)`.
class CreatePlusNode extends StatelessWidget {
  const CreatePlusNode({
    super.key,
    required this.parentId,
    required this.slot,
    required this.onAdd,
  });

  /// Id of the node that will parent the new child.
  final String parentId;

  /// Choice slot label: `A` or `B`.
  final String slot;

  final ValueChanged<String> onAdd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onAdd(parentId),
      child: Container(
        width: createMiniWidth,
        height: createMiniHeight,
        decoration: BoxDecoration(
          color: RamificaColors.containerBase,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: RamificaColors.textSecondary.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          mainAxisAlignment: .center,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: .circle,
                border: Border.all(color: RamificaColors.hotspot, width: 1.5),
              ),
              child: const Icon(
                Icons.add,
                size: 16,
                color: RamificaColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Option $slot',
              style: RamificaText.body.copyWith(
                color: RamificaColors.textPrimary,
                fontSize: 12,
              ),
            ),
            Text(
              'New branch',
              style: RamificaText.caption.copyWith(
                color: RamificaColors.textSecondary,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
