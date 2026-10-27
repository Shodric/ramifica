import 'package:flutter/material.dart';

abstract final class RamificaColors {
  static const hotspot = Color(0xFF00F2FE);
  static const nodeActive = Color(0xFF4FACFE);
  static const nodeLocked = Color(0xFF2A2A38);
  static const surface = Color(0xFF131318);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFA0A0B0);

  /// White at 12%. Bars and sheets.
  static const glass = Color(0x1FFFFFFF);

  static const error = Color(0xFFFFB4AB);
}

abstract final class RamificaTheme {
  static ThemeData get data {
    const scheme = ColorScheme.dark(
      primary: RamificaColors.hotspot,
      secondary: RamificaColors.nodeActive,
      surface: RamificaColors.surface,
      onSurface: RamificaColors.textPrimary,
      error: RamificaColors.error,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: RamificaColors.surface,
      colorScheme: scheme,
      textTheme: ThemeData(brightness: Brightness.dark).textTheme.apply(
        bodyColor: RamificaColors.textPrimary,
        displayColor: RamificaColors.textPrimary,
      ),
    );
  }
}
