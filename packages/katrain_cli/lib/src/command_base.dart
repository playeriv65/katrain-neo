// Building blocks of the `katrain-neo` command tree on package:args: the runner with the global options, command
// groups, leaf commands with positional parameters, typed access to a parsed command line, and commands that send
// one API call.

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'environment.dart';
import 'transport.dart';

/// The `katrain-neo` command runner. --port, --timeout and --compact are defined here; package:args looks up
/// options a command does not know in its parents, so they work anywhere on the line.
class CliRunner extends CommandRunner<int> {
  final CliEnvironment env;

  CliRunner(this.env, Iterable<Command<int>> commands)
    : super(
        'katrain-neo',
        'Control a running KaTrain Neo. Read commands print JSON.\n\n'
            'Run without arguments, or with an .sgf/.ngf/.gib file or a config.json, to start the app.\n'
            'Exit codes: 0 ok, 1 command error, 2 usage error, 3 app not running.',
      ) {
    argParser
      ..addOption('port', valueHelp: 'N', help: 'API port (default: from ~/.katrain-neo/api.json)')
      ..addOption('timeout', valueHelp: 'SECONDS', help: 'seconds to wait for the app / engine')
      ..addFlag('compact', negatable: false, help: 'single-line JSON output');
    commands.forEach(addCommand);
  }

  @override
  String get usageFooter => 'Global options may also follow the command, e.g. "katrain-neo status --compact".';

  @override
  void printUsage() => env.out.writeln(usage);

  @override
  Future<int?> runCommand(ArgResults topLevelResults) {
    if (topLevelResults.command == null && topLevelResults.rest.isEmpty && !topLevelResults.flag('help')) {
      usageException('Missing command.');
    }
    return super.runCommand(topLevelResults);
  }
}

mixin _PrintsUsage on Command<int> {
  CliEnvironment get env => (runner! as CliRunner).env;

  @override
  void printUsage() => env.out.writeln(usage);
}

/// A command that only groups subcommands (`analysis`, `sgf`, ...).
class CommandGroup extends Command<int> with _PrintsUsage {
  @override
  final String name;
  @override
  final String description;

  CommandGroup(this.name, this.description, Iterable<Command<int>> subcommands) {
    subcommands.forEach(addSubcommand);
  }
}

/// A positional parameter of a [CliCommand].
class Param {
  final String name;
  final String? help;

  /// May be left out; then it reads as [defaultsTo].
  final bool optional;

  /// Takes all remaining arguments (only the last parameter).
  final bool repeated;
  final String? defaultsTo;
  final List<String>? allowed;

  const Param(this.name, {this.help, this.allowed}) : optional = false, repeated = false, defaultsTo = null;
  const Param.optional(this.name, {this.help, this.defaultsTo}) : optional = true, repeated = false, allowed = null;
  const Param.repeated(this.name, {this.help, this.optional = false})
    : repeated = true,
      defaultsTo = null,
      allowed = null;

  String get usage {
    final word = repeated ? '<$name>...' : '<$name>';
    return optional ? '[$word]' : word;
  }

  String? get _helpLine {
    final parts = [
      ?help,
      if (allowed != null) '(${allowed!.join(' | ')})',
      if (defaultsTo != null) '(default: $defaultsTo)',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }
}

/// A leaf command: options (on [argParser]), positional [params] and what it does ([action]).
class CliCommand extends Command<int> with _PrintsUsage {
  @override
  final String name;
  @override
  final String description;
  final List<Param> params;
  final Future<int> Function(Args a) action;

  CliCommand(
    this.name,
    this.description, {
    this.params = const [],
    void Function(ArgParser p)? options,
    required this.action,
  }) {
    options?.call(argParser);
  }

  @override
  bool get takesArguments => params.isNotEmpty;

  @override
  String get invocation {
    final names = [name];
    for (var c = parent; c != null; c = c.parent) {
      names.add(c.name);
    }
    names.add(runner!.executableName);
    return [...names.reversed, ...params.map((p) => p.usage), '[options]'].join(' ');
  }

  @override
  String? get usageFooter {
    final described = [
      for (final p in params)
        if (p._helpLine case final help?) (p.usage, help),
    ];
    if (described.isEmpty) return null;
    final width = described.map((d) => d.$1.length).reduce((a, b) => a > b ? a : b);
    return '\nArguments:\n${described.map((d) => '${d.$1.padRight(width)}    ${d.$2}').join('\n')}';
  }

