// `katrain-neo`: controls a running KaTrain Neo over its local API and prints JSON.
// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/cli.py.

import 'dart:convert';
import 'dart:io';

import 'package:katrain_cli/katrain_cli.dart';

Future<void> main(List<String> args) async {
  stdout.encoding = utf8;
  stderr.encoding = utf8;
  final code = await runCli(args, CliEnvironment(out: stdout, err: stderr));
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
