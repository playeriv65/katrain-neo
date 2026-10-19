/// Helpers that reproduce Python behaviour the ported code relies on: `str()` of values, `int()`, stable sorting,
/// and number formatting/rounding with Python's exact round-half-even rules.
library;

import 'dart:typed_data';

/// The string Python's `str()` gives for property values set from code (ints, floats, strings).
String pyStr(Object? value) {
  if (value == null) return 'None';
  if (value is String) return value;
  if (value is bool) return value ? 'True' : 'False';
  if (value is double) return pyFloatRepr(value);
  return value.toString();
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
BigInt _scaledRounded(double x, int digits) {
  final (numerator, shift) = _exact(x);
  var n = numerator * BigInt.from(10).pow(digits);
  if (shift == 0) return n;
  final d = BigInt.one << shift;
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
