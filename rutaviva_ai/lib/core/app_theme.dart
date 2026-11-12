import 'package:flutter/material.dart';

/// Paleta AMOLED: negro puro (apaga los píxeles OLED) y acento menta suave
/// para no encandilar en un bus de noche.
class AppColors {
  AppColors._();

  static const Color black = Color(0xFF000000);
  static const Color surface = Color(0xFF0D0E11);
  static const Color surfaceHigh = Color(0xFF16181D);
  static const Color outline = Color(0xFF262A31);
  static const Color accent = Color(0xFF00E5A0);
  static const Color accentDeep = Color(0xFF0B3D2E);
  static const Color amber = Color(0xFFFFB020);
  static const Color danger = Color(0xFFFF5C6C);
  static const Color textPrimary = Color(0xFFEDEFF2);
  static const Color textMuted = Color(0xFF8B93A1);

  /// Equivale a `withOpacity` pero estable entre versiones de Flutter.
  static Color alpha(Color c, double opacity) =>
      c.withAlpha((opacity.clamp(0.0, 1.0) * 255).round());
}

class AppTheme {
  AppTheme._();

  static ThemeData get dark {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: AppColors.accent,
      onPrimary: AppColors.black,
      secondary: AppColors.amber,
      onSecondary: AppColors.black,
      error: AppColors.danger,
      onError: AppColors.black,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      onSurfaceVariant: AppColors.textMuted,
      surfaceContainerHighest: AppColors.surfaceHigh,
      outline: AppColors.outline,
    );
    final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.black,
      canvasColor: AppColors.surface,
      dividerColor: AppColors.outline,
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
    );
  }
}
