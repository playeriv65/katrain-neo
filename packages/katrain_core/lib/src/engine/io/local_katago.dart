// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/engine.py: starting the KataGo
// process (KataGoEngine.__init__, start, restart, shutdown, check_alive) and BaseEngine.get_engine_path.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../constants.dart';
import '../../i18n/i18n.dart';
import '../../utils/py_str_format.dart';
import '../katago_engine.dart';

/// Expands a leading `~` like Python's `os.path.expanduser`.
String expandUser(String path) {
  if (path != '~' && !path.startsWith('~/') && !path.startsWith(r'~\')) return path;
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  return home + path.substring(1);
}

/// Resolves KaTrain-style resource paths: `katrain/...` is relative to [resourceDir] (KaTrain's package folder),
/// anything else is a user path (`~` expanded, made absolute).
String findResource(String path, String resourceDir) {
  if (path.startsWith('katrain')) {
    final rest = path.replaceAll(r'katrain\', 'katrain/').replaceFirst('katrain/', '');
    return File('$resourceDir/$rest').absolute.path;
  }
  return File(expandUser(path)).absolute.path;
}

/// A KataGo analysis engine running as a local process.
class LocalKataGo implements EngineConnection {
  final KataGoEngine engine;
  final String resourceDir;
  final String dataFolder;
  late final List<String> command;
  bool shell = false;
  Process? _process;
  bool _exited = true;
  bool _stopping = false;
  final List<StreamSubscription> _subscriptions = [];

  LocalKataGo(this.engine, {required this.resourceDir, this.dataFolder = '~/.katrain'});

  Map<String, dynamic> get config => engine.config;

  /// Builds the command line, then starts KataGo. False when it could not be started (the error is reported).
  Future<bool> start() async {
    if (resolveEngineBackend(config) == 'custom') {
      command = [config['altcommand'] as String];
      shell = true;
    } else {
      final model = findResource(config['model'] as String, resourceDir);
      final cfg = findResource(config['config'] as String, resourceDir);
      final exe = engineExecutable(((config['katago'] as String?) ?? '').trim());
      if (exe == null) return false;
      command = [exe, 'analysis', '-model', model];
      final humanlikeModel = (config['humanlike_model'] as String?) ?? '';
      if (humanlikeModel.isNotEmpty) {
        final humanPath = findResource(humanlikeModel, resourceDir);
        if (File(humanPath).existsSync()) {
          command.addAll(['-human-model', humanPath]);
        } else {
          engine.host.log('Human model not found at $humanPath', outputError);
        }
      }
      command.addAll(['-config', cfg, '-override-config', 'homeDataDir=${expandUser(dataFolder)}']);
    }
    return _startProcess();
  }

  /// `get_engine_path`: the KataGo executable to run, or null (with an error reported) when there is none.
  String? engineExecutable(String exe) {
    var path = exe;
    if (path.isEmpty) {
      if (Platform.isWindows) {
        path = 'katrain/KataGo/katago.exe';
      } else if (Platform.isLinux) {
        path = 'katrain/KataGo/katago';
      } else {
        path = findResource('katrain/KataGo/katago-osx', resourceDir); // github actions built
        if (!File(path).existsSync()) path = 'katago'; // e.g. MacOS after brewing
      }
    }
    if (path.startsWith('katrain')) path = findResource(path, resourceDir);
    final hasDir = path.contains('/') || path.contains(r'\');
    if (hasDir && !File(path).existsSync()) {
      engine.onError(pyFormat(i18n.tr('Kata exe not found'), {'exe': path}), 'KATAGO-EXE');
      return null;
    } else if (!hasDir) {
      final separator = Platform.isWindows ? ';' : ':';
      final paths = [...(Platform.environment['PATH'] ?? '.').split(separator), '/opt/homebrew/bin/'];
      final found = [
        for (final dir in paths)
          if (File('$dir${Platform.pathSeparator}$path').existsSync()) '$dir${Platform.pathSeparator}$path',
      ];
      if (found.isEmpty) {
        engine.onError(pyFormat(i18n.tr('Kata exe not found in path'), {'exe': path}), 'KATAGO-EXE');
        return null;
      }
      path = found.first;
    }
    return path;
  }

  Future<bool> _startProcess() async {
    engine.drainPending();
    engine.host.log('Starting KataGo with $command', outputDebug);
    try {
      _process = shell
          ? await Process.start(command.first, const [], runInShell: true)
          : await Process.start(command.first, command.sublist(1));
    } on ProcessException catch (e) {
      engine.onError(pyFormat(i18n.tr('Starting Kata failed'), {'command': command, 'error': e}), 'c');
      return false;
    }
    _exited = false;
    _stopping = false;
    engine.resetReaders();
    engine.connection = this;
    final process = _process!;
    _subscriptions.add(
      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(engine.handleLine),
    );
    _subscriptions.add(
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(engine.handleStderrLine),
    );
    unawaited(
      process.exitCode.then((code) {
        _exited = true;
        if (!_stopping) engine.onProcessExit(code, maybeOpenRecovery: true);
      }),
    );
    return true;
  }

  @override
  bool get alive => _process != null && !_exited;

  @override
  void send(String line) {
    try {
      _process?.stdin.writeln(line);
    } on Object catch (e) {
      engine.host.log('Exception in writing to katago: $e', outputDebug);
    }
  }

  /// Waits until every query has its result, while the process lives.
  Future<void> waitToFinish() async {
    while (alive && !engine.isIdle()) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Stops KataGo; with [finish], first lets the outstanding queries complete.
  Future<void> shutdown({bool finish = false}) async {
    if (finish) await waitToFinish();
    final process = _process;
    if (process != null) {
      _stopping = true;
      engine.host.log('Terminating KataGo process', outputDebug);
      process.kill();
      engine.host.log('Terminated KataGo process', outputDebug);
      await process.exitCode;
    }
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    _process = null;
  }

  @override
  Future<void> close() => shutdown();

  /// `restart`: drop everything outstanding and start a fresh process.
  Future<bool> restart() async {
    engine.queryGeneration += 1;
    engine.drainPending();
    engine.clearQueries();
    await shutdown();
    return _startProcess();
  }
}
