import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:ramifica/app/theme.dart';

class GlassPanel extends StatelessWidget {
  final Widget child;

  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const .all(16),
    this.borderRadius = const .all(.circular(16)),
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: RamificaColors.glass,
            borderRadius: borderRadius,
            border: .all(color: RamificaColors.glassBorder),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
