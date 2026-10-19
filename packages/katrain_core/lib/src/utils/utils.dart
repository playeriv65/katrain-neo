// Small helpers: grids from KataGo's arrays, evaluation classes, half-precision floats, visit counts.

import 'dart:math' as math;
import 'dart:typed_data';

import 'format.dart';

/// Ownership or policy as a grid such that `grid[y][x]` is for the point (x, y). KataGo lists the top row first.
List<List<T>> varToGrid<T>(List<T> array, (int, int) size) {
  final (sizeX, sizeY) = size;
  final grid = List<List<T>>.filled(sizeY, const []);
  var ix = 0;
  for (var y = sizeY - 1; y >= 0; y--) {
    grid[y] = array.sublist(ix, math.min(ix + sizeX, array.length));
    ix += sizeX;
  }
  return grid;
}

/// Index of the evaluation class for the points lost, given thresholds from large to small.
int evaluationClass(double pointsLost, List<num> evalThresholds) {
  var i = 0;
  while (i < evalThresholds.length - 1 && pointsLost < evalThresholds[i]) {
    i += 1;
  }
  return i;
}

/// IEEE half precision floats, little endian, as analysis is packed into SGF files.
Uint8List packFloats(List<double>? values) {
  if (values == null) return Uint8List(0);
  final data = ByteData(values.length * 2);
  for (var i = 0; i < values.length; i++) {
    data.setUint16(i * 2, _toHalf(values[i]), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Unpacks [num] half precision floats; null for empty data.
List<double>? unpackFloats(List<int> data, int num) {
  if (data.isEmpty) return null;
  if (data.length != num * 2) {
    throw FormatException('unpack requires a buffer of ${num * 2} bytes');
  }
  final bytes = ByteData.sublistView(Uint8List.fromList(data));
  return [for (var i = 0; i < num; i++) _fromHalf(bytes.getUint16(i * 2, Endian.little))];
}

/// Double to half-precision bits, rounding to nearest even.
int _toHalf(double x) {
  if (x.isNaN) return 0x7E00;
  final sign = (x < 0 || (x == 0 && x.isNegative)) ? 0x8000 : 0;
  var a = x.abs();
  if (a.isInfinite) return sign | 0x7C00;
  if (a == 0) return sign;
  // frexp: a = f * 2^e with 0.5 <= f < 1
  var e = 0;
  var f = a;
  while (f >= 1.0) {
    f /= 2;
    e++;
  }
  while (f < 0.5) {
    f *= 2;
    e--;
  }
  if (f < 0.5 || f >= 1.0) throw StateError('frexp failed');
  // normalize f to [1, 2)
  f *= 2.0;
  e--;
  int bits;
  if (e >= 16) {
    throw RangeError('float too large to pack with e format');
  } else if (e < -25) {
    f = 0.0; // |x| < 2^-25: underflow to zero
    e = 0;
  } else if (e < -14) {
    // |x| < 2^-14: subnormal
    f = f * math.pow(2.0, 14 + e);
    e = 0;
  } else {
    e += 15;
    f -= 1.0; // get rid of the leading 1
  }
  f *= 1024.0; // 2**10
  bits = f.toInt(); // cannot overflow
  final remainder = f - bits;
  if (remainder > 0.5 || (remainder == 0.5 && bits.isOdd)) {
    bits++;
    if (bits == 1024) {
      // the carry propagated out of the mantissa
      bits = 0;
      e++;
      if (e == 31) throw RangeError('float too large to pack with e format');
    }
  }
  return sign | (e << 10) | bits;
}

double _fromHalf(int h) {
  final sign = (h & 0x8000) != 0 ? -1.0 : 1.0;
  final e = (h >> 10) & 0x1F;
  final f = h & 0x3FF;
  if (e == 0) return sign * f * math.pow(2.0, -24);
  if (e == 31) return f == 0 ? sign * double.infinity : double.nan;
  return sign * (1 + f / 1024.0) * math.pow(2.0, e - 15);
}

/// Visits, shortened: 950, 1.2k, 120k, 3M.
String formatVisits(num n) {
  if (n < 1000) return '$n';
  if (n < 1e5) return '${formatFixed(n / 1000, 1)}k';
  if (n < 1e6) return '${formatFixed(n / 1000, 0)}k';
  return '${formatFixed(n / 1e6, 0)}M';
}

/// Random items without replacement, each item's second element being its weight
/// (`weighted_selection_without_replacement`: the "log(u) / w" trick, then the n largest keys).
List<T> weightedSelectionWithoutReplacement<T>(
  List<T> items,
  int pickN,
  double Function(T) weight,
  math.Random random,
) {
  final keyed = [for (final item in items) (math.log(random.nextDouble()) / (weight(item) + 1e-18), item)];
  final indexed = [for (var i = 0; i < keyed.length; i++) (keyed[i].$1, i, keyed[i].$2)];
  // heapq.nlargest: largest keys first; equal keys keep their order
  indexed.sort((a, b) {
    final c = b.$1.compareTo(a.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  return [for (final e in indexed.take(pickN)) e.$3];
}
