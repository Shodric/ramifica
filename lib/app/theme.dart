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

  /// White at 18%. Glass border.
  static const glassBorder = Color(0x2EFFFFFF);

  static const error = Color(0xFFFFB4AB);

  /// Black at 75%, 8 px blur. Text that sits on video.
  static const videoShadow = Shadow(
    color: Color(0xBF000000),
    blurRadius: 8,
    offset: Offset(0, 2),
  );
}

abstract final class RamificaText {
  static const sans = 'Plus Jakarta Sans';
  static const display = 'Montserrat';

  static const screenTitle = TextStyle(
    fontFamily: display,
    fontWeight: .w700,
    fontSize: 28,
    height: 34 / 28,
    letterSpacing: -0.28,
    color: RamificaColors.textPrimary,
  );

  static const body = TextStyle(
    fontFamily: sans,
    fontWeight: .w400,
    fontSize: 16,
    height: 24 / 16,
    color: RamificaColors.textPrimary,
  );

  static const label = TextStyle(
    fontFamily: sans,
    fontWeight: .w600,
    fontSize: 14,
    height: 18 / 14,
    letterSpacing: 0.28,
    color: RamificaColors.textPrimary,
  );

  static const meta = TextStyle(
    fontFamily: sans,
    fontWeight: .w400,
    fontSize: 12,
    height: 16 / 12,
    color: RamificaColors.textSecondary,
  );

  static TextStyle overVideo(TextStyle style) {
    return style.copyWith(shadows: const [RamificaColors.videoShadow]);
  }
}

abstract final class RamificaTheme {
  static ThemeData get data {
    const scheme = ColorScheme.dark(
      primary: RamificaColors.hotspot,
      onPrimary: Color(0xFF00373A),
      secondary: RamificaColors.nodeActive,
      onSecondary: Color(0xFF003256),
      surface: RamificaColors.surface,
      onSurface: RamificaColors.textPrimary,
      error: RamificaColors.error,
      onError: Color(0xFF690005),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: .dark,
      fontFamily: RamificaText.sans,
      scaffoldBackgroundColor: RamificaColors.surface,
      colorScheme: scheme,
      textTheme: const TextTheme(
        headlineMedium: RamificaText.screenTitle,
        bodyLarge: RamificaText.body,
        labelLarge: RamificaText.label,
        bodySmall: RamificaText.meta,
      ),
    );
  }
}
