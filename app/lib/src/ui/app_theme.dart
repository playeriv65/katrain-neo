// The app's look: Material 3, dark, seeded from a blue-grey. The board's own colours stay where they carry meaning
// (score, win rate and point loss, evaluation classes, the board).

import 'package:flutter/material.dart';

import '../theme.dart';

ThemeData appTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: KTheme.boxBackgroundColor,
    brightness: Brightness.dark,
    surface: KTheme.backgroundColor,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: KTheme.backgroundColor,
    cardTheme: CardThemeData(
      color: KTheme.boxBackgroundColor,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    chipTheme: ChipThemeData(
      selectedColor: scheme.primaryContainer,
      checkmarkColor: scheme.onPrimaryContainer,
      side: BorderSide(color: scheme.outlineVariant),
    ),
    visualDensity: VisualDensity.compact,
  );
}

/// The colours of the three kinds of evaluation (score, win rate, point loss), the same everywhere.
abstract final class StatColors {
  static Color get score => KTheme.scoreColor;
  static Color get winrate => KTheme.winrateColor;
  static Color get pointloss => KTheme.pointlossColor;
}
