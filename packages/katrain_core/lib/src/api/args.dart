// The arguments of an API command, read by kind. Each kind has one meaning everywhere: a flag is on only for
// true, 1, "true", "yes" or "on"; a value counts as given when it is not empty.

import 'protocol.dart';

class ApiArgs {
  final Map<String, dynamic> _values;
  ApiArgs([Map<String, dynamic>? values]) : _values = values ?? {};

  /// The raw value.
  Object? operator [](String key) => _values[key];

  bool containsKey(String key) => _values.containsKey(key);

  /// Whether a value was given: present and not null, false, 0, or empty.
  bool has(String key) => isGiven(_values[key]);

  static bool isGiven(Object? v) => switch (v) {
    null || false || 0 => false,
    String s => s.isNotEmpty,
    List l => l.isNotEmpty,
    Map m => m.isNotEmpty,
    _ => true,
  };

  /// A switch; strings count as on for 1, true, yes or on.
  bool flag(String key, {bool orElse = false}) => switch (_values[key]) {
    null => orElse,
    bool b => b,
    num n => n != 0,
    String s => const ['1', 'true', 'yes', 'on'].contains(s.trim().toLowerCase()),
    final v => isGiven(v),
  };

  /// Whether a switch was set at all (on or off).
  bool hasFlag(String key) => _values[key] != null;

  int? integer(String key, {int? orElse, int? min}) {
    final v = _values[key];
    if (v == null || v == '') return orElse;
    final i = switch (v) {
      int i => i,
      double d when d == d.roundToDouble() => d.toInt(),
      String s => int.tryParse(s.trim()),
      _ => null,
    };
    if (i == null) throw ApiError('bad_argument', '$key must be an integer, got $v');
    if (min != null && i < min) throw ApiError('bad_argument', '$key must be at least $min');
    return i;
  }

  double? number(String key, {double? orElse, double? min}) {
    final v = _values[key];
    if (v == null || v == '') return orElse;
    final d = switch (v) {
      num n => n.toDouble(),
      String s => double.tryParse(s.trim()),
      _ => null,
    };
    if (d == null || !d.isFinite) throw ApiError('bad_argument', '$key must be a number, got $v');
    if (min != null && d < min) throw ApiError('bad_argument', '$key must be at least ${_short(min)}');
    return d;
  }

  /// A text value (numbers as written), or [orElse] when none was given.
  String? text(String key, {String? orElse}) {
    final v = _values[key];
    return isGiven(v) ? (v is double ? _short(v) : '$v') : orElse;
  }

  /// A list of words: a JSON list, or text separated by spaces or commas.
  List<String> words(String key) => switch (_values[key]) {
    null => const [],
    List l => [for (final x in l) '$x'],
    final v => splitWords('$v'),
  };

  static String _short(double d) => d == d.roundToDouble() ? '${d.toInt()}' : '$d';
}

/// Splits text at spaces and commas.
List<String> splitWords(String text) => text.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).toList();
