// Legacy encodings of game records: decoding (GB2312/GBK/GB18030, Big5, Shift-JIS, EUC-JP, EUC-KR/CP949, Windows
// code pages, UTF-8/16/32), codec names, dropping invalid bytes, guessing the encoding of files without CA, and how
// files are decoded by parseBytes (CA, Fox, NGF and GIB). Encoded samples are byte literals.

import 'dart:convert';

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

/// Property values of a game record: (property, text, the text's bytes in the sample's encoding).
typedef Sample = List<(String, String, List<int>)>;

const Sample chineseGbk = [
  ('PB', '柯洁', [0xBF, 0xC2, 0xBD, 0xE0]),
  ('PW', '朴廷桓', [0xC6, 0xD3, 0xCD, 0xA2, 0xBB, 0xB8]),
  (
    'EV',
    '第二十二届三星杯世界围棋公开赛决赛',
    [
      0xB5, 0xDA, 0xB6, 0xFE, 0xCA, 0xAE, 0xB6, 0xFE, 0xBD, 0xEC, 0xC8, 0xFD, 0xD0, 0xC7, 0xB1, 0xAD, 0xCA, 0xC0, //
      0xBD, 0xE7, 0xCE, 0xA7, 0xC6, 0xE5, 0xB9, 0xAB, 0xBF, 0xAA, 0xC8, 0xFC, 0xBE, 0xF6, 0xC8, 0xFC,
    ],
  ),
  ('C', '黑中盘胜', [0xBA, 0xDA, 0xD6, 0xD0, 0xC5, 0xCC, 0xCA, 0xA4]),
];

const Sample chineseBig5 = [
  ('PB', '柯潔', [0xAC, 0x5F, 0xBC, 0xE4]),
  ('PW', '朴廷桓', [0xA6, 0xB5, 0xA7, 0xCA, 0xAE, 0xD9]),
  (
    'EV',
    '第十屆應氏杯世界職業圍棋錦標賽',
    [
      0xB2, 0xC4, 0xA4, 0x51, 0xA9, 0xA1, 0xC0, 0xB3, 0xA4, 0xF3, 0xAA, 0x4D, 0xA5, 0x40, 0xAC, 0xC9, 0xC2, 0xBE, //
      0xB7, 0x7E, 0xB3, 0xF2, 0xB4, 0xD1, 0xC0, 0x41, 0xBC, 0xD0, 0xC1, 0xC9,
    ],
  ),
  ('C', '黑中盤勝', [0xB6, 0xC2, 0xA4, 0xA4, 0xBD, 0x4C, 0xB3, 0xD3]),
];

/// Shift-JIS; the trail byte of 十 is 0x5C, the ASCII backslash.
const Sample japaneseShiftJis = [
  ('PB', '井山裕太', [0x88, 0xE4, 0x8E, 0x52, 0x97, 0x54, 0x91, 0xBE]),
  ('PW', '一力遼', [0x88, 0xEA, 0x97, 0xCD, 0x97, 0xC9]),
  (
    'EV',
    '第七十期本因坊戦挑戦手合七番勝負',
    [
      0x91, 0xE6, 0x8E, 0xB5, 0x8F, 0x5C, 0x8A, 0xFA, 0x96, 0x7B, 0x88, 0xF6, 0x96, 0x56, 0x90, 0xED, 0x92, 0xA7, //
      0x90, 0xED, 0x8E, 0xE8, 0x8D, 0x87, 0x8E, 0xB5, 0x94, 0xD4, 0x8F, 0x9F, 0x95, 0x89,
    ],
  ),
  (
    'C',
    '黒の中押し勝ち。白は右上の戦いで失敗しましたが、左下で頑張りました。',
    [
      0x8D, 0x95, 0x82, 0xCC, 0x92, 0x86, 0x89, 0x9F, 0x82, 0xB5, 0x8F, 0x9F, 0x82, 0xBF, 0x81, 0x42, 0x94, 0x92, //
      0x82, 0xCD, 0x89, 0x45, 0x8F, 0xE3, 0x82, 0xCC, 0x90, 0xED, 0x82, 0xA2, 0x82, 0xC5, 0x8E, 0xB8, 0x94, 0x73, //
      0x82, 0xB5, 0x82, 0xDC, 0x82, 0xB5, 0x82, 0xBD, 0x82, 0xAA, 0x81, 0x41, 0x8D, 0xB6, 0x89, 0xBA, 0x82, 0xC5, //
      0x8A, 0xE6, 0x92, 0xA3, 0x82, 0xE8, 0x82, 0xDC, 0x82, 0xB5, 0x82, 0xBD, 0x81, 0x42,
    ],
  ),
];

