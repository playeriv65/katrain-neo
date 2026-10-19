// The app's look: Material 3, dark, seeded from a blue-grey. The board's own colours stay where they carry meaning
// (score, win rate and point loss, evaluation classes, the board).

import 'package:flutter/material.dart';

import '../theme.dart';

/// Fonts for the characters of Chinese, Japanese and Korean, by language: each language's own glyph forms first, then
/// the others (Windows, macOS, Linux names).
const _cjkFonts = {
  'cn': ['Microsoft YaHei UI', 'Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC'],
  'tw': ['Microsoft JhengHei UI', 'Microsoft JhengHei', 'PingFang TC', 'Noto Sans CJK TC'],
  'jp': ['Yu Gothic UI', 'Yu Gothic', 'Hiragino Sans', 'Noto Sans CJK JP'],
  'ko': ['Malgun Gothic', 'Apple SD Gothic Neo', 'Noto Sans CJK KR'],
};

/// The fonts to fall back to in [lang]: the language's CJK fonts first, so Chinese is not drawn in Japanese forms.
List<String> fontFallback(String lang) => [
  ...?_cjkFonts[lang],
  for (final e in _cjkFonts.entries)
    if (e.key != lang) ...e.value,
];

ThemeData appTheme({String lang = 'en'}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: KTheme.boxBackgroundColor,
    brightness: Brightness.dark,
    surface: KTheme.backgroundColor,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamilyFallback: fontFallback(lang),
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
