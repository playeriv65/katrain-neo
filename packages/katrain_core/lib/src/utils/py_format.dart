/// Helpers that reproduce Python behaviour the ported code relies on: `str()` of values, `int()`, stable sorting,
/// and number formatting/rounding with Python's exact round-half-even rules.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// The string Python's `str()` (and so an f-string) gives for None, bools, numbers, strings, lists and dicts.
String pyStr(Object? value) {
  if (value == null) return 'None';
  if (value is String) return value;
  if (value is bool) return value ? 'True' : 'False';
  if (value is double) return pyFloatRepr(value);
  if (value is List || value is Map) return pyRepr(value);
  return value.toString();
}

/// Python's `repr()` of the values ported code writes into log lines: None, bools, numbers, strings, and lists and
/// dicts of them. (Tuples have no Dart equivalent; callers format those themselves.)
String pyRepr(Object? value) {
  if (value is String) return _pyStrRepr(value);
  if (value is List) return '[${value.map(pyRepr).join(', ')}]';
  if (value is Map) return '{${[for (final e in value.entries) '${pyRepr(e.key)}: ${pyRepr(e.value)}'].join(', ')}}';
  return pyStr(value);
}

String _pyStrRepr(String s) {
  final quote = s.contains("'") && !s.contains('"') ? '"' : "'";
  final out = StringBuffer(quote);
  for (final rune in s.runes) {
    if (rune == 0x5c) {
      out.write(r'\\');
    } else if (rune == quote.codeUnitAt(0)) {
      out.write('\\$quote');
    } else if (rune == 0x0a) {
      out.write(r'\n');
    } else if (rune == 0x0d) {
      out.write(r'\r');
    } else if (rune == 0x09) {
      out.write(r'\t');
    } else if (rune < 0x20 || (rune >= 0x7f && rune <= 0xa0) || rune == 0xad) {
      // not printable (Python checks the full Unicode tables; these are the ones that come up)
      out.write(r'\x');
      out.write(rune.toRadixString(16).padLeft(2, '0'));
    } else {
      out.writeCharCode(rune);
    }
  }
  out.write(quote);
  return out.toString();
}

/// Python's `repr(float)`/`str(float)`: the shortest digits that round-trip (Dart computes the same ones), written
/// in fixed notation for decimal exponents from -4 to 15 and in scientific notation otherwise.
String pyFloatRepr(double value) {
  if (value.isNaN) return 'nan';
  if (value.isInfinite) return value > 0 ? 'inf' : '-inf';
  final sign = (value < 0 || (value == 0 && value.isNegative)) ? '-' : '';
  if (value == 0) return '${sign}0.0';
  // digits and exponent from Dart's shortest representation: value = 0.<digits> * 10^point
  final dart = value.abs().toString();
  String digits;
  int point;
  final eIndex = dart.indexOf('e');
  final mantissa = eIndex < 0 ? dart : dart.substring(0, eIndex);
  final exp = eIndex < 0 ? 0 : int.parse(dart.substring(eIndex + 1));
  final dot = mantissa.indexOf('.');
  final intPart = dot < 0 ? mantissa : mantissa.substring(0, dot);
  final fracPart = dot < 0 ? '' : mantissa.substring(dot + 1);
  digits = intPart + fracPart;
  point = intPart.length + exp;
  final lead = digits.length - digits.replaceFirst(RegExp('^0+'), '').length;
  digits = digits.substring(lead);
  point -= lead;
  digits = digits.replaceFirst(RegExp(r'0+$'), '');
  if (digits.isEmpty) return '${sign}0.0';
  final decimalExponent = point - 1; // as in d.ddd x 10^decimalExponent
  if (decimalExponent < -4 || decimalExponent >= 16) {
    final m = digits.length > 1 ? '${digits[0]}.${digits.substring(1)}' : digits;
    final e = decimalExponent.abs().toString().padLeft(2, '0');
    return '$sign${m}e${decimalExponent < 0 ? '-' : '+'}$e';
  }
  if (point <= 0) return '${sign}0.${'0' * -point}$digits';
  if (point >= digits.length) return '$sign$digits${'0' * (point - digits.length)}.0';
  return '$sign${digits.substring(0, point)}.${digits.substring(point)}';
}

