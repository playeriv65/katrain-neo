// Starts the KaTrain Neo app (`gui`, or `katrain-neo` without a command): reuses a running app, otherwise starts
// the executable detached and waits until the discovery file of the new process appears and its API answers.
// The app's output is not captured, so an early exit is only noticed as a timeout.

import 'dart:io';

// katrain_core has no public library for the protocol alone; package:katrain_core/api.dart pulls in the server.
import 'package:katrain_core/api.dart';
import 'package:path/path.dart' as p;

import 'transport.dart';

/// Environment variable naming the KaTrain Neo app executable.
const appVariable = 'KATRAIN_NEO_APP';

/// Executable names looked for next to the CLI.
const appNames = ['katrain_neo.exe', 'katrain_neo'];

/// The KaTrain Neo executable: `$KATRAIN_NEO_APP`, else `katrain_neo(.exe)` next to this executable.
String? findApp({Map<String, String>? environment, String? executable}) {
  final configured = (environment ?? Platform.environment)[appVariable];
  if (configured != null && configured.isNotEmpty) return configured;
  final dir = p.dirname(executable ?? Platform.resolvedExecutable);
  for (final name in appNames) {
    final candidate = p.join(dir, name);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// `~` expanded like katrain_core's data folder (HOME, else USERPROFILE).
String expandUser(String path) {
  if (path != '~' && !path.startsWith('~/') && !path.startsWith(r'~\')) return path;
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  return home + path.substring(1);
}

/// [path] made absolute and normalized.
String absolutePath(String path) => p.normalize(p.absolute(path));

double _now() => DateTime.now().millisecondsSinceEpoch / 1000;

/// The discovery file's start time in seconds (accepts milliseconds too).
double? _started(Map<String, dynamic> info) {
  final started = info['started'];
  if (started is! num) return null;
  return started > 1e11 ? started / 1000 : started.toDouble();
}

/// Starts KaTrain Neo in the background and (with [wait]) waits until its API answers.
Future<Envelope> launchGui(
  ApiClient client, {
  String? config,
  String? sgf,
  bool wait = true,
  int timeout = 90,
  String? app,
  Map<String, dynamic>? Function()? discovery,
}) async {
  final readInfo = discovery ?? (() => readDiscovery());
  try {
    if ((await client.health())['ok'] == true) {
      return {
        'ok': true,
        'result': {'already_running': true, ...?readInfo()},
      };
    }
  } on NotRunning {
    // not running: start it
  }
  final exe = app ?? findApp();
  if (exe == null) {
    return {
      'ok': false,
      'error': {
        'code': 'app_not_found',
        'message': 'KaTrain Neo app not found',
        'hint': 'set $appVariable to the KaTrain Neo executable, or put katrain-neo next to ${appNames.join(' / ')}',
      },
    };
  }
  final args = [if (config != null) absolutePath(expandUser(config)), if (sgf != null) absolutePath(expandUser(sgf))];
  final launched = _now();
  final Process process;
  try {
    process = await Process.start(exe, args, mode: ProcessStartMode.detached);
  } on ProcessException catch (e) {
    return {
      'ok': false,
      'error': {'code': 'gui_not_started', 'message': 'could not start $exe: ${e.message}'},
    };
  }
  if (!wait) {
    return {
      'ok': true,
      'result': {'started': true, 'pid': process.pid},
    };
  }
  final deadline = launched + timeout;
  while (_now() < deadline) {
    final info = readInfo();
    final started = info == null ? null : _started(info);
    // the discovery file must come from this launch, not an earlier run (matched on start time, not pid)
    if (info != null && started != null && started >= launched - 1) {
      try {
        if ((await client.health())['ok'] == true) {
          return {
            'ok': true,
            'result': {'started': true, 'pid': process.pid, 'port': info['port']},
          };
        }
      } on NotRunning {
        // not listening yet
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return {
    'ok': false,
    'error': {'code': 'timeout', 'message': 'KaTrain Neo API not ready after ${timeout}s'},
  };
}
