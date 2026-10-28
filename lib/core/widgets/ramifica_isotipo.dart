import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// The 3-stop Stitch brand ramp: hotspot through signal blue to brand violet.
///
/// Shared by [RamificaIsotipo] and the shell Create button so the two never
/// drift. Geometry (begin/end) stays with each use site.
const ramificaBrandRampColors = [
  RamificaColors.hotspot,
  Color(0xFF38B6FF),
  RamificaColors.brandViolet,
];

/// The Ramifica isotipo: a branching mark drawn as vector, no asset, no text.
///
/// A trunk rises and splits into two paths, one node per tip: the story
/// graph in miniature. The strokes carry the 3-stop brand ramp
/// ([ramificaBrandRampColors]) over a transparent ground with a cyan glow
/// wash behind. Static: no animations, no controllers.
///
/// Wiring points for later phases (both out of P1 scope):
/// - Explore header mark, in `lib/features/explore/explore_view.dart`
///   (no header mark widget exists there yet).
/// - Access logo, in `lib/features/access/access_view.dart`
///   (no logo widget exists there yet).
class RamificaIsotipo extends StatelessWidget {
  const RamificaIsotipo({super.key, this.size = 48});

  /// Square dimension in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Ramifica',
      child: SizedBox.square(
        dimension: size,
        child: const CustomPaint(painter: _IsotipoPainter()),
      ),
    );
  }
}

class _IsotipoPainter extends CustomPainter {
  const _IsotipoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    if (s <= 0) return;
    final o = Offset(
      (size.width - s) / 2,
      (size.height - s) / 2,
    );

    // Glow wash behind the mark.
    canvas.drawCircle(
      o + Offset(0.5 * s, 0.52 * s),
      0.42 * s,
      Paint()..color = RamificaColors.glowCyan,
    );

    // Trunk splitting into two branches, in unit coordinates.
    final path = Path()
      ..moveTo(0.44 * s, 0.82 * s)
      ..cubicTo(0.44 * s, 0.68 * s, 0.42 * s, 0.62 * s, 0.40 * s, 0.55 * s)
      ..cubicTo(0.37 * s, 0.44 * s, 0.33 * s, 0.36 * s, 0.28 * s, 0.28 * s)
      ..moveTo(0.40 * s, 0.55 * s)
      ..cubicTo(0.46 * s, 0.47 * s, 0.54 * s, 0.42 * s, 0.63 * s, 0.38 * s)
      ..cubicTo(0.68 * s, 0.36 * s, 0.71 * s, 0.34 * s, 0.74 * s, 0.31 * s);
    canvas.drawPath(
      path.shift(o),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.11 * s
        ..strokeCap = StrokeCap.round
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: ramificaBrandRampColors,
        ).createShader(Rect.fromLTWH(o.dx, o.dy, s, s)),
    );

    // One node per tip: root in hotspot, branches in violet.
    canvas.drawCircle(o + Offset(0.44 * s, 0.82 * s), 0.075 * s,
        Paint()..color = RamificaColors.hotspot);
    canvas.drawCircle(o + Offset(0.28 * s, 0.28 * s), 0.075 * s,
        Paint()..color = RamificaColors.brandViolet);
    canvas.drawCircle(o + Offset(0.74 * s, 0.31 * s), 0.075 * s,
        Paint()..color = RamificaColors.brandViolet);
  }

  @override
  bool shouldRepaint(_IsotipoPainter oldDelegate) => false;
}
