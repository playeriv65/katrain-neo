// The app's look: Material 3, light or dark as the system is, seeded from a slate blue. Colours that carry meaning
// stay: score, win rate and point loss (in a shade for each mode), evaluation classes, the board.

import 'package:flutter/material.dart';

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

/// The app's look in [brightness]; the app follows the system's light or dark mode.
ThemeData appTheme({String lang = 'en', Brightness brightness = Brightness.dark}) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    fontFamilyFallback: fontFallback(lang),
    colorScheme: scheme,
    extensions: [brightness == Brightness.dark ? EvalColors.dark : EvalColors.light],
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

/// The colours of the three kinds of evaluation (score, win rate, point loss) wherever they are told apart: the
/// graph's lines and scale, the statistics, the panel toggles; and of a player doing better or worse in the report.
/// Each mode has its own, so they stand out against its surfaces (the test checks the contrast).
@immutable
class EvalColors extends ThemeExtension<EvalColors> {
  final Color score;
  final Color winrate;
  final Color pointloss;
  final Color better;
  final Color worse;
  const EvalColors({
    required this.score,
    required this.winrate,
    required this.pointloss,
    required this.better,
    required this.worse,
  });

  static const dark = EvalColors(
    score: Color(0xFF4DB3E6),
    winrate: Color(0xFF1ACC1A),
    pointloss: Color(0xFFCCCC1A),
    better: Color(0xFF2E6B17),
    worse: Color(0xFF9A4A22),
  );

  static const light = EvalColors(
    score: Color(0xFF00639B),
    winrate: Color(0xFF187018),
    pointloss: Color(0xFF7A6300),
    better: Color(0xFFA5D6A7),
    worse: Color(0xFFFFCC80),
  );

  static EvalColors of(BuildContext context) => Theme.of(context).extension<EvalColors>()!;

  /// The three evaluation colours in the order the panels list them.
  List<Color> get all => [score, winrate, pointloss];

  @override
  EvalColors copyWith({Color? score, Color? winrate, Color? pointloss, Color? better, Color? worse}) => EvalColors(
    score: score ?? this.score,
    winrate: winrate ?? this.winrate,
    pointloss: pointloss ?? this.pointloss,
    better: better ?? this.better,
    worse: worse ?? this.worse,
  );

  @override
  EvalColors lerp(EvalColors? other, double t) => other == null
      ? this
      : EvalColors(
          score: Color.lerp(score, other.score, t)!,
          winrate: Color.lerp(winrate, other.winrate, t)!,
          pointloss: Color.lerp(pointloss, other.pointloss, t)!,
          better: Color.lerp(better, other.better, t)!,
          worse: Color.lerp(worse, other.worse, t)!,
        );
}

/// Black or white, whichever reads on [background].
Color textOn(Color background) =>
    ThemeData.estimateBrightnessForColor(background) == Brightness.dark ? Colors.white : Colors.black;
