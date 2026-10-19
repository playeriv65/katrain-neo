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

/// The app's languages as locales, for Flutter's own texts (Cancel, Close, tooltips, the text field menu) and for
/// choosing glyph forms.
const appLocales = {
  'en': Locale('en'),
  'cn': Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN'),
  'tw': Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW'),
  'jp': Locale('ja'),
  'ko': Locale('ko'),
  'de': Locale('de'),
  'es': Locale('es'),
  'fr': Locale('fr'),
  'ru': Locale('ru'),
  'tr': Locale('tr'),
  'ua': Locale('uk'),
};

/// The fonts to fall back to in [lang]: the language's CJK fonts first, so Chinese is not drawn in Japanese forms.
List<String> fontFallback(String lang) => [
  ...?_cjkFonts[lang],
  for (final e in _cjkFonts.entries)
    if (e.key != lang) ...e.value,
];

/// The colour the scheme is derived from: a slate blue.
const _seed = Color(0xFF2E4158);

ThemeData appTheme({String lang = 'en'}) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark);
  return ThemeData(
    useMaterial3: true,
    fontFamilyFallback: fontFallback(lang),
    colorScheme: scheme,
    cardTheme: CardThemeData(
      color: scheme.surfaceContainer,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    visualDensity: VisualDensity.compact,
  );
}

/// The colours of the three kinds of evaluation (score, win rate, point loss), the same everywhere.
abstract final class StatColors {
  static Color get score => KTheme.scoreColor;
  static Color get winrate => KTheme.winrateColor;
  static Color get pointloss => KTheme.pointlossColor;
}
