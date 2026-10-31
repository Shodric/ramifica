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

  /// Destructive action fill (delete). White text on top.
  static const danger = Color(0xFFD32F2F);

  /// Dark surface ramp. [containerLow] matches [surface];
  /// [containerHighest] matches [nodeLocked].
  static const containerLowest = Color(0xFF0B0B0F);
  static const containerLow = surface;
  static const containerBase = Color(0xFF1A1A22);
  static const containerHigh = Color(0xFF22222E);
  static const containerHighest = Color(0xFF2A2A38);
  static const containerBright = Color(0xFF34343F);

  static const onSurface = textPrimary;

  /// Subtle 1 px edge. Same ink as [glassBorder].
  static const outline = glassBorder;

  /// Faint fill edge. Same ink as [glass].
  static const outlineVariant = glass;

  /// Dark cyan container. Bright text on it is [onPrimaryContainer].
  static const primaryContainer = Color(0xFF004B50);
  static const onPrimaryContainer = hotspot;

  /// Dark text on [nodeActive].
  static const onSecondary = Color(0xFF003256);

  /// Dark blue container for tints behind [nodeActive].
  static const secondaryContainer = Color(0xFF0B2A3F);

  static const rewardGold = Color(0xFFFED83A);
  static const brandViolet = Color(0xFF7B2CBF);

  /// [hotspot] at 16%. Glow washes and rings.
  static const glowCyan = Color(0x2900F2FE);

  /// [brandViolet] at 16%. Glow washes and rings.
  static const glowViolet = Color(0x297B2CBF);

  /// Black at 75%, 8 px blur. Text that sits on video.
  static const videoShadow = Shadow(
    color: Color(0xBF000000),
    blurRadius: 8,
    offset: Offset(0, 2),
  );

  /// Black at 40%, 16 px blur, 8 px down. Lifted cards and sheets.
  static const cardShadow = Shadow(
    color: Color(0x66000000),
    blurRadius: 16,
    offset: Offset(0, 8),
  );

  /// [glowCyan] wash, 16 px blur. Active halos.
  static const glowCyanShadow = Shadow(color: glowCyan, blurRadius: 16);

  /// [glowViolet] wash, 16 px blur. Reward halos.
  static const glowVioletShadow = Shadow(color: glowViolet, blurRadius: 16);

  /// White at 6%. Creator input fill.
  static const inputFill = Color(0x0FFFFFFF);

  /// Resting input edge.
  static const inputBorder = BorderSide(color: glassBorder);

  /// Input edge on focus.
  static const inputFocusedBorder = BorderSide(color: hotspot, width: 2);

  /// Brand Rampcolors
  static const rampColors = [
    RamificaColors.hotspot,
    Color(0xFF38B6FF),
    RamificaColors.brandViolet,
  ];
}

abstract final class RamificaLayout {
  /// Card corner radius.
  static const double cardRadius = 24;

  static const cardBorderRadius = BorderRadius.all(Radius.circular(cardRadius));

  /// Tight grid gutter. Screens keep their 16 px margin.
  static const double compactGutter = 12;
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

  static const displayXL = TextStyle(
    fontFamily: display,
    fontWeight: .w700,
    fontSize: 40,
    height: 44 / 40,
    letterSpacing: -0.4,
    color: RamificaColors.textPrimary,
  );

  static const headlineMD = TextStyle(
    fontFamily: display,
    fontWeight: .w700,
    fontSize: 24,
    height: 30 / 24,
    letterSpacing: -0.24,
    color: RamificaColors.textPrimary,
  );

  static const headlineSM = TextStyle(
    fontFamily: display,
    fontWeight: .w700,
    fontSize: 20,
    height: 26 / 20,
    letterSpacing: -0.2,
    color: RamificaColors.textPrimary,
  );

  static const bodySM = TextStyle(
    fontFamily: sans,
    fontWeight: .w400,
    fontSize: 14,
    height: 20 / 14,
    color: RamificaColors.textPrimary,
  );

  static const labelSM = TextStyle(
    fontFamily: sans,
    fontWeight: .w600,
    fontSize: 12,
    height: 16 / 12,
    letterSpacing: 0.24,
    color: RamificaColors.textPrimary,
  );

  static const caption = TextStyle(
    fontFamily: sans,
    fontWeight: .w400,
    fontSize: 11,
    height: 14 / 11,
    letterSpacing: 0.22,
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
      onSecondary: RamificaColors.onSecondary,
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