  @override
  Future<int> run() async {
    final a = Args._(this);
    try {
      return await action(a);
    } on NotRunning catch (e) {
      env.out.writeln(
        formatJson({
          'ok': false,
          'error': {'code': 'gui_not_running', 'message': e.message},
        }, compact: a.compact),
      );
      return exitNotRunning;
    }
  }
}

/// A command that sends the API call [toCall] makes from the command line. With [ascii], `--ascii` prints only
/// the result's text diagram.
CliCommand apiCommand(
  String name,
  String description,
  ApiCall Function(Args a) toCall, {
  List<Param> params = const [],
  void Function(ArgParser p)? options,
  bool ascii = false,
}) => CliCommand(
  name,
  description,
  params: params,
  options: (p) {
    options?.call(p);
    if (ascii) p.addFlag('ascii', negatable: false, help: 'print only the text diagram');
  },
  action: (a) async {
    final call = toCall(a);
    final timeout = call.timeout != null ? call.timeout! + 30 : a.timeout ?? 60;
    final response = await a.env.client.call(call.command, call.args, a.port, timeout);
    return a.env.report(response, compact: a.compact, textKey: ascii && a.flag('ascii') ? 'ascii' : null);
  },
);

/// The parsed command line of one [CliCommand]: its positionals, options and the global options. Values that do
/// not convert raise a usage error.
class Args {
  final CliCommand _command;
  final ArgResults _results;
  final _positionals = <String, Object?>{};
  late final int? port = _global('port', max: 65535);
  late final int? timeout = _global('timeout');
  late final bool compact = _command.globalResults!.flag('compact');

  Args._(this._command) : _results = _command.argResults! {
    final rest = _results.rest;
    var next = 0;
    for (final p in _command.params) {
      if (p.repeated) {
        if (next == rest.length && !p.optional) fail('Missing argument <${p.name}>.');
        _positionals[p.name] = rest.sublist(next);
        next = rest.length;
      } else if (next < rest.length) {
        final value = rest[next++];
        if (p.allowed != null && !p.allowed!.contains(value)) {
          fail('"$value" is not an allowed value for ${p.usage} (${p.allowed!.join(', ')}).');
        }
        _positionals[p.name] = value;
      } else if (p.optional) {
        _positionals[p.name] = p.defaultsTo;
      } else {
        fail('Missing argument <${p.name}>.');
      }
    }
    if (next < rest.length) fail('Unexpected argument "${rest[next]}".');
  }

  CliEnvironment get env => _command.env;

  /// Raises a usage error for this command.
  Never fail(String message) => _command.usageException(message);

  bool _isParam(String name) => _positionals.containsKey(name);
  String _label(String name) => _isParam(name) ? '<$name>' : '--$name';

  /// The value of a single positional or option.
  String? string(String name) => _isParam(name) ? _positionals[name] as String? : _results.option(name);

  /// The values of a repeated positional or a multi-option (comma separated and/or repeated); null when empty.
  List<String>? list(String name) {
    final values = _isParam(name) ? _positionals[name] as List<String> : _results.multiOption(name);
    return values.isEmpty ? null : values;
  }

  bool flag(String name) => _results.flag(name);

  int? integer(String name) {
    final s = string(name);
    if (s == null) return null;
    return int.tryParse(s) ?? fail('Invalid value for ${_label(name)}: "$s" is not an integer.');
  }

  double? number(String name) {
    final s = string(name);
    if (s == null) return null;
    final v = double.tryParse(s);
    return v != null && v.isFinite ? v : fail('Invalid value for ${_label(name)}: "$s" is not a number.');
  }

  /// `on`/`off` (also `true`/`false`, `yes`/`no`, `1`/`0`).
  bool? onOff(String name) {
    final s = string(name);
    if (s == null) return null;
    return switch (s.toLowerCase()) {
      'on' || 'true' || 'yes' || '1' => true,
      'off' || 'false' || 'no' || '0' => false,
      _ => fail('Invalid value for ${_label(name)}: "$s" is not on or off.'),
    };
  }

  int? _global(String name, {int? max}) {
    final s = _command.globalResults!.option(name);
    if (s == null) return null;
    final v = int.tryParse(s);
    if (v == null || v < 1 || (max != null && v > max)) {
      fail('Invalid value for --$name: "$s" is not a whole number from 1${max == null ? '' : ' to $max'}.');
    }
    return v;
  }
}
