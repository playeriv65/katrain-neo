// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/lang.py.

import '../utils/format.dart';
import 'strings/all.dart';

export 'strings/all.dart' show translations, languageFonts;

const defaultLanguage = 'en';

/// KaTrain's translations, looked up by KaTrain's message ids (e.g. `menu:newgame`).
///
/// Like Python's gettext with `languages=[lang, "en"]`: a missing translation falls back to English, then to the
/// message id itself. Listeners are told when the language changes, as KaTrain re-renders its widgets.
class I18n {
  String _lang = '';
  Map<String, String> _strings = const {};
  final List<void Function(I18n)> _listeners = [];

  I18n(String lang) {
    switchLang(lang);
  }

  String get lang => _lang;

  /// Font file KaTrain uses for this language, or null for the default font.
  String? get fontName => languageFonts[_lang];

  void switchLang(String lang) {
    if (lang == _lang) return;
    _lang = lang;
    _strings = translations[lang] ?? const {};
    for (final listener in List.of(_listeners)) {
      listener(this);
    }
  }

  void addListener(void Function(I18n) listener) => _listeners.add(listener);

  void removeListener(void Function(I18n) listener) => _listeners.remove(listener);

  /// `i18n._(text)`.
  String tr(String text) => _strings[text] ?? translations[defaultLanguage]![text] ?? text;
}

/// The application-wide translator, like KaTrain's `i18n`.
final i18n = I18n(defaultLanguage);

/// A rank as KaTrain writes it: `3d`, `12k` (localised), `??k` when unknown.
String rankLabel(double? rank) {
  if (rank == null) return '??k';
  if (rank >= 0.5) return '${formatFixed(rank, 0)}${i18n.tr('strength:dan')}';
  return '${formatFixed(1 - rank, 0)}${i18n.tr('strength:kyu')}';
}
