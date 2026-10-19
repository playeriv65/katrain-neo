// Command line parsing with the semantics of Python's argparse (3.13), which the playeriv65/katrain fork's
// katrain/cli.py uses: agents rely on its details, so they are kept:
// - option abbreviations (`--vis 100`), `--opt=value`, `-v100`, `-n=45`;
// - options taking one or more values (`--moves D4 Q16`; the last occurrence wins);
// - positionals and options in any order, consumed chunk by chunk like argparse does
//   (`play D4 --color B Q16` is an error there, and here);
// - negative numbers are values, not options (`pv step -1`); `--` ends the options;
// - --port/--timeout/--compact anywhere on the line (cli.py's _accept_global_options_everywhere).
// package:args provides the option help text; its parser cannot express these rules.

import 'package:args/args.dart';

/// How a value is converted, like argparse's `type=`.
enum ArgType { string, integer, float, onOff }

enum _Kind { flag, value, multi, help }

/// An option (`--name`, `-a`).
class OptSpec {
  final String name;
  final String? abbr;
  final String dest;
  final _Kind _kind;
  final ArgType type;
  final Object? defaultValue;
  final List<String>? choices;
  final String? help;
  final String? metavar;
  final bool hidden;
  final bool global;

  OptSpec._(
    this.name,
    this._kind, {
    this.abbr,
    String? dest,
    this.type = ArgType.string,
    this.defaultValue,
    this.choices,
    this.help,
    this.metavar,
    this.hidden = false,
    this.global = false,
  }) : dest = dest ?? name.replaceAll('-', '_');

  List<String> get optionStrings => [if (_kind == _Kind.help) '-h', '--$name', if (abbr != null) '-$abbr'];

  /// argparse names options by all their option strings: `--node/-n`.
  String get displayName => optionStrings.join('/');
}

/// A positional argument. [nargs] is argparse's: `1` (exactly one), `?`, `*` or `+`.
class PosSpec {
  final String name;
  final String nargs;
  final ArgType type;
  final Object? defaultValue;
  final List<String>? choices;
  final String? help;
  final String? metavar;

  PosSpec(
    this.name, {
    this.nargs = '1',
    this.type = ArgType.string,
    this.defaultValue,
    this.choices,
    this.help,
    this.metavar,
  });

  String get displayName => metavar ?? name;
  bool get required => nargs == '1' || nargs == '+';
}

/// A (sub)command: its options, positionals and subcommands, like one argparse parser.
class CommandSpec {
  final String name;
  final String? help;
  final String? description;
  final List<OptSpec> options = [OptSpec._('help', _Kind.help, help: 'show this help message and exit')];
  final List<PosSpec> positionals = [];
  final Map<String, CommandSpec> subcommands = {};
  String subMetavar = 'ACTION';
  bool subRequired = true;

  CommandSpec(this.name, {this.help, this.description});

  void flag(String name, {String? abbr, String? dest, String? help, bool hidden = false, bool global = false}) =>
      options.add(OptSpec._(name, _Kind.flag, abbr: abbr, dest: dest, help: help, hidden: hidden, global: global));

  void option(
    String name, {
    String? abbr,
    String? dest,
    ArgType type = ArgType.string,
    Object? defaultValue,
    List<String>? choices,
    String? help,
    String? metavar,
    bool hidden = false,
    bool global = false,
  }) => options.add(
    OptSpec._(
      name,
      _Kind.value,
      abbr: abbr,
      dest: dest,
      type: type,
      defaultValue: defaultValue,
      choices: choices,
      help: help,
      metavar: metavar,
      hidden: hidden,
      global: global,
    ),
  );

  /// An option taking one or more values (argparse `nargs="+"`).
  void multi(String name, {String? dest, String? help}) =>
      options.add(OptSpec._(name, _Kind.multi, dest: dest, help: help));

  void arg(
    String name, {
    String nargs = '1',
    ArgType type = ArgType.string,
    Object? defaultValue,
    List<String>? choices,
    String? help,
    String? metavar,
  }) => positionals.add(
    PosSpec(name, nargs: nargs, type: type, defaultValue: defaultValue, choices: choices, help: help, metavar: metavar),
  );