/// EUC-JP. Its kanji are valid GB2312 too: the guess tells them apart by the kana of the comment.
const Sample japaneseEucJp = [
  ('PB', '井山裕太', [0xB0, 0xE6, 0xBB, 0xB3, 0xCD, 0xB5, 0xC2, 0xC0]),
  ('PW', '一力遼', [0xB0, 0xEC, 0xCE, 0xCF, 0xCE, 0xCB]),
  (
    'EV',
    '第七十期本因坊戦挑戦手合七番勝負',
    [
      0xC2, 0xE8, 0xBC, 0xB7, 0xBD, 0xBD, 0xB4, 0xFC, 0xCB, 0xDC, 0xB0, 0xF8, 0xCB, 0xB7, 0xC0, 0xEF, 0xC4, 0xA9, //
      0xC0, 0xEF, 0xBC, 0xEA, 0xB9, 0xE7, 0xBC, 0xB7, 0xC8, 0xD6, 0xBE, 0xA1, 0xC9, 0xE9,
    ],
  ),
  (
    'C',
    '黒の中押し勝ち。白は右上の戦いで失敗しましたが、左下で頑張りました。',
    [
      0xB9, 0xF5, 0xA4, 0xCE, 0xC3, 0xE6, 0xB2, 0xA1, 0xA4, 0xB7, 0xBE, 0xA1, 0xA4, 0xC1, 0xA1, 0xA3, 0xC7, 0xF2, //
      0xA4, 0xCF, 0xB1, 0xA6, 0xBE, 0xE5, 0xA4, 0xCE, 0xC0, 0xEF, 0xA4, 0xA4, 0xA4, 0xC7, 0xBC, 0xBA, 0xC7, 0xD4, //
      0xA4, 0xB7, 0xA4, 0xDE, 0xA4, 0xB7, 0xA4, 0xBF, 0xA4, 0xAC, 0xA1, 0xA2, 0xBA, 0xB8, 0xB2, 0xBC, 0xA4, 0xC7, //
      0xB4, 0xE8, 0xC4, 0xA5, 0xA4, 0xEA, 0xA4, 0xDE, 0xA4, 0xB7, 0xA4, 0xBF, 0xA1, 0xA3,
    ],
  ),
];

const Sample koreanEucKr = [
  ('PB', '신진서', [0xBD, 0xC5, 0xC1, 0xF8, 0xBC, 0xAD]),
  ('PW', '박정환', [0xB9, 0xDA, 0xC1, 0xA4, 0xC8, 0xAF]),
  (
    'EV',
    '제이십오회 엘지배 세계기왕전 결승 삼번기',
    [
      0xC1, 0xA6, 0xC0, 0xCC, 0xBD, 0xCA, 0xBF, 0xC0, 0xC8, 0xB8, 0x20, 0xBF, 0xA4, 0xC1, 0xF6, 0xB9, 0xE8, 0x20, //
      0xBC, 0xBC, 0xB0, 0xE8, 0xB1, 0xE2, 0xBF, 0xD5, 0xC0, 0xFC, 0x20, 0xB0, 0xE1, 0xBD, 0xC2, 0x20, 0xBB, 0xEF, //
      0xB9, 0xF8, 0xB1, 0xE2,
    ],
  ),
  (
    'C',
    '흑이 불계로 이겼습니다',
    [
      0xC8, 0xE6, 0xC0, 0xCC, 0x20, 0xBA, 0xD2, 0xB0, 0xE8, 0xB7, 0xCE, 0x20, 0xC0, 0xCC, 0xB0, 0xE5, 0xBD, 0xC0, //
      0xB4, 0xCF, 0xB4, 0xD9,
    ],
  ),
];

