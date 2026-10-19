/// Fills the placeholders of translated texts: `{name}`, `{name:.1f}` (decimals), `{name:+.1f}` (with sign),
/// `{name:.1%}` (percentage), `{name:d}` (integer) and `{name:s}`; `{{` and `}}` are literal braces.
library;

import 'format.dart';

final RegExp _field = RegExp(r'\{\{|\}\}|\{([A-Za-z_][A-Za-z0-9_]*)(?::([^{}]*))?\}');
final RegExp _fixedSpec = RegExp(r'^(\+)?\.(\d+)([f%])$');

String fillTemplate(String template, Map<String, Object?> args) => template.replaceAllMapped(_field, (m) {
  final whole = m[0]!;
  if (whole == '{{') return '{';
  if (whole == '}}') return '}';
  final name = m[1]!;
  if (!args.containsKey(name)) throw ArgumentError('no value for {$name} in "$template"');
  return _formatValue(args[name], m[2] ?? '');
});

String _formatValue(Object? value, String spec) {
  if (spec.isEmpty || spec == 's') return '${value ?? ''}';
  if (spec == 'd') {
    if (value is! int) throw ArgumentError('{:d} needs an integer, got $value');
    return '$value';
  }
  final m = _fixedSpec.firstMatch(spec);
  if (m == null) throw UnsupportedError('format "$spec" is not supported');
  if (value is! num) throw ArgumentError('format "$spec" needs a number, got $value');
  final digits = int.parse(m[2]!);
  final plus = m[1] != null;
  return m[3] == '%'
      ? formatPercent(value.toDouble(), digits, plus: plus)
      : formatFixed(value.toDouble(), digits, plus: plus);
}