  CommandSpec sub(String name, [String? help]) => subcommands[name] = CommandSpec(name, help: help, description: help);

  /// Help text for this command; [prog] is e.g. `katrain-neo analysis run`.
  String helpText(String prog) {
    final parser = ArgParser(usageLineLength: 100);
    for (final o in options) {
      if (o.hidden) continue;
      final choices = o.choices == null ? '' : ' (choices: ${o.choices!.join(', ')})';
      final defaults = o.defaultValue == null || o._kind == _Kind.flag ? '' : ' (default: ${o.defaultValue})';
      final help = '${o.help ?? ''}$choices$defaults'.trim();
      switch (o._kind) {
        case _Kind.flag || _Kind.help:
          parser.addFlag(o.name, abbr: o._kind == _Kind.help ? 'h' : o.abbr, negatable: false, help: help);
        case _Kind.value:
          parser.addOption(o.name, abbr: o.abbr, help: help, valueHelp: o.metavar ?? _metavar(o));
        case _Kind.multi:
          parser.addMultiOption(o.name, help: help, valueHelp: '${_metavar(o)} ...');
      }
    }
    final out = StringBuffer('${usage(prog)}\n');
    if (description != null) out.write('\n$description\n');
    if (positionals.isNotEmpty) {
      out.write('\npositional arguments:\n');
      for (final p in positionals) {
        final choices = p.choices == null ? '' : ' {${p.choices!.join(',')}}';
        out.write('  ${p.displayName.padRight(20)} ${p.help ?? ''}$choices'.trimRight());
        out.write('\n');
      }
    }
    if (subcommands.isNotEmpty) {
      out.write('\n$subMetavar:\n');
      for (final s in subcommands.values) {
        out.write('  ${s.name.padRight(20)} ${s.help ?? ''}'.trimRight());
        out.write('\n');
      }
    }
    out.write('\noptions:\n${parser.usage}\n');
    return out.toString();
  }

  String usage(String prog) {
    final parts = ['usage: $prog', '[options]'];
    for (final p in positionals) {
      final n = p.displayName;
      parts.add(switch (p.nargs) {
        '?' => '[$n]',
        '*' => '[$n ...]',
        '+' => '$n [$n ...]',
        _ => n,
      });
    }
    if (subcommands.isNotEmpty) parts.add('$subMetavar ...');
    return parts.join(' ');
  }

  static String _metavar(OptSpec o) => o.dest.toUpperCase();
}

/// A parsed command line.
class Invocation {
  /// Subcommand names, e.g. `['analysis', 'run']`; empty when no command was given.
  final List<String> path;

  /// Values by argparse dest (`no_pv`, `from_`, ...), with defaults filled in.
  final Map<String, Object?> values;
  final int? port;
  final int? timeout;
  final bool compact;

  Invocation(this.path, this.values, {this.port, this.timeout, this.compact = false});

  String? get cmd => path.isEmpty ? null : path[0];
  String? get sub => path.length > 1 ? path[1] : null;
  Object? operator [](String dest) => values[dest];
}

/// A command line error (argparse exits with code 2).
class UsageError implements Exception {
  final String prog;
  final String usage;
  final String message;
  UsageError(this.prog, this.usage, this.message);

  /// What argparse prints on stderr.
  String get text => '$usage\n$prog: error: $message';

  @override
  String toString() => text;
}

/// `-h` / `--help` was given: print [text] and exit 0.
class HelpRequested implements Exception {
  final String text;
  HelpRequested(this.text);
}

class _ArgumentError implements Exception {
  final String message;
  _ArgumentError(this.message);
}

class _Match {
  final OptSpec? opt;
  final String optionString;
  final String? explicit;
  _Match(this.opt, this.optionString, this.explicit);
}

final _negativeNumber = RegExp(r'^-\d+$|^-\d*\.\d+$');

/// Parses [argv] against [root] like argparse's `parse_args`.
Invocation parseCommandLine(CommandSpec root, List<String> argv, {String prog = 'katrain-neo'}) {
  final state = _State();
  final extras = _parseLevel(root, argv, prog, state);
  if (extras.isNotEmpty) {
    throw UsageError(prog, root.usage(prog), 'unrecognized arguments: ${extras.join(' ')}');
  }
  return Invocation(
    state.path,
    state.values,
    port: state.globals['port'] as int?,
    timeout: state.globals['timeout'] as int?,
    compact: state.globals['compact'] == true,
  );
}

