// Differential tests: decoding must give Python's text for every codec (bytes.decode(errors="ignore")), codec names
// must resolve as in Python, and files must be read as pysgf reads them (fixtures from codecs_fixtures.py).

import 'dart:convert';

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'fixtures_util.dart';

List<int> hexBytes(String hex) => [
  for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
];

void main() {
  final data = loadFixture('codecs.json');

  test('decoding matches Python for every codec', () {
    final cases = (data['decoding'] as List).cast<Map<String, dynamic>>();
    final codecs = <String>{};
    for (final c in cases) {
      final codec = c['codec'] as String;
      codecs.add(codec);
      final bytes = hexBytes(c['bytes'] as String);
      final (text, errors) = decodeWith(codec, bytes);
      expect(text, c['text'], reason: '$codec ${c['bytes']}');
      expect(errors, c['errors'], reason: 'errors of $codec ${c['bytes']}');
    }
    expect(codecs.length, greaterThan(60));
  });

  test('codec names resolve as in Python', () {
    final sample = [for (var i = 0; i < 256; i++) i, ...utf8.encode('棋譜 바둑 囲碁 Go')];
    for (final l in (data['lookups'] as List).cast<Map<String, dynamic>>()) {
      expect(pyDecodeIgnore(sample, l['name'] as String), l['text'], reason: 'codec name "${l['name']}"');
    }
  });

  test('encodings are guessed for files without CA', () {
    for (final g in (data['guesses'] as List).cast<Map<String, dynamic>>()) {
      final bytes = hexBytes(g['bytes'] as String);
      expect(detectEncoding(bytes), g['expected'], reason: '${g['name']} (chardet: ${g['chardet']})');
      expect(gameParser.parseBytes(bytes).getProperty('PB'), isNotNull);
      expect(pyDecodeIgnore(bytes, g['expected'] as String), g['text']);
    }
  });

  test('files with CA, and Fox files, are read as pysgf reads them', () {
    for (final f in (data['files'] as List).cast<Map<String, dynamic>>()) {
      final root = gameParser.parseBytes(hexBytes(f['bytes'] as String), fileName: f['file_name'] as String);
      for (final key in ['PB', 'PW', 'EV']) {
        expect(root.getProperty(key), f[key], reason: '$key of ${f['bytes']}');
      }
    }
  });
}
