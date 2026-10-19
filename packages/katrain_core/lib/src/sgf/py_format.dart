/// Small helpers that reproduce Python behaviour the ported code relies on.
library;

/// The string Python's `str()` gives for property values set from code (ints, floats, strings).
String pyStr(Object? value) {
  if (value == null) return 'None';
  if (value is String) return value;
  if (value is bool) return value ? 'True' : 'False';
  if (value is double) {
    if (value.isFinite && value == value.truncateToDouble() && value.abs() < 1e16) {
      return '${value.toInt()}.0';
    }
    return value.toString();
  }
  return value.toString();
}

/// Python's `int(str)`: surrounding whitespace allowed, otherwise strict.
int pyInt(String value) {
  final parsed = int.tryParse(value.trim());
  if (parsed == null) throw FormatException('invalid literal for int(): $value');
  return parsed;
}

/// Stable sort by a key, like Python's `list.sort(key=...)` (Dart's List.sort is not guaranteed stable).
void mergeSortBy<T>(List<T> list, num Function(T) key) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, key(list[i]), list[i])];
  indexed.sort((a, b) {
    final c = a.$2.compareTo(b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$3;
  }
}
