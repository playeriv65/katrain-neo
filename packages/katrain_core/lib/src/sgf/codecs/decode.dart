/// Python's `bytes.decode(encoding, errors="ignore")`, which KaTrain (through pysgf) decodes SGF files with: the same
/// codec names and aliases, and the same text, invalid bytes dropped exactly where Python drops them. The tables come
/// from CPython (tools/port/codecs_gen.py).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'tables.dart';

const _illegal = 0xFFFE; // in the tables: an error; 0xFFFF: a lead byte

Uint16List _unpack16(String data) {
  final bytes = Uint8List.fromList(GZipDecoder().decodeBytes(base64.decode(data)));
  return bytes.buffer.asUint16List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
}

Uint32List _unpack32(String data) {
  final bytes = Uint8List.fromList(GZipDecoder().decodeBytes(base64.decode(data)));
  return bytes.buffer.asUint32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
}

final Map<String, Uint16List> _singleByte = {};
final Map<String, (Uint16List, Uint16List)> _multiByte = {};
Uint32List? _gb18030Runs;
Uint16List? _eucJp3;

/// Python's `_Py_normalize_encoding`: ASCII letters, digits and dots lowercased, other runs of characters becoming
/// one underscore between them.
String normalizeEncodingName(String name) {
  final out = StringBuffer();
  var punct = false;
  for (final unit in name.codeUnits) {
    final alnum = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
    if (alnum || unit == 0x2E) {
      if (punct && out.isNotEmpty) out.write('_');
      punct = false;
      out.writeCharCode(unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit);
    } else {
      punct = true;
    }
  }
  return out.toString();
}

/// The codec Python finds for [encoding] (`codecs.lookup`), among the supported ones; null when Python would raise
/// LookupError, or for a codec this port does not have.
String? codecName(String encoding) {
  final norm = normalizeEncodingName(encoding);
  if (norm.isEmpty) return null;
  return codecAliases[norm] ?? codecAliases[norm.replaceAll('.', '_')];
}

/// `bytes.decode(encoding, errors="ignore")`, or null when Python has no codec of that name (or this port does not
/// support it; Python's codecs for EBCDIC, ISO-2022, HZ, UTF-7, Big5-HKSCS and a few others are not included).
String? decodeIgnoringErrors(List<int> bytes, String encoding) {
  final codec = codecName(encoding);
  if (codec == null) return null;
  return decodeWith(codec, bytes).$1;
}

/// Decodes with a supported codec, and counts the errors (bytes or sequences Python would report).
(String, int) decodeWith(String codec, List<int> bytes) {
  switch (codec) {
    case 'utf_8':
      return _decodeUtf8(bytes, 0);
    case 'utf_8_sig':
      final bom = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
      return _decodeUtf8(bytes, bom ? 3 : 0);
    case 'utf_16' || 'utf_16_le' || 'utf_16_be':
      return _decodeUtf16(bytes, codec);
    case 'utf_32' || 'utf_32_le' || 'utf_32_be':
      return _decodeUtf32(bytes, codec);
  }
  if (singleByteTables.containsKey(codec)) {
    final table = _singleByte.putIfAbsent(codec, () => _unpack16(singleByteTables[codec]!));
    final out = StringBuffer();
    var errors = 0;
    for (final b in bytes) {
      final cp = table[b & 0xFF];
      if (cp == _illegal) {
        errors += 1;
      } else {
        out.writeCharCode(cp);
      }
    }
    return (out.toString(), errors);
  }
  final packed = multiByteTables[codec];
  if (packed == null) throw ArgumentError('unsupported codec $codec');
  final (single, pair) = _multiByte.putIfAbsent(codec, () => (_unpack16(packed.$1), _unpack16(packed.$2)));
  return _decodeMultiByte(codec, single, pair, bytes);
}

