// Entry of the `katrain-neo` command line: starts the app for no arguments or a game file, otherwise runs the
// command tree and maps usage errors to exit code 2.

import 'package:args/command_runner.dart';

import 'command_base.dart';
import 'commands.dart';
import 'environment.dart';

/// First arguments that start the app instead of being a command (`katrain-neo game.sgf`).
const appFileSuffixes = ['.sgf', '.ngf', '.gib', 'config.json'];

/// Runs the `katrain-neo` command line; returns the exit code.
Future<int> runCli(List<String> argv, CliEnvironment env) async {
  final runner = CliRunner(env, buildCommands());
  final first = argv.firstOrNull;
  final firstLower = first?.toLowerCase();
  if (first == null || (!runner.commands.containsKey(first) && appFileSuffixes.any((s) => firstLower!.endsWith(s)))) {
    // `katrain-neo`, `katrain-neo game.sgf`, `katrain-neo my_config.json`: like `gui --no-wait`
    final config = firstLower?.endsWith('config.json') == true ? first : null;
    final sgf = config == null ? first : null;
    return env.report(await env.launch(config: config, sgf: sgf, wait: false));
  }
  try {
    return await runner.run(argv) ?? exitOk;
  } on UsageException catch (e) {
    env.err.writeln(e);
    return exitUsage;
  }
}
