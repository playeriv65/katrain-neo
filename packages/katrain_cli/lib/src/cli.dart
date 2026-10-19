// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/cli.py: main, _finish
// and _print_json.

import 'dart:convert';
import 'dart:io';

import '../agent_guide.dart';
import 'argparse.dart';
import 'commands.dart';
import 'launch.dart';
import 'links.dart';
import 'to_api.dart';
import 'transport.dart';

const exitOk = 0, exitApiError = 1, exitUsage = 2, exitNotRunning = 3;

/// First arguments that start the app instead of being a command (`katrain-neo game.sgf`).
const appFileSuffixes = ['.sgf', '.ngf', '.gib', 'config.json'];

/// What the CLI needs from the outside world; replaceable for tests.
class CliEnvironment {
  final StringSink out;
  final StringSink err;
  final ApiClient client;
  final String Function() readStdin;
  final String Function(String) absolute;

  /// Starts the app (launchGui with the real executable by default).
  final Future<Envelope> Function({String? config, String? sgf, bool wait, int timeout})? launch;

  CliEnvironment({
    required this.out,
    required this.err,
    ApiClient? client,
    String Function()? readStdin,
    this.absolute = absolutePath,
    this.launch,
  }) : client = client ?? ApiClient(),
       readStdin = readStdin ?? readAllStdin;
}

/// Python's json.dumps(obj, ensure_ascii=False, indent=2) or, with [compact], separators=(",", ":").
String formatJson(Object? obj, {bool compact = false}) =>
    compact ? jsonEncode(obj) : const JsonEncoder.withIndent('  ').convert(obj);

/// Standard input as text: UTF-8, else the system encoding.
String readAllStdin() {
  final bytes = <int>[];
  for (var b = stdin.readByteSync(); b >= 0; b = stdin.readByteSync()) {
    bytes.add(b);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return systemEncoding.decode(bytes);
  }
}

int _finish(CliEnvironment env, Envelope response, bool compact, [String? textKey]) {
  if (response['ok'] == true) {
    final result = response['result'];
    if (textKey != null && result is Map && result.containsKey(textKey)) {
      final text = result[textKey];
      env.out.writeln(text is String ? text : formatJson(text, compact: compact));
    } else {
      env.out.writeln(formatJson(result, compact: compact));
    }
    return exitOk;
  }
  env.out.writeln(formatJson({'ok': false, 'error': response['error']}, compact: compact));
  return exitApiError;
}

/// Runs the `katrain-neo` command line; returns the exit code.
Future<int> runCli(List<String> argv, CliEnvironment env) async {
  final root = buildCommands();
  Future<Envelope> launch({String? config, String? sgf, bool wait = true, int timeout = 90}) =>
      env.launch?.call(config: config, sgf: sgf, wait: wait, timeout: timeout) ??
      launchGui(env.client, config: config, sgf: sgf, wait: wait, timeout: timeout);

  final first = argv.isEmpty ? null : argv.first;
  final appFile =
      first != null &&
      !root.subcommands.containsKey(first) &&
      appFileSuffixes.any((s) => first.toLowerCase().endsWith(s));
  if (first == null || appFile) {
    // plain `katrain-neo`, `katrain-neo game.sgf`, `katrain-neo my_config.json`: like `gui --no-wait`
    final config = appFile && first.toLowerCase().endsWith('config.json') ? first : null;
    final sgf = appFile && config == null ? first : null;
    return _finish(env, await launch(config: config, sgf: sgf, wait: false), false);
  }

  final Invocation a;
  try {
    a = parseCommandLine(root, argv);
  } on HelpRequested catch (h) {
    env.out.write(h.text);
    return exitOk;
  } on UsageError catch (e) {
    env.err.writeln(e.text);
    return exitUsage;
  }
  if (a.cmd == null) {
    env.out.write(root.helpText('katrain-neo'));
    return exitUsage;
  }
  final client = env.client;
  try {
    switch (a.cmd) {
      case 'gui':
        final response = await launch(
          config: a['config'] as String?,
          sgf: a['sgf'] as String?,
          wait: a['no_wait'] != true,
          timeout: orDefault(a.timeout, 90),
        );
        return _finish(env, response, a.compact);
      case 'guide':
        env.out.writeln(agentGuide);
        return exitOk;
      case 'ping':
        return _finish(env, await client.health(port: a.port, timeout: orDefault(a.timeout, 3)), a.compact);
      case 'commands':
        return _finish(env, await client.call('commands', null, a.port), a.compact);
      case 'call':
        final Object? args;
        try {
          args = jsonDecode(a['json_args'] as String);
        } on FormatException catch (e) {
          env.err.writeln('invalid JSON arguments: ${e.message}');
          return exitUsage;
        }
        if (args is! Map<String, dynamic>) {
          env.err.writeln('JSON arguments must be an object');
          return exitUsage;
        }
        final int t;
        try {
          t = a.timeout != null && a.timeout != 0 ? a.timeout! : _pyIntOrZero(args['timeout']) + 60;
        } on FormatException {
          env.err.writeln('invalid timeout in JSON arguments: ${args['timeout']}');
          return exitUsage;
        }
        return _finish(env, await client.call(a['command'] as String, args, a.port, t), a.compact);
      case 'open':
        Envelope response;
        try {
          final link = linkToCommand(a['url'] as String);
          response = await client.call(link.command, link.args, a.port);
        } on LinkError catch (e) {
          response = _badLink(e.message);
        } on NotRunning catch (e) {
          response = _badLink(e.message);
        }
        return _finish(env, response, a.compact);
    }
    final call = toApi(a, absolute: env.absolute, readStdin: env.readStdin);
    final timeout = call.timeout != null ? call.timeout! + 30 : orDefault(a.timeout, 60);
    final wantsAscii = a.cmd == 'board' || (a.cmd == 'sandbox' && a.sub == 'board');
    final textKey = wantsAscii && a['ascii'] == true ? 'ascii' : null;
    return _finish(env, await client.call(call.command, call.args, a.port, timeout), a.compact, textKey);
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

Envelope _badLink(String message) => {
  'ok': false,
  'error': {'code': 'bad_link', 'message': message},
};

/// `int(args.get("timeout") or 0)`; throws FormatException where Python's int() raises.
int _pyIntOrZero(Object? v) {
  if (v == null || v == false || v == 0 || v == '') return 0;
  if (v == true) return 1;
  if (v is num) return v.truncate();
  if (v is String) return pyInt(v) ?? (throw FormatException('invalid int', v));
  throw FormatException('invalid int', '$v');
}
