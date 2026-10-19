// Differential tests: Python number formatting, half floats, random numbers, KaTrain utils and translations
// (fixtures from tools/fixtures).

import 'dart:typed_data';

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'fixtures_util.dart';

double doubleFromHex(String hex) {
  final bytes = Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
  return ByteData.sublistView(bytes).getFloat64(0, Endian.little);
}

String toHex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

void main() {
  final data = loadFixture('utils.json');

  test('number formatting and rounding match Python', () {
    for (final f in (data['formats'] as List).cast<Map<String, dynamic>>()) {
      final x = doubleFromHex(f['x'] as String);
      final reason = 'x = ${f['repr']}';
      expect(pyFloatRepr(x), f['repr'], reason: reason);
      expect(pyFixed(x, 0), f['f0'], reason: reason);
      expect(pyFixed(x, 1), f['f1'], reason: reason);
      expect(pyFixed(x, 2), f['f2'], reason: reason);
      expect(pyFixed(x, 6), f['f6'], reason: reason);
      expect(pyFixed(x, 1, plus: true), f['p1f'], reason: reason);
      expect(pyExp(x, 0), f['e0'], reason: reason);
      expect(pyExp(x, 3), f['e3'], reason: reason);
      expect(pyPercent(x, 1), f['pc1'], reason: reason);
      expect(pyPercent(x, 2), f['pc2'], reason: reason);
      expect(pyPercent(x, 1, plus: true), f['ppc1'], reason: reason);
      if (f['round'] != null) expect(pyRound(x), f['round'], reason: reason);
      expect(pyFloatRepr(pyRoundTo(x, 1)), f['round1'], reason: reason);
      expect(pyFloatRepr(pyRoundTo(x, 2)), f['round2'], reason: reason);
    }
  });

  test('half-float packing matches struct', () {
    for (final h in (data['halves'] as List).cast<Map<String, dynamic>>()) {
      final values = [for (final v in h['values'] as List) doubleFromHex(v as String)];
      final packed = packFloats(values);
      expect(toHex(packed), h['packed']);
      expect([for (final v in unpackFloats(packed, values.length)!) pyFloatRepr(v)], h['unpacked']);
    }
    expect(() => packFloats([1e16]), throwsRangeError);
    expect(unpackFloats([], 3), isNull);
  });

  test('random numbers match Python', () {
    final randoms = data['randoms'] as Map<String, dynamic>;
    for (final MapEntry(key: seed, value: expected) in randoms.entries) {
      final r = PyRandom.big(BigInt.parse(seed));
      final values = [for (var i = 0; i < (expected as List).length; i++) pyFloatRepr(r.random())];
      expect(values, expected, reason: 'seed $seed');
    }
  });

  test('weighted selection matches KaTrain', () {
    for (final s in (data['selections'] as List).cast<Map<String, dynamic>>()) {
      final items = [
        for (final item in s['items'] as List) ((item as List)[0] as String, doubleFromHex(item[1] as String)),
      ];
      final picked = weightedSelectionWithoutReplacement(items, s['n'] as int, (i) => i.$2, PyRandom(s['seed'] as int));
      expect([for (final p in picked) p.$1], s['picked'], reason: 'seed ${s['seed']} n ${s['n']}');
    }
  });

  test('grid, evaluation class, visits and json.dumps', () {
    final misc = data['misc'] as Map<String, dynamic>;
    expect(varToGrid(List.generate(12, (i) => i), (4, 3)), misc['var_to_grid']);
    for (final e in misc['evaluation_class'] as List) {
      expect(evaluationClass((e[0] as num).toDouble(), [12, 6, 3, 1.5, 0.5, 0]), e[1], reason: 'points lost ${e[0]}');
    }
    for (final e in misc['format_visits'] as List) {
      expect(formatVisits(e[0] as int), e[1]);
    }
    for (final e in misc['json_dumps'] as List) {
      expect(pyJsonDumps(e[0]), e[1]);
    }
    for (final e in misc['repr'] as List) {
      expect(pyRepr(e[0]), e[1]);
    }
    for (final e in misc['sums'] as List) {
      final values = [for (final v in e[0] as List) v is String ? doubleFromHex(v) : v as num];
      expect(pyStr(pySum(values)), e[1], reason: 'sum of $values');
    }
  });

  test('translations and rank labels match KaTrain', () {
    final ranks = [for (final r in data['ranks'] as List) (r as num?)?.toDouble()];
    final byLang = data['translations'] as Map<String, dynamic>;
    try {
      for (final MapEntry(key: lang, value: expected) in byLang.entries) {
        i18n.switchLang(lang);
        final keys = (expected as Map<String, dynamic>)['keys'] as Map<String, dynamic>;
        for (final MapEntry(key: key, value: text) in keys.entries) {
          expect(i18n.tr(key), text, reason: '$lang: $key');
        }
        expect([for (final r in ranks) rankLabel(r)], expected['rank_labels'], reason: lang);
      }
    } finally {
      i18n.switchLang(defaultLanguage);
    }
  });
}
