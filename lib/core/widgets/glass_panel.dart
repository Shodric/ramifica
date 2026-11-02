import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

/// The Stitch glass surface. One [BackdropFilter] path shared by every
/// variant: frosted panels and pucks blur, opaque cards stay static.
///
/// Overdraw: [GlassPanel.card] sits on the opaque
/// [RamificaColors.containerBase] ramp, so it skips the blur entirely. Live
/// blur is reserved for focal surfaces floating over content ([GlassPanel]
/// and [GlassPanel.puck]).
class GlassPanel extends StatelessWidget {
  final Widget child;

  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;

  final Color _fill;
  final Color _border;
  final double _sigma;

  const GlassPanel({
    Key? key,
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(16)),
  }) : this._surface(
         key: key,
         child: child,
         padding: padding,
         borderRadius: borderRadius,
         fill: RamificaColors.glass,
         border: RamificaColors.glassBorder,
         sigma: 16,
       );

  /// 24 px Stitch card on the opaque container ramp. Static: no blur cost.
  const GlassPanel.card({
    Key? key,
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
    BorderRadius borderRadius = RamificaLayout.cardBorderRadius,
  }) : this._surface(
         key: key,
         child: child,
         padding: padding,
         borderRadius: borderRadius,
         fill: RamificaColors.containerBase,
         border: RamificaColors.outlineVariant,
         sigma: 0,
       );

  /// 48 px puck for controls floating over content. Focal: live blur.
  const GlassPanel.puck({
    Key? key,
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(
      RamificaLayout.compactGutter,
    ),
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(48)),
  }) : this._surface(
         key: key,
         child: child,
         padding: padding,
         borderRadius: borderRadius,
         fill: RamificaColors.glass,
         border: RamificaColors.glassBorder,
         sigma: 16,
       );
  const GlassPanel._surface({
    super.key,
    required this.child,
    required this.padding,
    required this.borderRadius,
    required Color fill,
    required Color border,
    required double sigma,
  }) : _fill = fill,
       _border = border,
       _sigma = sigma;

  @override
  Widget build(BuildContext context) {
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: _fill,
        borderRadius: borderRadius,
        border: Border.all(color: _border),
      ),
      child: Padding(padding: padding, child: child),
    );
    if (_sigma <= 0) return surface;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma),
        child: surface,
      ),
    );
  }
}
