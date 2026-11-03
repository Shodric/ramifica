import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// Grows a circle from the zone until it covers the screen, in 1.5 seconds.
///
/// The fill is the held hotspot's color at half opacity, drawn behind the
/// hotspot itself with no ring. The color is remembered when the hold is
/// active, so releasing keeps the growing color while the circle shrinks
/// back instead of flashing to the fallback. Covering the screen calls
/// [onCompleted], which is the only signal that starts the next video.
/// Closing after cover runs a ring exit instead of shrinking: a hole opens
/// at the center and grows outward until the fill is gone.
class HoldPortal extends StatefulWidget {
  const HoldPortal({
    super.key,
    required this.open,
    required this.serial,
    required this.center,
    required this.startRadius,
    required this.fillColor,
    required this.onCompleted,
  });

  final bool open;
  final int serial;
  final Offset? center;
  final double startRadius;

  /// The held hotspot's resolved icon color. Shown at half opacity: at
  /// full cover the previous video shows through faintly while the
  /// commit runs.
  final Color fillColor;
  final VoidCallback onCompleted;

  @override
  State<HoldPortal> createState() => _HoldPortalState();
}

class _HoldPortalState extends State<HoldPortal> with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _growth;
  late final AnimationController _exit;
  late final Animation<double> _exitGrowth;
  Offset? _center;
  var _startRadius = 0.0;
  late Color _fillColor;
  var _reported = false;
  var _exiting = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
      reverseDuration: const Duration(milliseconds: 250),
    );
    _growth = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _controller.addListener(_onTick);
    _exit = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _exitGrowth = CurvedAnimation(parent: _exit, curve: Curves.easeInOut);
    _exit.addStatusListener(_onExitStatus);
    _fillColor = widget.fillColor.withValues(alpha: 0.5);
    _remember();
    if (widget.open && _center != null) _grow();
  }

  @override
  void didUpdateWidget(HoldPortal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _remember();
    final restarted = widget.open && widget.serial != oldWidget.serial;
    if (restarted || (widget.open && !oldWidget.open)) {
      _grow();
    } else if (!widget.open && oldWidget.open) {
      if (_reported && _controller.value == 1) {
        _startExit();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _exit.dispose();
    super.dispose();
  }

  void _remember() {
    final center = widget.center;
    if (center == null) return;
    _center = center;
    _startRadius = widget.startRadius;
    // Only while a hold is tracked: on release the view clears the held
    // choice (fading the zones back), but the shrinking circle keeps the
    // color it grew with.
    _fillColor = widget.fillColor.withValues(alpha: 0.5);
  }

  void _grow() {
    // A new hold mid-exit cancels the exit and grows from zero again.
    _exiting = false;
    _exit.stop();
    _exit.reset();
    _reported = false;
    _controller.forward(from: 0);
  }

  void _startExit() {
    _exiting = true;
    _controller.stop();
    _exit.forward(from: 0);
  }

  void _onExitStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!mounted) return;
    setState(() {
      _exiting = false;
      _reported = false;
    });
    _controller.reset();
  }

  void _onTick() {
    if (!widget.open || _reported || _controller.status == .reverse) return;
    if (_controller.value < 1) return;
    _reported = true;
    widget.onCompleted();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([_controller, _exit]),
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final center = _center;
              final size = constraints.biggest;
              if (center == null || size.isEmpty) {
                return const SizedBox.expand();
              }
              final cover = _cover(size, center);
              final full = math.max(_startRadius, cover);
              if (_exiting) {
                final hole = lerpDouble(0, full, _exitGrowth.value)!;
                return SizedBox.expand(
                  child: ClipPath(
                    clipper: _RingClipper(center, full, hole),
                    child: ColoredBox(
                      key: const ValueKey('hold-ring'),
                      color: _fillColor,
                    ),
                  ),
                );
              }
              final idle = !widget.open && _controller.value == 0;
              if (idle) {
                return const SizedBox.expand();
              }
              final radius = lerpDouble(_startRadius, full, _growth.value)!;
              return SizedBox.expand(
                child: ClipPath(
                  clipper: _PortalClipper(center, radius),
                  child: ColoredBox(
                    key: const ValueKey('hold-fill'),
                    color: _fillColor,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

double _cover(Size size, Offset center) {
  final corners = <Offset>[
    Offset.zero,
    Offset(size.width, 0),
    Offset(0, size.height),
    Offset(size.width, size.height),
  ];
  var farthest = 0.0;
  for (final corner in corners) {
    final distance = (corner - center).distance;
    if (distance > farthest) farthest = distance;
  }
  // A couple of pixels past the farthest corner: float rounding must
  // never leave a sliver of the old video visible at full cover.
  return farthest + 2;
}

class _PortalClipper extends CustomClipper<Path> {
  const _PortalClipper(this.center, this.radius);

  final Offset center;
  final double radius;

  @override
  Path getClip(Size size) {
    return Path()..addOval(Rect.fromCircle(center: center, radius: radius));
  }

  @override
  bool shouldReclip(_PortalClipper oldClipper) {
    return oldClipper.center != center || oldClipper.radius != radius;
  }
}

class _RingClipper extends CustomClipper<Path> {
  const _RingClipper(this.center, this.outerRadius, this.innerRadius);

  final Offset center;
  final double outerRadius;
  final double innerRadius;

  @override
  Path getClip(Size size) {
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCircle(center: center, radius: outerRadius))
      ..addOval(Rect.fromCircle(center: center, radius: innerRadius));
  }

  @override
  bool shouldReclip(_RingClipper oldClipper) {
    return oldClipper.center != center ||
        oldClipper.outerRadius != outerRadius ||
        oldClipper.innerRadius != innerRadius;
  }
}
