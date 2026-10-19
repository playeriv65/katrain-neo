// End-to-end tests of the CLI against a tiny API server (the transport, output and exit codes of the
// playeriv65/katrain fork's katrain/cli.py main).

import 'dart:convert';
import 'dart:io';

import 'package:katrain_cli/katrain_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const token = 'secret-token';

class _FakeApi {
  late HttpServer server;
  final requests = <({String method, String path, Object? body})>[];

  /// The envelope returned for a command; default `{"ok": true, "result": {"command": ..., "args": ...}}`.
  Map<String, Object?> Function(String command, Map<String, dynamic> args)? reply;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final text = await utf8.decodeStream(request);
      final body = text.isEmpty ? null : jsonDecode(text);
      requests.add((method: request.method, path: request.uri.path, body: body));
      final response = request.response..headers.contentType = ContentType.json;
      if (request.headers.value('X-KaTrain-Token') != token) {
        response.statusCode = 403;
        response.write(
          jsonEncode({
            'ok': false,
            'error': {'code': 'bad_token', 'message': 'missing or wrong token'},
          }),
        );
      } else if (request.uri.path == '/v1/health') {
        response.write(
          jsonEncode({
            'ok': true,
            'result': {'app': 'KaTrain Neo', 'api_version': 1},
          }),
        );
      } else {
        final b = body as Map<String, dynamic>;
        final command = b['command'] as String;
        final args = b['args'] as Map<String, dynamic>;
        response.write(
          jsonEncode(
            reply?.call(command, args) ??
                {
                  'ok': true,
                  'result': {'command': command, 'args': args},
                },
          ),
        );
      }
      await response.close();
    });
  }

  Map<String, dynamic> get discovery => {'port': server.port, 'token': token, 'pid': 1, 'started': 0};
}

class _Run {
  final int code;
  final String out;
  final String err;
  _Run(this.code, this.out, this.err);
  Object? get json => jsonDecode(out);
}