(String, int) _decodeMultiByte(String codec, Uint16List single, Uint16List pair, List<int> bytes) {
  final out = StringBuffer();
  var errors = 0;
  final n = bytes.length;
  var i = 0;
  while (i < n) {
    final b = bytes[i] & 0xFF;
    final s = single[b];
    if (s < _illegal) {
      out.writeCharCode(s);
      i += 1;
      continue;
    }
    if (s == _illegal) {
      errors += 1;
      i += 1;
      continue;
    }
    // a lead byte; a sequence cut short by the end of the input drops the rest (Python's "incomplete" error)
    if (i + 1 >= n) {
      errors += 1;
      break;
    }
    final p = pair[(b - 0x80) * 256 + (bytes[i + 1] & 0xFF)];
    if (p < _illegal) {
      out.writeCharCode(p);
      i += 2;
      continue;
    }
    if (p == _illegal) {
      errors += 1;
      i += 1;
      continue;
    }
    // longer sequences
    final (needed, cp) = switch (codec) {
      'gb18030' => (4, i + 3 < n ? _gb18030Four(bytes, i) : null),
      'euc_jp' => (3, i + 2 < n ? _eucJpThree(bytes, i) : null),
      'euc_kr' => (8, i + 7 < n ? _eucKrMakeUp(bytes, i) : null),
      _ => throw StateError('unexpected long sequence in $codec'),
    };
    if (i + needed > n) {
      errors += 1;
      break;
    }
    if (cp == null) {
      errors += 1;
      i += 1;
    } else {
      out.writeCharCode(cp);
      i += needed;
    }
  }
  return (out.toString(), errors);
}

int? _gb18030Four(List<int> bytes, int i) {
  final [b1, b2, b3, b4] = [for (var k = 0; k < 4; k++) bytes[i + k] & 0xFF];
  if (b3 < 0x81 || b3 > 0xFE || b4 < 0x30 || b4 > 0x39) return null;
  final index = (((b1 - 0x81) * 10 + (b2 - 0x30)) * 126 + (b3 - 0x81)) * 10 + (b4 - 0x30);
  final runs = _gb18030Runs ??= _unpack32(gb18030FourByteRuns);
  // binary search over the run starts
  var lo = 0;
  var hi = runs.length ~/ 3 - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final start = runs[mid * 3];
    if (index < start) {
      hi = mid - 1;
    } else if (index >= start + runs[mid * 3 + 2]) {
      lo = mid + 1;
    } else {
      return runs[mid * 3 + 1] + index - start;
    }
  }
  return null;
}

int? _eucJpThree(List<int> bytes, int i) {
  final b2 = bytes[i + 1] & 0xFF;
  final b3 = bytes[i + 2] & 0xFF;
  if (b2 < 0xA1 || b2 > 0xFE || b3 < 0xA1 || b3 > 0xFE) return null;
  final cp = (_eucJp3 ??= _unpack16(eucJpThreeByte))[(b2 - 0xA1) * 94 + (b3 - 0xA1)];
  return cp == _illegal ? null : cp;
}

int? _eucKrMakeUp(List<int> bytes, int i) {
  int at(int k) => bytes[i + k] & 0xFF;
  if (at(2) != 0xA4 || at(4) != 0xA4 || at(6) != 0xA4) return null;
  int index(List<int> table, int b) => (b >= 0xA1 && b <= 0xFE) ? table[b - 0xA1] : -1;
  final cho = index(eucKrChoseong, at(3));
  final jung = index(eucKrJungseong, at(5));
  final jong = index(eucKrJongseong, at(7));
  if (cho < 0 || jung < 0 || jong < 0) return null;
  return 0xAC00 + cho * 588 + jung * 28 + jong;
}

