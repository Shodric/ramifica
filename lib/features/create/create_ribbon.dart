import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Stitch-style canvas ribbon: status pill + story title with the Simulate
/// and Publish actions on row one; tree-mode toggle and zoom cluster on row
/// two. The Publish CTA disables while the draft has missing items.
/// All copy is final EN — no hold, timing, or tap-to-choose affordances.
class CreateRibbon extends StatelessWidget {
  const CreateRibbon({
    super.key,
    required this.title,
    required this.rootMode,
    required this.onModeChanged,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onRecenter,
    required this.onSimulate,
    required this.onPublish,
    required this.canPublish,
    required this.onClose,
  });

  final String title;
  final bool rootMode;
  final ValueChanged<bool> onModeChanged;
  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onRecenter;
  final VoidCallback onSimulate;
  final VoidCallback? onPublish;

  /// Publish CTA enabled exactly when the draft has no missing items and
  /// no job is running.
  final bool canPublish;

  /// Leaves the fullscreen canvas back to Explore.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              key: const ValueKey('ribbon-close'),
              tooltip: 'Back to Create',
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title.isEmpty ? 'Create' : title,
                maxLines: 1,
                overflow: .ellipsis,
                style: RamificaText.headlineSM.copyWith(fontSize: 18),
              ),
            ),
            IconButton(
              onPressed: onSimulate,
              icon: const Icon(Icons.remove_red_eye_rounded),
            ),
            const SizedBox(width: 8),
            _PublishButton(onPressed: canPublish ? onPublish : null),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              decoration: BoxDecoration(
                color: RamificaColors.inputFill,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: RamificaColors.outlineVariant),
              ),
              child: Row(
                mainAxisSize: .min,
                children: [
                  _ModeTab(
                    label: 'Full Tree',
                    selected: !rootMode,
                    onTap: () => onModeChanged(false),
                  ),
                  _ModeTab(
                    label: 'Root Mode',
                    selected: rootMode,
                    onTap: () => onModeChanged(true),
                  ),
                ],
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Zoom out',
              onPressed: onZoomOut,
              icon: const Icon(Icons.remove, size: 18),
            ),
            SizedBox(
              width: 52,
              child: Text(
                '${(zoom * 100).round()}%',
                textAlign: .center,
                style: RamificaText.labelSM,
              ),
            ),
            IconButton(
              tooltip: 'Zoom in',
              onPressed: onZoomIn,
              icon: const Icon(Icons.add, size: 18),
            ),
            IconButton(
              key: const ValueKey('ribbon-recenter'),
              tooltip: 'Recenter on root',
              onPressed: onRecenter,
              icon: const Icon(Icons.filter_center_focus, size: 18),
            ),
          ],
        ),
      ],
    );
  }
}

class _ModeTab extends StatelessWidget {
  const _ModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? RamificaColors.hotspot.withValues(alpha: 0.25)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: RamificaText.labelSM.copyWith(
            color: selected
                ? RamificaColors.textPrimary
                : RamificaColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _PublishButton extends StatelessWidget {
  const _PublishButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: onPressed == null
            ? null
            : const LinearGradient(
                colors: [RamificaColors.nodeActive, RamificaColors.brandViolet],
              ),
      ),
      child: ElevatedButton(
        key: const ValueKey('ribbon-publish'),
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          disabledBackgroundColor: RamificaColors.inputFill,
        ),
        child: const Text('Publish'),
      ),
    );
  }
}
