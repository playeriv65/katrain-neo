/// The part of Python's `str.format` KaTrain's translated templates use: `{name}` and `{name:spec}` with the specs
/// `.Nf`, `+.Nf`, `.N%`, `d` and `s`, plus `{{` and `}}` for literal braces.
library;

import 'py_format.dart';

final RegExp _field = RegExp(r'\{\{|\}\}|\{([A-Za-z_][A-Za-z0-9_]*)(?::([^{}]*))?\}');
final RegExp _fixedSpec = RegExp(r'^(\+)?\.(\d+)([f%])$');

String pyFormat(String template, Map<String, Object?> args) {
  return template.replaceAllMapped(_field, (m) {
    final whole = m[0]!;
    if (whole == '{{') return '{';
    if (whole == '}}') return '}';
    final name = m[1]!;
    if (!args.containsKey(name)) throw ArgumentError('KeyError: $name');
    return _formatValue(args[name], m[2] ?? '');
  });
}

String _formatValue(Object? value, String spec) {
  if (spec.isEmpty || spec == 's') return pyStr(value);
  if (spec == 'd') {
    if (value is! int) throw ArgumentError("Unknown format code 'd' for $value");
    return '$value';
  }
  final m = _fixedSpec.firstMatch(spec);
  if (m == null) throw UnsupportedError('format spec "$spec" is not supported');
  if (value is! num) throw ArgumentError('format spec "$spec" needs a number, got $value');
  final digits = int.parse(m[2]!);
  final plus = m[1] != null;
  return m[3] == '%' ? pyPercent(value.toDouble(), digits, plus: plus) : pyFixed(value.toDouble(), digits, plus: plus);
}