class _State {
  final path = <String>[];
  final values = <String, Object?>{};
  final globals = <String, Object?>{};
}

/// One argparse parser: parses [tokens] for [spec] and returns the unrecognized ones.
List<String> _parseLevel(CommandSpec spec, List<String> tokens, String prog, _State state) {
  UsageError fail(String message) => UsageError(prog, spec.usage(prog), message);
  try {
    return _LevelParser(spec, tokens, prog, state).run();
  } on _ArgumentError catch (e) {
    throw fail(e.message);
  }
}

class _LevelParser {
  final CommandSpec spec;
  final List<String> tokens;
  final String prog;
  final _State state;
  late final List<MapEntry<String, OptSpec>> _optionStrings = [
    for (final o in spec.options)
      for (final s in o.optionStrings) MapEntry(s, o),
  ];
  final extras = <String>[];

  _LevelParser(this.spec, this.tokens, this.prog, this.state);

  OptSpec? _exact(String s) {
    for (final e in _optionStrings) {
      if (e.key == s) return e.value;
    }
    return null;
  }

  /// argparse's `_parse_optional`: null for a positional value, else the option it names (opt null: unknown).
  _Match? _classify(String arg) {
    if (arg.isEmpty || arg[0] != '-') return null;
    final exact = _exact(arg);
    if (exact != null) return _Match(exact, arg, null);
    if (arg.length == 1) return null;
    final eq = arg.indexOf('=');
    if (eq >= 0) {
      final o = _exact(arg.substring(0, eq));
      if (o != null) return _Match(o, arg.substring(0, eq), arg.substring(eq + 1));
    }
    final tuples = _optionTuples(arg);
    if (tuples.length > 1) {
      throw _ArgumentError('ambiguous option: $arg could match ${tuples.map((t) => t.optionString).join(', ')}');
    }
    if (tuples.length == 1) return tuples.single;
    if (_negativeNumber.hasMatch(arg)) return null;
    if (arg.contains(' ')) return null;
    return _Match(null, arg, null);
  }

  List<_Match> _optionTuples(String arg) {
    final result = <_Match>[];
    final eq = arg.indexOf('=');
    final prefix = eq >= 0 ? arg.substring(0, eq) : arg;
    final explicit = eq >= 0 ? arg.substring(eq + 1) : null;
    if (arg.startsWith('--')) {
      for (final e in _optionStrings) {
        if (e.key.startsWith(prefix)) result.add(_Match(e.value, e.key, explicit));
      }
    } else {
      final shortPrefix = arg.substring(0, 2);
      final shortExplicit = arg.substring(2);
      for (final e in _optionStrings) {
        if (e.key == shortPrefix) {
          result.add(_Match(e.value, e.key, shortExplicit));
        } else if (e.key.startsWith(prefix)) {
          result.add(_Match(e.value, e.key, explicit));
        }
      }
    }
    return result;
  }

