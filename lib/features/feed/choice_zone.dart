import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';
import 'package:ramifica/core/widgets/glass_panel.dart';
import 'package:ramifica/features/feed/video_frame.dart';

/// Ring at `x`, `y`, `radius` (0 to 1 of the frame).
///
/// Positions go through [VideoFrame], because the 9:16 clip rarely fills the
/// screen exactly. A pointer down inside the circle reports its id and starts
/// the hold. The matching release is caught anywhere on screen (see the feed
/// view), so sliding off the ring still cancels. A short press does not choose.
class ChoiceZone extends StatelessWidget {
  const ChoiceZone({
    super.key,
    required this.choiceId,
    required this.label,
    required this.x,
    required this.y,
    required this.radius,
    required this.video,
    required this.enabled,
    required this.onHoldStart,
  });

  final String choiceId;
  final String label;
  final double x;
  final double y;
  final double radius;
  final VideoFrame video;

  /// False while a hold is already running. A new press does not steal it.
  final bool enabled;

  /// Called with the pointer id. The matching release ends the hold.
  final ValueChanged<int> onHoldStart;

  @override
  Widget build(BuildContext context) {
    final center = video.point(x, y);
    final ring = video.radius(radius);
    final diameter = ring * 2;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            left: center.dx - ring,
            top: center.dy - ring,
            width: diameter,
            height: diameter,
            child: _ZoneRing(
              key: ValueKey('ring-$choiceId'),
              enabled: enabled,
              onHoldStart: onHoldStart,
            ),
          ),
          Positioned(
            left: center.dx,
            top: center.dy + ring + 8,
            child: FractionalTranslation(
              translation: const Offset(-0.5, 0),
              child: IgnorePointer(
                child: GlassPanel(
                  padding: const .symmetric(horizontal: 10, vertical: 4),
                  borderRadius: const .all(.circular(999)),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: RamificaText.label,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reports the first pointer down inside the circle.
///
/// Releases are caught by the feed view, not here, so this stays stateless:
/// while a hold runs `enabled` is false, and the bloc ignores a second
/// `HoldStarted` anyway.
class _ZoneRing extends StatelessWidget {
  const _ZoneRing({
    super.key,
    required this.enabled,
    required this.onHoldStart,
  });

  final bool enabled;
  final ValueChanged<int> onHoldStart;

  void _down(BuildContext context, PointerDownEvent event) {
    if (!enabled) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(event.position);
    final radius = box.size.shortestSide / 2;
    final center = box.size.center(Offset.zero);
    if ((local - center).distance > radius) return;
    onHoldStart(event.pointer);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: .opaque,
      onPointerDown: (event) => _down(context, event),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: .circle,
          border: Border.all(color: RamificaColors.hotspot, width: 2),
        ),
        child: SizedBox.expand(),
      ),
    );
  }
}
