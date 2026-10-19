// Number formatting for what the app shows, and a stable sort.

/// [x] with [digits] decimals, and a `+` before positive numbers with [plus].
String formatFixed(double x, int digits, {bool plus = false}) {
  final s = x.toStringAsFixed(digits);
  return plus && !s.startsWith('-') ? '+$s' : s;
}

/// [x] as a percentage with [digits] decimals (0.5 is `50.0%`).
String formatPercent(double x, int digits, {bool plus = false}) => '${formatFixed(x * 100, digits, plus: plus)}%';

/// Sorts [list] by [key] keeping the order of equal elements (List.sort does not promise that).
void stableSortBy<T>(List<T> list, Comparable Function(T) key, {bool descending = false}) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, key(list[i]), list[i])];
  indexed.sort((a, b) {
    final c = descending ? b.$2.compareTo(a.$2) : a.$2.compareTo(b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$3;
  }
}
