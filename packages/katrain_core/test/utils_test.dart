// Utils (board grids, evaluation classes, stored analysis floats, visit counts) and translations (switching language,
// fallbacks, placeholders, rank labels).

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

/// The placeholder names in a translation, e.g. `points_lost` in `{points_lost:.1f}`.
Set<String> placeholders(String text) => {for (final m in RegExp(r'\{(\w*)[^{}]*\}').allMatches(text)) m[1]!};

void main() {
  group('utils', () {
    test('a KataGo array becomes a grid indexed by y then x, top row first in the array', () {
      final grid = varToGrid(List.generate(12, (i) => i), (4, 3));
      expect(grid, [
        [8, 9, 10, 11],
        [4, 5, 6, 7],
        [0, 1, 2, 3],
      ]);
      expect(grid[2][0], 0, reason: 'the first value is the top left point');
    });

    test('evaluation class: the index of the first threshold the point loss reaches', () {
      const thresholds = [12, 6, 3, 1.5, 0.5, 0];
      final classes = {20.0: 0, 12.0: 0, 11.9: 1, 6.0: 1, 4.0: 2, 2.0: 3, 1.0: 4, 0.5: 4, 0.4: 5, 0.0: 5, -3.0: 5};
      classes.forEach((pointsLost, cls) => expect(evaluationClass(pointsLost, thresholds), cls, reason: '$pointsLost'));
    });

    test('analysis floats are stored as little-endian half floats', () {
      expect(packFloats([1.0, -2.0]), [0x00, 0x3C, 0x00, 0xC0]);
      expect(packFloats(null), isEmpty);
      final exact = [0.0, 0.5, -0.25, 1.0, -1.0, 1024.0, 65504.0];
      expect(unpackFloats(packFloats(exact), exact.length), exact);
      final values = [0.1234, -0.987, 0.0001, 3.14159, -42.42];
      final roundTrip = unpackFloats(packFloats(values), values.length)!;
      for (var i = 0; i < values.length; i++) {
        expect(roundTrip[i], closeTo(values[i], values[i].abs() * 1e-3 + 1e-7), reason: '${values[i]}');
      }
    });

    test('half floats out of range or of the wrong length are refused', () {
      expect(() => packFloats([1e6]), throwsRangeError);
      expect(unpackFloats([], 3), isNull);
      expect(() => unpackFloats([0, 0, 0], 2), throwsFormatException);
    });

    test('visits are shortened with k and M', () {
      final formats = {0: '0', 950: '950', 999: '999', 1234: '1.2k', 25600: '25.6k', 120000: '120k', 3000000: '3M'};
      formats.forEach((visits, text) => expect(formatVisits(visits), text));
    });
  });

  group('translations', () {
    tearDown(() => i18n.switchLang(defaultLanguage));

    test('switching language changes the texts and tells the listeners once', () {
      final heard = <String>[];
      void listener(I18n t) => heard.add(t.lang);
      i18n.addListener(listener);
      try {
        expect(i18n.tr('menu:newgame'), 'New Game/Change Rules');
        i18n.switchLang('cn');
        expect(i18n.tr('menu:newgame'), '新对局');
        i18n.switchLang('cn');
        i18n.switchLang('de');
        expect(heard, ['cn', 'de']);
      } finally {
        i18n.removeListener(listener);
      }
      i18n.switchLang('en');
      expect(heard, ['cn', 'de'], reason: 'removed listeners are not told');
    });

    test('a missing translation falls back to English, then to the message id', () {
      i18n.switchLang('es');
      expect(translations['es']!.containsKey('ai:human'), isFalse);
      expect(i18n.tr('ai:human'), translations['en']!['ai:human']);
      expect(i18n.tr('no such message'), 'no such message');
      i18n.switchLang('xx');
      expect(i18n.lang, 'xx');
      expect(i18n.tr('menu:newgame'), 'New Game/Change Rules');
    });

    test('every language has English texts for its messages, with the same placeholders', () {
      final english = translations[defaultLanguage]!;
      for (final MapEntry(key: lang, value: strings) in translations.entries) {
        for (final MapEntry(key: id, value: text) in strings.entries) {
          expect(english.containsKey(id), isTrue, reason: '$lang: $id');
          expect(placeholders(text), placeholders(english[id]!), reason: '$lang: $id');
        }
      }
    });

    test('some languages need their own font', () {
      i18n.switchLang('jp');
      expect(i18n.fontName, isNotNull);
      i18n.switchLang('en');
      expect(i18n.fontName, isNull);
    });

    test('ranks are written as dan or kyu in the current language', () {
      final labels = {3.0: '3d', 1.0: '1d', 0.0: '1k', -0.4: '1k', -4.0: '5k', -14.0: '15k'};
      labels.forEach((rank, label) => expect(rankLabel(rank), label, reason: '$rank'));
      expect(rankLabel(null), '??k');
      i18n.switchLang('cn');
      expect(rankLabel(3), '3段');
      expect(rankLabel(-4), '5级');
    });
  });
}