  List<String> run() {
    // defaults, as argparse sets them before parsing
    for (final o in spec.options) {
      if (o.global || o._kind == _Kind.help) continue;
      state.values[o.dest] = o._kind == _Kind.flag ? false : o.defaultValue;
    }
    for (final p in spec.positionals) {
      state.values[p.name] = p.defaultValue;
    }

    // classify every token: 'O' option, 'A' value, '-' for the first '--' (everything after it is a value)
    final pattern = StringBuffer();
    final options = <int, _Match>{};
    var rest = false;
    for (var i = 0; i < tokens.length; i++) {
      if (rest) {
        pattern.write('A');
      } else if (tokens[i] == '--') {
        pattern.write('-');
        rest = true;
      } else {
        final m = _classify(tokens[i]);
        if (m == null) {
          pattern.write('A');
        } else {
          options[i] = m;
          pattern.write('O');
        }
      }
    }
    final patterns = pattern.toString();
    final positionals = [
      ...spec.positionals.map(_Positional.new),
      if (spec.subcommands.isNotEmpty) _Positional.parser(spec),
    ];

    int consumeOptional(int start) {
      final m = options[start]!;
      final opt = m.opt;
      if (opt == null) {
        extras.add(tokens[start]);
        return start + 1;
      }
      if (m.explicit != null) {
        if (opt._kind == _Kind.flag || opt._kind == _Kind.help) {
          throw _ArgumentError('argument ${opt.displayName}: ignored explicit argument ${pyRepr(m.explicit!)}');
        }
        _takeOption(opt, [m.explicit!]);
        return start + 1;
      }
      final next = patterns.substring(start + 1);
      final count = switch (opt._kind) {
        _Kind.flag || _Kind.help => 0,
        _Kind.value => next.startsWith('A') ? 1 : -1,
        _Kind.multi => RegExp('^A*').matchAsPrefix(next)!.end,
      };
      if (count < 0 || (opt._kind == _Kind.multi && count == 0)) {
        throw _ArgumentError(
          'argument ${opt.displayName}: expected ${opt._kind == _Kind.multi ? 'at least one argument' : 'one argument'}',
        );
      }
      _takeOption(opt, tokens.sublist(start + 1, start + 1 + count));
      return start + 1 + count;
    }

    int consumePositionals(int start) {
      final counts = _matchPartial(positionals, patterns.substring(start));
      for (var i = 0; i < counts.length; i++) {
        final p = positionals[i];
        var args = tokens.sublist(start, start + counts[i]);
        if (p.isParser) {
          if (patterns[start] == '-') args = args.sublist(1);
        } else if (patterns.substring(start, start + counts[i]).contains('-')) {
          args = [...args]..remove('--');
        }
        start += counts[i];
        _takePositional(p, args);
      }
      positionals.removeRange(0, counts.length);
      return start;
    }

    final optionIndices = options.keys.toList()..sort();
    final maxOption = optionIndices.isEmpty ? -1 : optionIndices.last;
    var start = 0;
    while (start <= maxOption) {
      var nextOption = start;
      while (nextOption <= maxOption && !options.containsKey(nextOption)) {
        nextOption++;
      }
      if (start != nextOption) {
        final end = consumePositionals(start);
        if (end > start) {
          start = end;
          continue;
        }
        start = end;
      }
      if (!options.containsKey(start)) {
        extras.addAll(tokens.sublist(start, nextOption));
        start = nextOption;
      }
      start = consumeOptional(start);
    }
    final stop = consumePositionals(start);
    extras.addAll(tokens.sublist(stop));

    final missing = [
      for (final p in positionals)
        if (p.required) p.displayName,
    ];
    if (missing.isNotEmpty) throw _ArgumentError('the following arguments are required: ${missing.join(', ')}');
    return extras;
  }

  void _takeOption(OptSpec opt, List<String> args) {
    final label = 'argument ${opt.displayName}';
    final target = opt.global ? state.globals : state.values;
    switch (opt._kind) {
      case _Kind.help:
        throw HelpRequested(spec.helpText(prog));
      case _Kind.flag:
        target[opt.dest] = true;
      case _Kind.value:
        target[opt.dest] = _check(label, _convert(label, opt.type, args.single), opt.choices);
      case _Kind.multi:
        target[opt.dest] = [for (final a in args) _check(label, _convert(label, opt.type, a), opt.choices)];
    }
  }

  void _takePositional(_Positional p, List<String> args) {
    if (p.isParser) {
      final name = args.first;
      final sub = spec.subcommands[name];
      if (sub == null) {
        throw _ArgumentError(
          'argument ${spec.subMetavar}: invalid choice: ${pyRepr(name)} (choose from ${spec.subcommands.keys.join(', ')})',
        );
      }
      state.path.add(name);
      extras.addAll(_parseLevel(sub, args.sublist(1), '$prog $name', state));
      return;
    }
    final spec_ = p.spec!;
    final label = 'argument ${spec_.displayName}';
    Object? value;
    switch (spec_.nargs) {
      case '?':
        value = args.isEmpty ? spec_.defaultValue : _convert(label, spec_.type, args.single);
        if (args.isNotEmpty || value is String) value = _check(label, value, spec_.choices);
      case '*' || '+':
        value = args.isEmpty && spec_.nargs == '*'
            ? (spec_.defaultValue ?? <Object?>[])
            : [for (final a in args) _check(label, _convert(label, spec_.type, a), spec_.choices)];
      default:
        value = _check(label, _convert(label, spec_.type, args.single), spec_.choices);
    }
    state.values[spec_.name] = value;
  }

