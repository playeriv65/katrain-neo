// Runs the app in debug mode and hot reloads it whenever a Dart file of the app or the core changes, so it can be
// played while its code is being edited: the game, the clock and the window stay as they are.
//
//   cd app && dart tool/dev_run.dart [-d windows|macos|linux] [extra flutter run arguments]
//
// Keys (then Enter): r hot reload, R hot restart (loses the game in memory), q quit. A change that hot reload cannot
// take (e.g. to main(), a global or a new dependency) is reported, and waits for R.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The folders whose Dart files trigger a reload, relative to the app folder.
const watched = ['lib', '../packages/katrain_core/lib'];

/// Changes closer together than this are reloaded at once.
const debounce = Duration(milliseconds: 400);

void say(String message) => stdout.writeln('[dev_run] $message');

Future<void> main(List<String> args) async {
  final appDir = File(Platform.script.toFilePath()).parent.parent;
  final device = args.contains('-d') ? <String>[] : ['-d', _defaultDevice()];
  final flutter = Platform.environment['FLUTTER'] ?? 'flutter';
  final process = await Process.start(
    flutter,
    ['run', ...device, '--machine', ...args],
    workingDirectory: appDir.path,
    runInShell: Platform.isWindows, // flutter is a batch file there
  );
  final runner = _Runner(process);
  process.stderr.transform(utf8.decoder).listen(stderr.write);
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(runner.onLine);

  Timer? pending;
  for (final folder in watched) {
    final dir = Directory('${appDir.path}${Platform.pathSeparator}$folder');
    if (!dir.existsSync()) continue;
    dir.watch(recursive: true).where((e) => e.path.endsWith('.dart')).listen((e) {
      pending?.cancel();
      pending = Timer(debounce, () => runner.restart(full: false, reason: 'changed ${_short(e.path, appDir)}'));
    });
  }

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    switch (line.trim()) {
      case 'r':
        runner.restart(full: false, reason: 'asked');
      case 'R':
        runner.restart(full: true, reason: 'asked');
      case 'q':
        runner.stop();
    }
  });

  say('starting the app; it hot reloads when a file in ${watched.join(', ')} changes');
  final code = await process.exitCode;
  say('the app ended ($code)');
  exit(code);
}

String _defaultDevice() => Platform.isMacOS ? 'macos' : (Platform.isLinux ? 'linux' : 'windows');

String _short(String path, Directory appDir) =>
    path.startsWith(appDir.path) ? path.substring(appDir.path.length + 1) : path;

/// Talks to `flutter run --machine`: JSON lines in both directions.
class _Runner {
  final Process process;
  _Runner(this.process);

  String? _appId;

  /// Set once the app runs: reloads asked for while it is still building wait for it.
  bool _started = false;
  int _nextId = 1;
  bool _busy = false;
  ({bool full, String reason})? _queued;
  final _replies = <int, Completer<Map<String, dynamic>>>{};

  void onLine(String line) {
    if (!line.startsWith('[{')) {
      if (line.trim().isNotEmpty) stdout.writeln(line);
      return;
    }
    final List<dynamic> messages;
    try {
      messages = jsonDecode(line) as List<dynamic>;
    } on FormatException {
      stdout.writeln(line);
      return;
    }
    for (final m in messages.cast<Map<String, dynamic>>()) {
      final id = m['id'];
      if (id is int && _replies.containsKey(id)) {
        _replies.remove(id)!.complete(m);
        continue;
      }
      final params = (m['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      switch (m['event']) {
        case 'app.start':
          _appId = params['appId'] as String?;
        case 'app.started':
          _started = true;
          say('the app is running');
          _runQueued();
        case 'app.log':
          stdout.write('${params['log']}${(params['log'] as String).endsWith('\n') ? '' : '\n'}');
        case 'app.progress':
          final message = params['message'];
          if (message is String && message.isNotEmpty) say(message);
        case 'daemon.logMessage':
          say('${params['level']}: ${params['message']}');
        case 'app.stop':
          say('the app stopped');
      }
    }
  }

  Future<Map<String, dynamic>> _call(String method, Map<String, dynamic> params) {
    final id = _nextId++;
    final reply = _replies[id] = Completer();
    process.stdin.writeln(
      jsonEncode([
        {'id': id, 'method': method, 'params': params},
      ]),
    );
    return reply.future;
  }

  /// A hot reload, or with [full] a hot restart; one at a time, the last one asked for waits.
  Future<void> restart({required bool full, required String reason}) async {
    if (!_started || _busy) {
      _queued = (full: full || (_queued?.full ?? false), reason: reason);
      return;
    }
    _busy = true;
    say('${full ? 'hot restart' : 'hot reload'} ($reason)');
    final reply = await _call('app.restart', {'appId': _appId, 'fullRestart': full, 'pause': false, 'reason': reason});
    final result = (reply['result'] as Map?)?.cast<String, dynamic>();
    final code = result?['code'];
    final message = '${result?['message'] ?? reply['error'] ?? ''}'.trim();
    if (code == 0) {
      say(message.isEmpty ? 'done' : message);
    } else if (message.contains('synchronization failed')) {
      // the compiler's errors are printed above; the next saved change tries again
      say('not applied: the code does not compile yet');
    } else {
      say('not applied: $message');
      if (!full) say('this change needs a hot restart, which loses the game in memory: save it, then type R');
    }
    _busy = false;
    _runQueued();
  }

  void _runQueued() {
    final next = _queued;
    if (next == null || !_started) return;
    _queued = null;
    restart(full: next.full, reason: next.reason);
  }

  Future<void> stop() async {
    if (_appId == null) {
      process.kill();
      return;
    }
    await _call('app.stop', {'appId': _appId});
  }
}