const Sample westernCp1252 = [
  ('PB', 'Gérard Müller', [0x47, 0xE9, 0x72, 0x61, 0x72, 0x64, 0x20, 0x4D, 0xFC, 0x6C, 0x6C, 0x65, 0x72]),
  ('PW', 'Jürgen Groß', [0x4A, 0xFC, 0x72, 0x67, 0x65, 0x6E, 0x20, 0x47, 0x72, 0x6F, 0xDF]),
  (
    'EV',
    "Coupe d'Europe – Finale",
    [
      0x43, 0x6F, 0x75, 0x70, 0x65, 0x20, 0x64, 0x27, 0x45, 0x75, 0x72, 0x6F, 0x70, 0x65, 0x20, 0x96, 0x20, 0x46, //
      0x69, 0x6E, 0x61, 0x6C, 0x65,
    ],
  ),
  ('C', 'Très bien joué', [0x54, 0x72, 0xE8, 0x73, 0x20, 0x62, 0x69, 0x65, 0x6E, 0x20, 0x6A, 0x6F, 0x75, 0xE9]),
];

/// The UTF-8 sample of [sample]: the same texts.
Sample utf8Of(Sample sample) => [for (final (p, text, _) in sample) (p, text, utf8.encode(text))];

/// The bytes of a game record with the sample's properties, and [head] (such as `CA[...]`) in the root.
List<int> recordBytes(Sample sample, {String head = ''}) => [
  ...ascii.encode('(;GM[1]FF[4]$head SZ[19]'),
  for (final (property, _, bytes) in sample) ...[...ascii.encode('$property['), ...bytes, ...ascii.encode(']')],
  ...ascii.encode(';B[pd];W[dp])'),
];

/// Expects the root of [root] to have the sample's texts.
void expectTexts(GoNode root, Sample sample, {String? reason}) {
  for (final (property, text, _) in sample) {
    expect(root.getProperty(property), text, reason: '$property ${reason ?? ''}');
  }
  expect(root.children.length, 1, reason: reason);
}

String joined(Sample sample) => [for (final (_, text, _) in sample) text].join('|');

List<int> joinedBytes(Sample sample) => [
  for (var i = 0; i < sample.length; i++) ...[if (i > 0) 0x7C, ...sample[i].$3],
];