  static Object? _check(String label, Object? value, List<String>? choices) {
    if (choices != null && !choices.contains(value)) {
      throw _ArgumentError(
        '$label: invalid choice: ${pyRepr('$value')} '
        '(choose from ${choices.join(', ')})',
      );
    }
    return value;
  }

  static Object? _convert(String label, ArgType type, String value) {
    switch (type) {
      case ArgType.string:
        return value;
      case ArgType.integer:
        return pyInt(value) ?? (throw _ArgumentError('$label: invalid int value: ${pyRepr(value)}'));
      case ArgType.float:
        return pyFloat(value) ?? (throw _ArgumentError('$label: invalid float value: ${pyRepr(value)}'));
      case ArgType.onOff:
        return onOff(value) ?? (throw _ArgumentError('$label: use on/off'));
    }
  }
}

class _Positional {
  final PosSpec? spec;
  final bool isParser;
  final bool _parserRequired;
  final String? _parserMetavar;

  _Positional(PosSpec this.spec) : isParser = false, _parserRequired = false, _parserMetavar = null;
  _Positional.parser(CommandSpec command)
    : spec = null,
      isParser = true,
      _parserRequired = command.subRequired,
      _parserMetavar = command.subMetavar;

  bool get required => isParser ? _parserRequired : spec!.required;
  String get displayName => isParser ? _parserMetavar! : spec!.displayName;

  /// argparse's `_get_nargs_pattern` for positionals.
  String get pattern {
    if (isParser) return '(-*A[-AO]*)';
    return switch (spec!.nargs) {
      '?' => '(-*A?-*)',
      '*' => '(-*[A-]*)',
      '+' => '(-*A[A-]*)',
      _ => '(-*A-*)',
    };
  }
}

/// argparse's `_match_arguments_partial` (3.13): match as many positionals as possible; trailing empty matches
/// directly before an option are left for later.
List<int> _matchPartial(List<_Positional> positionals, String pattern) {
  for (var i = positionals.length; i > 0; i--) {
    final re = RegExp('^${positionals.take(i).map((p) => p.pattern).join()}');
    final m = re.firstMatch(pattern);
    if (m != null) {
      final result = [for (var g = 1; g <= m.groupCount; g++) m.group(g)!.length];
      if (m.end < pattern.length && pattern[m.end] == 'O') {
        while (result.isNotEmpty && result.last == 0) {
          result.removeLast();
        }
      }
      return result;
    }
  }
  return [];
}

final _pyInt = RegExp(r'^\s*[+-]?\d+(_\d+)*\s*$');
final _pyFloat = RegExp(r'^\s*[+-]?(\d+(_\d+)*(\.(\d+(_\d+)*)?)?|\.\d+(_\d+)*)([eE][+-]?\d+(_\d+)*)?\s*$');

/// Python's `int(str)` for decimal ASCII digits; null when Python would raise.
int? pyInt(String s) => _pyInt.hasMatch(s) ? int.parse(s.trim().replaceAll('_', '')) : null;

/// Python's `float(str)` for finite decimal numbers; null otherwise (unlike Python, inf and nan are rejected:
/// they cannot be sent as JSON).
double? pyFloat(String s) => _pyFloat.hasMatch(s) ? double.parse(s.trim().replaceAll('_', '')) : null;

/// cli.py's `_on_off`.
bool? onOff(String v) {
  final s = v.toLowerCase();
  if (const ['on', 'true', '1', 'yes'].contains(s)) return true;
  if (const ['off', 'false', '0', 'no'].contains(s)) return false;
  return null;
}

/// Python's `repr(str)` for the strings that appear in error messages.
String pyRepr(String s) {
  final quote = s.contains("'") && !s.contains('"') ? '"' : "'";
  final escaped = s.replaceAll(r'\', r'\\').replaceAll('\n', r'\n').replaceAll('\r', r'\r').replaceAll('\t', r'\t');
  return quote + (quote == "'" ? escaped.replaceAll("'", r"\'") : escaped) + quote;
}