void main() {
  late _FakeApi api;
  setUp(() async {
    api = _FakeApi();
    await api.start();
  });
  tearDown(() => api.server.close(force: true));

  Future<_Run> run(List<String> argv, {Map<String, dynamic>? Function()? discovery, String stdinText = ''}) async {
    final out = StringBuffer(), err = StringBuffer();
    final env = CliEnvironment(
      out: out,
      err: err,
      client: ApiClient(discovery: discovery ?? () => api.discovery),
      readStdin: () => stdinText,
    );
    final code = await runCli(argv, env);
    return _Run(code, out.toString(), err.toString());
  }

  test('sends the command with the token header, drops null args and prints compact JSON', () async {
    final r = await run(['--compact', 'board', '--node', '45']);
    expect(r.code, exitOk);
    expect(r.out, '{"command":"board","args":{"node":"45"}}\n');
    expect(api.requests.single.method, 'POST');
    expect(api.requests.single.path, '/v1/command');
    expect(api.requests.single.body, {
      'command': 'board',
      'args': {'node': '45'},
    });
  });

  test('pretty JSON keeps non-ASCII text', () async {
    api.reply = (_, _) => {
      'ok': true,
      'result': {
        'text': '黑棋很厚',
        'list': [1, 2.5],
        'empty': {},
      },
    };
    final r = await run(['message', '黑棋很厚']);
    expect(r.out, '{\n  "text": "黑棋很厚",\n  "list": [\n    1,\n    2.5\n  ],\n  "empty": {}\n}\n');
    expect((api.requests.single.body as Map)['args'], {'text': '黑棋很厚'});
  });

  test('board --ascii and sandbox board --ascii print only the diagram', () async {
    api.reply = (_, _) => {
      'ok': true,
      'result': {'ascii': 'X . O\n. . .', 'stones': []},
    };
    expect((await run(['board', '--ascii'])).out, 'X . O\n. . .\n');
    expect((await run(['sandbox', 'board', 's1', '--ascii'])).out, 'X . O\n. . .\n');
    expect((await run(['board'])).json, {'ascii': 'X . O\n. . .', 'stones': []});
  });

  test('a command error prints the error envelope and exits 1', () async {
    api.reply = (_, _) => {
      'ok': false,
      'error': {'code': 'bad_node', 'message': 'no such node', 'hint': 'use n<ID>'},
      'extra': 1,
    };
    final r = await run(['goto', 'n999']);
    expect(r.code, exitApiError);
    expect(r.json, {
      'ok': false,
      'error': {'code': 'bad_node', 'message': 'no such node', 'hint': 'use n<ID>'},
    });
  });

  test('a wrong token gets the server error (HTTP 403 with a JSON body)', () async {
    final r = await run(['status'], discovery: () => {...api.discovery, 'token': 'wrong'});
    expect(r.code, exitApiError);
    expect((r.json as Map)['error'], {'code': 'bad_token', 'message': 'missing or wrong token'});
  });

  test('not running: no discovery file, or nothing listening, exits 3', () async {
    var r = await run(['status'], discovery: () => null);
    expect(r.code, exitNotRunning);
    expect(r.json, {
      'ok': false,
      'error': {
        'code': 'gui_not_running',
        'message': 'KaTrain Neo is not running (no ~/.katrain-neo/api.json). Start it with: katrain-neo gui',
      },
    });
    final port = api.server.port;
    await api.server.close(force: true);
    r = await run(['status', '--compact'], discovery: () => {'port': port, 'token': token});
    expect(r.code, exitNotRunning);
    final error = (r.json as Map)['error'] as Map;
    expect(error['code'], 'gui_not_running');
    expect(error['message'], startsWith('KaTrain Neo is not reachable ('));
  });

  test('--port overrides the discovery port', () async {
    final r = await run(['status', '--port', '${api.server.port}'], discovery: () => {'port': 1, 'token': token});
    expect(r.code, exitOk);
  });

  test('ping uses GET /v1/health', () async {
    final r = await run(['ping']);
    expect(r.code, exitOk);
    expect(r.json, {'app': 'KaTrain Neo', 'api_version': 1});
    expect(api.requests.single.method, 'GET');
    expect(api.requests.single.path, '/v1/health');
  });

  test('call and commands', () async {
    var r = await run(['call', 'nav.goto', '{"node": "45", "board": null}']);
    expect(r.code, exitOk);
    expect(r.json, {
      'command': 'nav.goto',
      'args': {'node': '45'},
    });
    r = await run(['commands']);
    expect((r.json as Map)['command'], 'commands');
    r = await run(['call', 'status', '{bad']);
    expect(r.code, exitUsage);
    expect(r.err, startsWith('invalid JSON arguments'));
    r = await run(['call', 'status', '[1]']);
    expect(r.code, exitUsage);
    expect(r.err, 'JSON arguments must be an object\n');
  });

  test('open follows katrain:// links; bad links exit 1', () async {
    var r = await run(['open', 'katrain://variation/v3?step=2&as=branch']);
    expect(r.json, {
      'command': 'variation.show',
      'args': {'id': 'v3', 'step': '2', 'as': 'branch'},
    });
    r = await run(['open', 'http://example.com']);
    expect(r.code, exitApiError);
    expect(r.json, {
      'ok': false,
      'error': {'code': 'bad_link', 'message': 'links must start with katrain://'},
    });
    r = await run(['open', 'katrain://goto/4'], discovery: () => null);
    expect(r.code, exitApiError);
    expect(((r.json as Map)['error'] as Map)['code'], 'bad_link');
  });

  test('sgf import - reads stdin; paths are made absolute', () async {
    var r = await run(['sgf', 'import', '-', '--end'], stdinText: '(;GM[1])');
    expect((r.json as Map)['args'], {'content': '(;GM[1])', 'fast': false, 'at_end': true});
    r = await run(['sgf', 'import', 'game.sgf']);
    expect(((r.json as Map)['args'] as Map)['path'], p.normalize(p.absolute('game.sgf')));
  });

  test('usage errors exit 2 on stderr, help exits 0', () async {
    var r = await run(['play']);
    expect(r.code, exitUsage);
    expect(r.out, isEmpty);
    expect(r.err, contains('katrain-neo play: error: the following arguments are required: moves'));
    r = await run(['play', '--help']);
    expect(r.code, exitOk);
    expect(r.out, startsWith('usage: katrain-neo play'));
    r = await run(['--compact']);
    expect(r.code, exitUsage);
    expect(r.out, startsWith('usage: katrain-neo'));
    expect(api.requests, isEmpty);
  });

  test('guide prints the agent guide for katrain-neo', () async {
    final r = await run(['guide']);
    expect(r.code, exitOk);
    expect(r.out, contains('katrain-neo sandbox new --from 36'));
    expect(r.out, contains('~/.katrain-neo/api_backups'));
    expect(RegExp(r'(^|[\s`])katrain (?!Neo)').hasMatch(r.out), isFalse);
  });

  test('plain katrain-neo and katrain-neo game.sgf start the app without waiting', () async {
    final launches = <String>[];
    Future<_Run> runLaunch(List<String> argv) async {
      final out = StringBuffer();
      final env = CliEnvironment(
        out: out,
        err: StringBuffer(),
        client: ApiClient(discovery: () => api.discovery),
        launch: ({config, sgf, wait = true, timeout = 90}) async {
          launches.add('$config|$sgf|$wait|$timeout');
          return {
            'ok': true,
            'result': {'started': true, 'pid': 42},
          };
        },
      );
      return _Run(await runCli(argv, env), out.toString(), '');
    }

    expect((await runLaunch([])).json, {'started': true, 'pid': 42});
    await runLaunch(['Game.SGF']);
    await runLaunch(['my_config.json']);
    await runLaunch(['gui', 'x.sgf', '--timeout', '5']);
    expect(launches, [
      'null|null|false|90',
      'null|Game.SGF|false|90',
      'my_config.json|null|false|90',
      'null|x.sgf|true|5',
    ]);
  });

  test('gui reuses a running app', () async {
    final r = await launchGui(ApiClient(discovery: () => api.discovery), discovery: () => api.discovery);
    expect(r['ok'], isTrue);
    expect((r['result'] as Map)['already_running'], isTrue);
    expect((r['result'] as Map)['port'], api.server.port);
  });

  test('gui without an app executable reports app_not_found', () async {
    expect(findApp(environment: {}, executable: p.join(Directory.systemTemp.path, 'nothing', 'katrain-neo')), isNull);
    expect(findApp(environment: {appVariable: '/opt/neo/katrain_neo'}), '/opt/neo/katrain_neo');
    final dir = Directory.systemTemp.createTempSync('katrain_cli_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = File(p.join(dir.path, appNames.last))..writeAsStringSync('');
    expect(findApp(environment: {}, executable: p.join(dir.path, 'katrain-neo')), app.path);
  });

  test('gui waits for the API of the started app and times out', () async {
    // a detached `dart` without arguments stands in for the app: it exits at once and writes no discovery file
    final client = ApiClient(discovery: () => null);
    var r = await launchGui(client, app: Platform.resolvedExecutable, wait: false, discovery: () => null);
    expect(r['ok'], isTrue);
    expect((r['result'] as Map)['pid'], isA<int>());
    r = await launchGui(client, app: Platform.resolvedExecutable, timeout: 1, discovery: () => null);
    expect(r['error'], {'code': 'timeout', 'message': 'KaTrain Neo API not ready after 1s'});
  });

  test('the compiled entry point finds the app through ~/.katrain-neo/api.json', () async {
    final home = Directory.systemTemp.createTempSync('katrain_cli_home');
    addTearDown(() => home.deleteSync(recursive: true));
    File(p.join(home.path, '.katrain-neo', 'api.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(api.discovery));
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/katrain_neo.dart', 'message', '黑棋'],
      environment: {'HOME': home.path, 'USERPROFILE': home.path},
      stdoutEncoding: utf8,
    );
    expect(result.exitCode, exitOk, reason: '${result.stderr}');
    expect(jsonDecode(result.stdout as String), {
      'command': 'message',
      'args': {'text': '黑棋'},
    });
    final bad = await Process.run(Platform.resolvedExecutable, ['run', 'bin/katrain_neo.dart', 'play']);
    expect(bad.exitCode, exitUsage);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
