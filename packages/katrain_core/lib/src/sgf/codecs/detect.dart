/// Guessing the encoding of an SGF file that does not say (no `CA` property).
///
/// pysgf asks chardet (LGPL, so not ported) about the first 300 bytes, and reads Windows-1252 and GB2312 answers as
/// GBK. This guess looks at the whole file instead: UTF-8 when it is valid UTF-8; otherwise the CJK codec that
/// decodes it with the fewest errors and the most plausible text (the language's most frequent characters, its own
/// script: kana, hangul, GB2312 hanzi); Windows-1252 for western text, whose high bytes stand alone between ASCII.
/// Ties go to Chinese. Short texts in Korean can look like Chinese and are then misread, as with chardet.
library;

import 'decode.dart';
import 'tables.dart';

/// The encoding to decode [bytes] with, as a Python codec name.
String detectEncoding(List<int> bytes) {
  final n = bytes.length;
  if (n >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) return 'utf_8_sig';
  if (n >= 4 && bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0 && bytes[3] == 0) return 'utf_32';
  if (n >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xFE && bytes[3] == 0xFF) return 'utf_32';
  if (n >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) return 'utf_16';
  if (decodeWith('utf_8', bytes).$2 == 0) return 'utf_8';

  // western text: high bytes between ASCII bytes
  var high = 0;
  var isolated = 0;
  for (var i = 0; i < n; i++) {
    if (bytes[i] < 0x80) continue;
    high += 1;
    if ((i == 0 || bytes[i - 1] < 0x80) && (i == n - 1 || bytes[i + 1] < 0x80)) isolated += 1;
  }
  if (high > 0 && isolated >= 0.8 * high) return 'cp1252';

  String? best;
  var bestErrors = 0;
  var bestScore = 0.0;
  for (final codec in const ['gb18030', 'cp950', 'cp949', 'cp932', 'euc_jp']) {
    final (text, errors) = decodeWith(codec, bytes);
    final score = _plausibility(codec, text);
    if (best == null || errors < bestErrors || (errors == bestErrors && score > bestScore)) {
      best = codec;
      bestErrors = errors;
      bestScore = score;
    }
  }
  return best!;
}

final _frequent = {for (final e in frequentCharacters.entries) e.key: e.value.runes.toSet()};

/// How much [text] looks like the language of [codec]: the share of its non-ASCII characters that are among the
/// language's most frequent ones, plus half the share in the language's own script.
double _plausibility(String codec, String text) {
  var total = 0;
  var frequent = 0;
  var native = 0;
  final language = switch (codec) {
    'gb18030' || 'cp950' => 'chinese',
    'cp949' => 'korean',
    _ => 'japanese',
  };
  final common = _frequent[language]!;
  for (final cp in text.runes) {
    if (cp < 0x80) continue;
    total += 1;
    if (common.contains(cp)) frequent += 1;
    final isNative = switch (language) {
      'korean' => _ksHangul.contains(cp),
      'japanese' => cp >= 0x3040 && cp <= 0x30FF,
      _ => codec == 'gb18030' ? _inGb2312Hanzi(cp) : _inBig5Common(cp),
    };
    if (isNative) native += 1;
  }
  if (total == 0) return 0;
  return (frequent + native / 2) / total;
}

final _gb2312Hanzi = () {
  // the hanzi of GB2312 (rows 0xB0-0xF7): the ones simplified Chinese text is written in
  final (text, _) = decodeWith('gb2312', [
    for (var lead = 0xB0; lead <= 0xF7; lead++)
      for (var trail = 0xA1; trail <= 0xFE; trail++) ...[lead, trail],
  ]);
  return text.runes.toSet();
}();

bool _inGb2312Hanzi(int cp) => _gb2312Hanzi.contains(cp);

final _ksHangul = () {
  // the 2350 hangul syllables of KS X 1001 (EUC-KR 0xB0A1-0xC8FE), the ones Korean is written with; CP949 can
  // encode all 11172, and reads almost any byte pair as one of the rare ones
  final (text, _) = decodeWith('euc_kr', [
    for (var lead = 0xB0; lead <= 0xC8; lead++)
      for (var trail = 0xA1; trail <= 0xFE; trail++) ...[lead, trail],
  ]);
  return text.runes.toSet();
}();

final _big5Common = () {
  // the frequently used characters of Big5 (0xA440-0xC67E)
  final (text, _) = decodeWith('cp950', [
    for (var lead = 0xA4; lead <= 0xC6; lead++)
      for (final trail in [for (var t = 0x40; t <= 0x7E; t++) t, for (var t = 0xA1; t <= 0xFE; t++) t])
        if (lead < 0xC6 || trail <= 0x7E) ...[lead, trail],
  ]);
  return text.runes.toSet();
}();

bool _inBig5Common(int cp) => _big5Common.contains(cp);
