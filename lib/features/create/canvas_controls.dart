import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Floating recenter action pinned over the canvas top-right: taps always
/// return to the story root, never to a corner.
class CanvasRecenterButton extends StatelessWidget {
  const CanvasRecenterButton({super.key, required this.onRecenter});

  final VoidCallback onRecenter;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: RamificaColors.inputFill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: RamificaColors.outlineVariant),
      ),
      child: IconButton(
        key: const ValueKey('ribbon-recenter'),
        tooltip: 'Recenter on root',
        onPressed: onRecenter,
        icon: const Icon(Icons.filter_center_focus, size: 18),
      ),
    );
  }
}

/// Floating zoom cluster pinned over the canvas bottom-right: zoom out,
/// the current zoom (tapping resets to 100%), and zoom in. Null callbacks
/// disable their segment: zoom-in at 100%, zoom-out at the 25% floor.
class CanvasZoomControls extends StatelessWidget {
  const CanvasZoomControls({
    super.key,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onZoomReset,
  });

  final double zoom;

  /// Null disables the segment: zoom-in at 100%, zoom-out at the 25% floor.
  /// The middle segment always resets to 100%.
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;
  final VoidCallback onZoomReset;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_ZoomAction>(
      key: const ValueKey('ribbon-zoom'),
      showSelectedIcon: false,
      emptySelectionAllowed: true,
      selected: const {},
      style: SegmentedButton.styleFrom(
        backgroundColor: RamificaColors.inputFill,
        foregroundColor: RamificaColors.textPrimary,
        disabledForegroundColor: RamificaColors.textSecondary.withValues(
          alpha: 0.5,
        ),
        side: const BorderSide(color: RamificaColors.outlineVariant),
        shape: const RoundedRectangleBorder(
          borderRadius: .all(Radius.circular(999)),
        ),
        textStyle: const TextStyle(
          fontFamily: RamificaText.sans,
          fontWeight: .w600,
          fontSize: 12,
          height: 16 / 12,
          letterSpacing: 0.24,
        ),
        padding: const .symmetric(horizontal: 12),
        visualDensity: .compact,
        tapTargetSize: .shrinkWrap,
      ),
      onSelectionChanged: (selection) {
        switch (selection.single) {
          case _ZoomAction.out:
            onZoomOut?.call();
          case _ZoomAction.reset:
            onZoomReset();
          case _ZoomAction.zoomIn:
            onZoomIn?.call();
        }
      },
      segments: [
        ButtonSegment(
          value: _ZoomAction.out,
          icon: const Icon(Icons.remove, size: 18),
          tooltip: 'Zoom out',
          enabled: onZoomOut != null,
        ),
        ButtonSegment(
          value: _ZoomAction.reset,
          label: SizedBox(
            width: 48,
            child: Text('${(zoom * 100).round()}%', textAlign: .center),
          ),
          tooltip: 'Reset zoom to 100%',
        ),
        ButtonSegment(
          value: _ZoomAction.zoomIn,
          icon: const Icon(Icons.add, size: 18),
          tooltip: 'Zoom in',
          enabled: onZoomIn != null,
        ),
      ],
    );
  }
}

/// Zoom cluster segments: out, reset-to-100%, in. The button never holds
/// a selection — every tap is a momentary action.
enum _ZoomAction { out, reset, zoomIn }
