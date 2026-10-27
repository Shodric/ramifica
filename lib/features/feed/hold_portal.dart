import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// Grows a circle from the zone until it covers the screen, in one second.
///
/// The fill is the current node's inline blur, stretched and softened.
/// Releasing reverses the circle. Covering the screen calls [onCompleted].
class HoldPortal extends StatefulWidget {
  const HoldPortal({
    super.key,
    required this.open,
    required this.serial,
    required this.center,
    required this.startRadius,
    required this.blurData,
    required this.onCompleted,
  });

  final bool open;
  final int serial;
  final Offset? center;
  final double startRadius;
  final String? blurData;
  final VoidCallback onCompleted;

  @override
  State<HoldPortal> createState() => _HoldPortalState();
}

class _HoldPortalState extends State<HoldPortal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Offset? _center;
  var _startRadius = 0.0;
  Uint8List? _bytes;
  var _reported = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _controller.addListener(_onTick);
    _bytes = _decodeBlur(widget.blurData);
    _remember();
    if (widget.open && _center != null) _grow();
  }

  @override
  void didUpdateWidget(HoldPortal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.blurData != oldWidget.blurData) {
      _bytes = _decodeBlur(widget.blurData);
    }
    _remember();
    final restarted = widget.open && widget.serial != oldWidget.serial;
    if (restarted || (widget.open && !oldWidget.open)) {
      _grow();
    } else if (!widget.open && oldWidget.open) {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _remember() {
    final center = widget.center;
    if (center == null) return;
    _center = center;
    _startRadius = widget.startRadius;
  }

  void _grow() {
    _reported = false;
    _controller.forward(from: 0);
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
        animation: _controller,
        builder: (context, _) {
          return LayoutBuilder(
            builder: (context, constraints) {
              final center = _center;
              final size = constraints.biggest;
              final idle = !widget.open && _controller.value == 0;
              if (center == null || size.isEmpty || idle) {
                return const SizedBox.expand();
              }
              final cover = _cover(size, center);
              final radius = lerpDouble(
                _startRadius,
                math.max(_startRadius, cover),
                _controller.value,
              )!;
              return Stack(
                fit: .expand,
                children: [
                  ClipPath(
                    clipper: _PortalClipper(center, radius),
                    child: Stack(
                      fit: .expand,
                      children: [
                        if (_bytes != null)
                          Positioned.fill(
                            child: ImageFiltered(
                              imageFilter: ImageFilter.blur(
                                sigmaX: 8,
                                sigmaY: 8,
                              ),
                              child: Opacity(
                                opacity: 0.85,
                                child: Image.memory(
                                  _bytes!,
                                  fit: .cover,
                                  width: size.width,
                                  height: size.height,
                                  gaplessPlayback: true,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const SizedBox.expand(),
                                ),
                              ),
                            ),
                          ),
                        const Positioned.fill(
                          child: ColoredBox(color: Color(0x66131318)),
                        ),
                      ],
                    ),
                  ),
                  CustomPaint(
                    painter: _RingPainter(center, radius),
                    child: const SizedBox.expand(),
                  ),
                ],
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
  return farthest;
}

Uint8List? _decodeBlur(String? data) {
  if (data == null) return null;
  final comma = data.indexOf(',');
  if (comma < 0 || comma == data.length - 1) return null;
  try {
    return base64Decode(data.substring(comma + 1));
  } on FormatException {
    return null;
  }
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

class _RingPainter extends CustomPainter {
  const _RingPainter(this.center, this.radius);

  final Offset center;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = RamificaColors.hotspot;
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) {
    return oldDelegate.center != center || oldDelegate.radius != radius;
  }
}