/// Python's `int(str)`: surrounding whitespace allowed, otherwise strict.
int pyInt(String value) {
  final parsed = int.tryParse(value.trim());
  if (parsed == null) throw FormatException('invalid literal for int(): $value');
  return parsed;
}

/// Python's `sum(values)` (3.12 and later): ints are added exactly until the first float, then floats are added
/// with Neumaier's compensated summation, which can give a different last digit than adding one by one.
num pySum(Iterable<num> values) {
  final it = values.iterator;
  var intResult = 0;
  while (it.moveNext()) {
    final v = it.current;
    if (v is int) {
      intResult += v;
      continue;
    }
    var f = intResult + v.toDouble();
    var c = 0.0;
    while (it.moveNext()) {
      final w = it.current;
      if (w is double) {
        final t = f + w;
        if (f.abs() >= w.abs()) {
          c += (f - t) + w;
        } else {
          c += (w - t) + f;
        }
        f = t;
      } else {
        f += w.toDouble();
      }
    }
    if (c != 0 && c.isFinite) f += c;
    return f;
  }
  return intResult;
}

/// Stable sort by a key, like Python's `list.sort(key=...)` (Dart's List.sort is not guaranteed stable).
void mergeSortBy<T>(List<T> list, Comparable Function(T) key, {bool reverse = false}) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, key(list[i]), list[i])];
  indexed.sort((a, b) {
    final c = reverse ? b.$2.compareTo(a.$2) : a.$2.compareTo(b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$3;
  }
}

/// The exact value of a finite double as numerator / 2^shift (shift >= 0).
(BigInt, int) _exact(double x) {
  final bytes = ByteData(8)..setFloat64(0, x.abs());
  final bits = bytes.getUint64(0);
  final exponent = (bits >> 52) & 0x7FF;
  var mantissa = BigInt.from(bits & 0xFFFFFFFFFFFFF);
  int e;
  if (exponent == 0) {
    e = -1074; // subnormal
  } else {
    mantissa += BigInt.one << 52;
    e = exponent - 1075;
  }
  if (e >= 0) return (mantissa << e, 0);
  return (mantissa, -e);
}

/// round(|x| * 10^digits) to an integer, ties to even, using the exact binary value of x (as Python does).
/// [digits] may be negative.
BigInt _scaledRounded(double x, int digits) {
  final (numerator, shift) = _exact(x);
  final ten = BigInt.from(10);
  final n = digits >= 0 ? numerator * ten.pow(digits) : numerator;
  final d = (BigInt.one << shift) * (digits >= 0 ? BigInt.one : ten.pow(-digits));
  if (d == BigInt.one) return n;
  final q = n ~/ d;
  final r = n - q * d;
  final twice = r * BigInt.two;
  if (twice > d || (twice == d && q.isOdd)) return q + BigInt.one;
  return q;
}

/// Python's `format(x, '.Nf')`, with an optional `+` sign flag (`'+.Nf'`).
String pyFixed(double x, int digits, {bool plus = false}) {
  if (x.isNaN) return 'nan';
  if (x.isInfinite) return '${x > 0 ? (plus ? '+' : '') : '-'}inf';
  final negative = x < 0 || (x == 0 && x.isNegative);
  var s = _scaledRounded(x, digits).toString();
  if (digits > 0) {
    s = s.padLeft(digits + 1, '0');
    s = '${s.substring(0, s.length - digits)}.${s.substring(s.length - digits)}';
  }
  return '${negative ? '-' : (plus ? '+' : '')}$s';
}

/// Python's `format(x, '.Ne')`: one digit before the point, [digits] after it, and an exponent of at least two digits.
String pyExp(double x, int digits) {
  if (x.isNaN) return 'nan';
  if (x.isInfinite) return x > 0 ? 'inf' : '-inf';
  final negative = x < 0 || (x == 0 && x.isNegative);
  var exponent = 0;
  var mantissa = BigInt.zero;
  if (x != 0) {
    exponent = (math.log(x.abs()) / math.ln10).floor();
    final low = BigInt.from(10).pow(digits);
    final high = low * BigInt.from(10);
    // the estimate can be one off either way; rounding up can also carry into the next power of ten
    for (var i = 0; i < 4; i++) {
      mantissa = _scaledRounded(x, digits - exponent);
      if (mantissa >= high) {
        exponent += 1;
      } else if (mantissa < low) {
        exponent -= 1;
      } else {
        break;
      }
    }
  }
  var s = mantissa.toString().padLeft(digits + 1, '0');
  if (digits > 0) s = '${s[0]}.${s.substring(1)}';
  final e = exponent.abs().toString().padLeft(2, '0');
  return '${negative ? '-' : ''}${s}e${exponent < 0 ? '-' : '+'}$e';
}

/// Python's `format(x, '.N%')`: x * 100 in floating point, then fixed with a percent sign.
String pyPercent(double x, int digits, {bool plus = false}) => '${pyFixed(x * 100, digits, plus: plus)}%';

/// Python's `round(x)` to an integer, ties to even.
int pyRound(double x) {
  final r = _scaledRounded(x, 0).toInt();
  return x < 0 ? -r : r;
}

/// Python's `round(x, n)` for n >= 0: the double nearest to the correctly rounded decimal.
double pyRoundTo(double x, int n) {
  if (!x.isFinite) return x;
  final s = pyFixed(x, n);
  return double.parse(s);
}

/// Python's `json.dumps(value)` with its defaults: `', '` and `': '` separators, Python's float repr, and every
/// character outside printable ASCII escaped as `\uXXXX`.
///
/// With [indent], like `json.dumps(value, indent=indent)`: one item per line, and `','` without a space.
String pyJsonDumps(Object? value, {int? indent}) {
  final out = StringBuffer();
  final itemSeparator = indent == null ? ', ' : ',';
  void newline(int level) {
    if (indent != null) out.write('\n${' ' * (indent * level)}');
  }

  void write(Object? v, int level) {
    if (v == null) {
      out.write('null');
    } else if (v is bool) {
      out.write(v ? 'true' : 'false');
    } else if (v is int) {
      out.write(v);
    } else if (v is double) {
      if (v.isNaN) {
        out.write('NaN');
      } else if (v.isInfinite) {
        out.write(v > 0 ? 'Infinity' : '-Infinity');
      } else {
        out.write(pyFloatRepr(v));
      }
    } else if (v is String) {
      out.write('"');
      for (final unit in v.codeUnits) {
        switch (unit) {
          case 0x22:
            out.write(r'\"');
          case 0x5c:
            out.write(r'\\');
          case 0x0a:
            out.write(r'\n');
          case 0x0d:
            out.write(r'\r');
          case 0x09:
            out.write(r'\t');
          case 0x08:
            out.write(r'\b');
          case 0x0c:
            out.write(r'\f');
          default:
            if (unit < 0x20 || unit > 0x7e) {
              out.write(r'\u');
              out.write(unit.toRadixString(16).padLeft(4, '0'));
            } else {
              out.writeCharCode(unit);
            }
        }
      }
      out.write('"');
    } else if (v is List) {
      if (v.isEmpty) {
        out.write('[]');
        return;
      }
      out.write('[');
      for (var i = 0; i < v.length; i++) {
        if (i > 0) out.write(itemSeparator);
        newline(level + 1);
        write(v[i], level + 1);
      }
      newline(level);
      out.write(']');
    } else if (v is Map) {
      if (v.isEmpty) {
        out.write('{}');
        return;
      }
      out.write('{');
      var first = true;
      for (final e in v.entries) {
        if (!first) out.write(itemSeparator);
        first = false;
        newline(level + 1);
        write(e.key.toString(), level + 1);
        out.write(': ');
        write(e.value, level + 1);
      }
      newline(level);
      out.write('}');
    } else {
      throw ArgumentError('Object of type ${v.runtimeType} is not JSON serializable');
    }
  }

  write(value, 0);
  return out.toString();
}