/// UTF-8 as CPython decodes it: an invalid sequence is dropped up to the byte where it stops being valid (the
/// "maximal subpart" of the Unicode standard), and a sequence cut short by the end drops the rest.
(String, int) _decodeUtf8(List<int> bytes, int start) {
  final out = StringBuffer();
  var errors = 0;
  final n = bytes.length;
  var i = start;
  while (i < n) {
    final b = bytes[i] & 0xFF;
    if (b < 0x80) {
      out.writeCharCode(b);
      i += 1;
      continue;
    }
    int length;
    int cp;
    var lo = 0x80;
    var hi = 0xBF;
    if (b >= 0xC2 && b <= 0xDF) {
      length = 2;
      cp = b & 0x1F;
    } else if (b >= 0xE0 && b <= 0xEF) {
      length = 3;
      cp = b & 0x0F;
      if (b == 0xE0) lo = 0xA0;
      if (b == 0xED) hi = 0x9F;
    } else if (b >= 0xF0 && b <= 0xF4) {
      length = 4;
      cp = b & 0x07;
      if (b == 0xF0) lo = 0x90;
      if (b == 0xF4) hi = 0x8F;
    } else {
      errors += 1; // invalid start byte
      i += 1;
      continue;
    }
    var k = 1;
    var valid = true;
    while (k < length) {
      if (i + k >= n) {
        valid = false;
        break;
      }
      final c = bytes[i + k] & 0xFF;
      final (low, high) = k == 1 ? (lo, hi) : (0x80, 0xBF);
      if (c < low || c > high) {
        valid = false;
        break;
      }
      cp = (cp << 6) | (c & 0x3F);
      k += 1;
    }
    if (!valid) {
      errors += 1;
      i += k; // the valid prefix is dropped as one error
      continue;
    }
    out.writeCharCode(cp);
    i += length;
  }
  return (out.toString(), errors);
}

/// UTF-16 as CPython decodes it: a byte order mark chooses the order (`utf_16` only; little endian without one), an
/// unpaired surrogate is dropped, and so is an odd last byte.
(String, int) _decodeUtf16(List<int> bytes, String codec) {
  var i = 0;
  var bigEndian = codec == 'utf_16_be';
  if (codec == 'utf_16' && bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      i = 2;
    } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      i = 2;
      bigEndian = true;
    }
  }
  int unit(int at) => bigEndian ? (bytes[at] << 8) | bytes[at + 1] : (bytes[at + 1] << 8) | bytes[at];
  final out = StringBuffer();
  var errors = 0;
  final n = bytes.length;
  while (i + 1 < n) {
    final u = unit(i);
    if (u < 0xD800 || u > 0xDFFF) {
      out.writeCharCode(u);
      i += 2;
    } else if (u <= 0xDBFF) {
      if (i + 3 >= n) {
        // a high surrogate cut short by the end drops the rest
        errors += 1;
        i = n;
        break;
      }
      final v = unit(i + 2);
      if (v >= 0xDC00 && v <= 0xDFFF) {
        out.writeCharCode(0x10000 + ((u - 0xD800) << 10) + (v - 0xDC00));
        i += 4;
      } else {
        errors += 1; // illegal UTF-16 surrogate
        i += 2;
      }
    } else {
      errors += 1; // illegal encoding
      i += 2;
    }
  }
  if (i < n) errors += 1; // truncated data
  return (out.toString(), errors);
}

/// UTF-32 as CPython decodes it: a byte order mark chooses the order (`utf_32` only; little endian without one), and
/// surrogates and values above 0x10FFFF are dropped, as is an incomplete last unit.
(String, int) _decodeUtf32(List<int> bytes, String codec) {
  var i = 0;
  var bigEndian = codec == 'utf_32_be';
  if (codec == 'utf_32' && bytes.length >= 4) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0 && bytes[3] == 0) {
      i = 4;
    } else if (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xFE && bytes[3] == 0xFF) {
      i = 4;
      bigEndian = true;
    }
  }
  final out = StringBuffer();
  var errors = 0;
  final n = bytes.length;
  while (i + 3 < n) {
    final cp = bigEndian
        ? (bytes[i] << 24) | (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3]
        : (bytes[i + 3] << 24) | (bytes[i + 2] << 16) | (bytes[i + 1] << 8) | bytes[i];
    if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
      errors += 1;
    } else {
      out.writeCharCode(cp);
    }
    i += 4;
  }
  if (i < n) errors += 1;
  return (out.toString(), errors);
}