void main() {
  group('decoding', () {
    final samples = {
      'gb2312': chineseGbk,
      'gbk': chineseGbk,
      'gb18030': chineseGbk,
      'big5': chineseBig5,
      'cp950': chineseBig5,
      'shift_jis': japaneseShiftJis,
      'cp932': japaneseShiftJis,
      'euc_jp': japaneseEucJp,
      'euc_kr': koreanEucKr,
      'cp949': koreanEucKr,
      'cp1252': westernCp1252,
    };
    for (final MapEntry(key: codec, value: sample) in samples.entries) {
      test('$codec text', () {
        expect(decodeWith(codec, joinedBytes(sample)), (joined(sample), 0));
      });
    }

    test('characters beyond the older code pages', () {
      // GBK has characters GB2312 lacks; GB18030 has all of Unicode, partly as four bytes
      expect(decodeIgnoringErrors([0x81, 0x40], 'gbk'), '丂');
      expect(decodeIgnoringErrors([0x81, 0x40], 'gb2312'), '@');
      expect(decodeIgnoringErrors([0xA2, 0xE3], 'gb18030'), '€');
      expect(decodeIgnoringErrors([0x94, 0x39, 0xFC, 0x36], 'gb18030'), '😀');
      expect(decodeIgnoringErrors([0x81, 0x30, 0x81, 0x30], 'gb18030'), '\u0080');
      // CP949 has all hangul syllables, EUC-KR only the 2350 common ones
      expect(decodeIgnoringErrors([0x8C, 0x63], 'cp949'), '똠');
      expect(decodeIgnoringErrors([0x8C, 0x63], 'euc_kr'), 'c');
      // Windows-1252 has letters where ISO-8859-1 has control characters
      expect(decodeIgnoringErrors([0x80, 0x96, 0xE9], 'cp1252'), '€–é');
      expect(decodeIgnoringErrors([0x80, 0x96, 0xE9], 'latin_1'), '\u0080\u0096é');
    });

    test('other single-byte code pages', () {
      expect(decodeIgnoringErrors([0xC1, 0xC2], 'koi8_r'), 'аб');
      expect(decodeIgnoringErrors([0xE0, 0xE1], 'cp1251'), 'аб');
      expect(decodeIgnoringErrors([0xE1, 0xE2], 'iso8859_7'), 'αβ');
      expect(decodeIgnoringErrors([0xA1], 'tis_620'), 'ก');
      expect(decodeIgnoringErrors([0x8E], 'mac_roman'), 'é');
    });

    test('Unicode encodings', () {
      expect(decodeIgnoringErrors(utf8.encode('棋 Go'), 'utf8'), '棋 Go');
      expect(decodeIgnoringErrors([0xEF, 0xBB, 0xBF, 0x41], 'utf_8_sig'), 'A');
      expect(decodeIgnoringErrors([0xFF, 0xFE, 0x41, 0x00, 0x3D, 0xD8, 0x00, 0xDE], 'utf_16'), 'A😀');
      expect(decodeIgnoringErrors([0xFE, 0xFF, 0x00, 0x41], 'utf_16'), 'A');
      expect(decodeIgnoringErrors([0x00, 0x41], 'utf_16_be'), 'A');
      expect(decodeIgnoringErrors([0x41, 0x00, 0x00, 0x00], 'utf_32_le'), 'A');
      expect(decodeIgnoringErrors([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x01, 0xF6, 0x00], 'utf_32'), '😀');
    });

    test('invalid bytes are dropped and counted', () {
      expect(decodeWith('utf_8', [0x41, 0xFF, 0x42]), ('AB', 1));
      expect(decodeWith('utf_8', [0x41, 0xE6, 0xA3]), ('A', 1)); // cut short at the end
      expect(decodeWith('utf_8', [0xC0, 0xAF]), ('', 2)); // overlong
      expect(decodeWith('utf_8', [0xED, 0xA0, 0x80, 0x41]).$1, 'A'); // surrogate
      expect(decodeWith('gbk', [0xCE, 0xA7, 0xCE]), ('围', 1)); // lead byte at the end
      expect(decodeWith('shift_jis', [0x88, 0xCD, 0xFF, 0x41]), ('囲A', 1));
      expect(decodeWith('utf_16_le', [0x41, 0x00, 0x42]), ('A', 1)); // odd last byte
      expect(decodeWith('utf_16_le', [0x00, 0xDC, 0x41, 0x00]), ('A', 1)); // lone low surrogate
    });
  });

  group('codec names', () {
    test('resolve with any case and punctuation, and with common aliases', () {
      final names = {
        'UTF-8': 'utf_8',
        'utf8': 'utf_8',
        'GB2312': 'gb2312',
        'gb2312-80': 'gb2312',
        'GBK': 'gbk',
        'cp936': 'gbk',
        'GB18030': 'gb18030',
        'Big5': 'big5',
        'Shift_JIS': 'shift_jis',
        'SJIS': 'shift_jis',
        'windows-31j': 'cp932',
        'EUC-JP': 'euc_jp',
        'EUC-KR': 'euc_kr',
        'UHC': 'cp949',
        'ISO-8859-1': 'latin_1',
        'latin1': 'latin_1',
        'Windows-1252': 'cp1252',
        'US-ASCII': 'ascii',
      };
      for (final MapEntry(key: name, value: codec) in names.entries) {
        expect(codecName(name), codec, reason: name);
      }
    });

    test('unknown names have no codec', () {
      expect(codecName('klingon'), isNull);
      expect(codecName(''), isNull);
      expect(decodeIgnoringErrors([0x41], 'klingon'), isNull);
    });
  });

  group('guessing the encoding of files without CA', () {
    final samples = {
      'GBK': chineseGbk,
      'Big5': chineseBig5,
      'Shift-JIS': japaneseShiftJis,
      'EUC-JP': japaneseEucJp,
      'EUC-KR': koreanEucKr,
      'Windows-1252': westernCp1252,
      'UTF-8': utf8Of(chineseGbk),
    };
    for (final MapEntry(key: name, value: sample) in samples.entries) {
      test(name, () {
        expectTexts(goParser.parseBytes(recordBytes(sample)), sample);
      });
    }

    test('plain ASCII and UTF-8 are read as UTF-8, byte order marks are followed', () {
      expect(detectEncoding(ascii.encode('(;PB[x])')), 'utf_8');
      expect(detectEncoding(utf8.encode('(;PB[柯洁])')), 'utf_8');
      expect(detectEncoding([0xEF, 0xBB, 0xBF, ...ascii.encode('(;)')]), 'utf_8_sig');
      expect(detectEncoding([0xFF, 0xFE, 0x28, 0x00]), 'utf_16');
      final utf16 = [
        0xFF,
        0xFE,
        for (final unit in '(;PB[柯洁])'.codeUnits) ...[unit & 0xFF, unit >> 8],
      ];
      expect(goParser.parseBytes(utf16).getProperty('PB'), '柯洁');
      final withBom = [0xEF, 0xBB, 0xBF, ...utf8.encode('(;PB[柯洁])')];
      expect(goParser.parseBytes(withBom).getProperty('PB'), '柯洁');
    });
  });

  group('CA', () {
    final labelled = {
      'GB2312': chineseGbk,
      'gbk': chineseGbk,
      'Big5': chineseBig5,
      'SJIS': japaneseShiftJis,
      'EUC-JP': japaneseEucJp,
      'EUC-KR': koreanEucKr,
      'ISO-8859-1': westernCp1252.take(2).toList(), // no en dash in ISO-8859-1
      'UTF-8': utf8Of(koreanEucKr),
    };
    for (final MapEntry(key: ca, value: sample) in labelled.entries) {
      test('CA[$ca] decodes the file', () {
        expectTexts(goParser.parseBytes(recordBytes(sample, head: 'CA[$ca]')), sample);
      });
    }

    test('CA is followed even when a guess would differ', () {
      // the same bytes read as KOI8-R and as Windows-1252
      final bytes = recordBytes([
        ('PB', '', const [0xC1, 0xC2]),
      ], head: 'CA[KOI8-R]');
      expect(goParser.parseBytes(bytes).getProperty('PB'), 'аб');
      final cp1252 = recordBytes([
        ('PB', '', const [0xC1, 0xC2]),
      ], head: 'CA[windows-1252]');
      expect(goParser.parseBytes(cp1252).getProperty('PB'), 'ÁÂ');
    });

    test('an unknown CA is read as UTF-8', () {
      final sample = utf8Of(chineseGbk);
      expectTexts(goParser.parseBytes(recordBytes(sample, head: 'CA[klingon]')), sample);
    });

    test('an explicit encoding overrides CA', () {
      final bytes = recordBytes(chineseGbk, head: 'CA[UTF-8]');
      expectTexts(goParser.parseBytes(bytes, encoding: 'gb18030'), chineseGbk);
    });

    test('Fox records are UTF-8 whatever CA says', () {
      final sample = utf8Of(chineseGbk);
      final root = goParser.parseBytes(recordBytes(sample, head: 'CA[gb2312]AP[foxwq]'));
      expectTexts(root, sample);
    });

    test('NGF and GIB records are UTF-8', () {
      final ngf = [
        'Rated game', '19', '白棋 3D', '黑棋 2D', 'www.cyberoro.com', '0', '0', '6', '20200102 [10:00]', '5', //
        'Black wins', '1', 'PMABBEEEE',
      ].join('\n');
      expect(goParser.parseBytes(utf8.encode(ngf), fileName: 'game.ngf').getProperty('PW'), '白棋');
      final gib = ['\\[GAMEBLACKNAME=김 (2D)\\]', 'INI 0 1 0 &4', 'STO 0 2 1 3 3 '].join('\n');
      expect(goParser.parseBytes(utf8.encode(gib), fileName: 'game.gib').getProperty('PB'), '김');
    });
  });
}
