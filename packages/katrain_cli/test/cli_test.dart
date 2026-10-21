// Tests of the `katrain-neo` CLI: every command line's API request (command, arguments, client timeout), usage
// errors and help, global options anywhere, katrain:// links, and end to end against a tiny API server (transport,
// output, exit codes, launching the app).

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

/// One request the CLI made: what `ApiClient.call` received (null arguments dropped, as when sending).
typedef _Request = ({String command, Map<String, Object?> args, int timeout, int? port});

/// Records requests instead of sending them; every command succeeds with an empty result.
class _Recorder extends ApiClient {
  final requests = <_Request>[];

  @override
  Future<Envelope> call(String command, [Map<String, Object?>? args, int? port, int timeout = 60]) async {
    requests.add((
      command: command,
      args: {for (final MapEntry(:key, :value) in (args ?? const {}).entries) key: ?value},
      timeout: timeout,
      port: port,
    ));
    return {'ok': true, 'result': <String, Object?>{}};
  }
}

/// Runs [argv] against a [_Recorder]; paths are made absolute as `/abs/<path>`, standard input is `(;GM[1])`.
Future<({int code, String out, String err, List<_Request> requests})> _record(List<String> argv) async {
  final client = _Recorder();
  final out = StringBuffer(), err = StringBuffer();
  final code = await runCli(
    argv,
    CliEnvironment(out: out, err: err, client: client, readStdin: () => '(;GM[1])', absolute: (s) => '/abs/$s'),
  );
  return (code: code, out: '$out', err: '$err', requests: client.requests);
}

/// Command line -> (API command, arguments, seconds the client waits). Commands that wait for the engine send
/// `timeout` (default 300, or --timeout) and the client waits 30 s longer; the others wait --timeout or 60 s.
const List<(List<String>, String, Map<String, Object?>, int)> _requests = [
  (['status'], 'status', {}, 60),
  (['board'], 'board', {}, 60),
  (['board', '--node', '45', '--ascii'], 'board', {'node': '45'}, 60),
  (['board', '-n', 'root'], 'board', {'node': 'root'}, 60),
  (['node'], 'node', {}, 60),
  (['node', 'n17'], 'node', {'node': 'n17'}, 60),
  (['history'], 'history', {'future': false, 'eval': true}, 60),
  (['history', '--node', '45', '--future', '--no-eval'], 'history', {'node': '45', 'future': true, 'eval': false}, 60),
  (['tree'], 'tree', {}, 60),
  (['tree', '-n', 'n3', '--max-depth', '30'], 'tree', {'node': 'n3', 'max_depth': 30}, 60),
  (['variations', '--node', 'main:3'], 'variations', {'node': 'main:3'}, 60),
  (['sgf', 'export'], 'sgf.export', {'overwrite': false, 'analysis': false, 'comments': false, 'marks': false}, 60),
  (
    ['sgf', 'export', '-o', 'x.sgf', '--overwrite', '--analysis', '--comments', '--marks'],
    'sgf.export',
    {'path': '/abs/x.sgf', 'overwrite': true, 'analysis': true, 'comments': true, 'marks': true},
    60,
  ),
  (
    ['sgf', 'export', '--out', ''],
    'sgf.export',
    {'path': '', 'overwrite': false, 'analysis': false, 'comments': false, 'marks': false},
    60,
  ),
  (['sgf', 'import', 'game.sgf'], 'sgf.import', {'path': '/abs/game.sgf', 'fast': false, 'at_end': false}, 60),
  (['sgf', 'import', '-', '--fast', '--end'], 'sgf.import', {'content': '(;GM[1])', 'fast': true, 'at_end': true}, 60),
  (['game', 'new'], 'game.new', {}, 60),
  (
    ['game', 'new', '--size', '13', '--komi', '6.5', '--rules', 'chinese', '--handicap', '2'],
    'game.new',
    {'size': '13', 'komi': 6.5, 'rules': 'chinese', 'handicap': 2},
    60,
  ),
  (['game', 'new', '--komi', '-0.5'], 'game.new', {'komi': -0.5}, 60),
  (['analysis', 'get'], 'analysis.get', {'pv': true, 'ownership': false, 'policy': false}, 60),
  (
    [
      'analysis',
      'get',
      '--node',
      '45',
      '--top',
      '5',
      '--no-pv',
      '--pv-limit',
      '3',
      '--ownership',
      '--policy',
      '--moves',
      'D4,Q16',
    ],
    'analysis.get',
    {
      'node': '45',
      'moves': ['D4', 'Q16'],
      'top': 5,
      'pv': false,
      'pv_limit': 3,
      'ownership': true,
      'policy': true,
    },
    60,
  ),
  (
    ['analysis', 'run'],
    'analysis.run',
    {'force': false, 'wait': true, 'timeout': 300, 'pv': true, 'ownership': false, 'policy': false},
    330,
  ),
  (
    [
      'analysis',
      'run',
      '-n',
      '45',
      '-v',
      '2000',
      '--region',
      'C3:G7',
      '--max-time',
      '2.5',
      '--force',
      '--no-wait',
      '--top',
      '3',
    ],
    'analysis.run',
    {
      'node': '45',
      'visits': 2000,
      'region': 'C3:G7',
      'max_time': 2.5,
      'force': true,
      'wait': false,
      'timeout': 300,
      'top': 3,
      'pv': true,
      'ownership': false,
      'policy': false,
    },
    330,
  ),
  (
    ['analysis', 'run', '--timeout', '20'],
    'analysis.run',
    {'force': false, 'wait': true, 'timeout': 20, 'pv': true, 'ownership': false, 'policy': false},
    50,
  ),
  (
    ['analysis', 'moves', 'D4', 'C3', 'E5'],
    'analysis.moves',
    {
      'moves': ['D4', 'C3', 'E5'],
      'timeout': 300,
      'pv': true,
      'ownership': false,
      'policy': false,
    },
    330,
  ),
  (
    ['analysis', 'moves', 'D4', '--node', '45', '-v', '800', '--pv-limit', '2', '--timeout', '9'],
    'analysis.moves',
    {
      'node': '45',
      'moves': ['D4'],
      'visits': 800,
      'timeout': 9,
      'pv': true,
      'pv_limit': 2,
      'ownership': false,
      'policy': false,
    },
    39,
  ),
  (['analysis', 'game'], 'analysis.game', {'mistakes_only': false}, 60),
  (
    ['analysis', 'game', '-v', '300', '--mistakes-only', '--range', '20-60'],
    'analysis.game',
    {'visits': 300, 'mistakes_only': true, 'move_range': '20-60'},
    60,
  ),
  (['analysis', 'wait'], 'analysis.wait', {'timeout': 300}, 330),
  (['analysis', 'wait', '--timeout', '5'], 'analysis.wait', {'timeout': 5}, 35),
  (['analysis', 'ponder', 'on'], 'analysis.ponder', {'on': true}, 60),
  (['analysis', 'ponder', 'off'], 'analysis.ponder', {'on': false}, 60),
  (['analysis', 'stop'], 'analysis.stop', {}, 60),
  (['engine', 'get'], 'engine.get', {}, 60),
  (['engine', 'set'], 'engine.set', {'save': false}, 60),
  (
    [
      'engine',
      'set',
      '--max-visits',
      '1000',
      '--fast-visits',
      '50',
      '--max-time',
      '8',
      '--wide-root-noise',
      '0.04',
      '--save',
    ],
    'engine.set',
    {'max_visits': 1000, 'fast_visits': 50, 'max_time': 8.0, 'wide_root_noise': 0.04, 'save': true},
    60,
  ),
  (['goto', '45'], 'nav.goto', {'node': '45', 'board': false}, 60),
  (['goto', 'n12', '--board'], 'nav.goto', {'node': 'n12', 'board': true}, 60),
  (['next'], 'nav.next', {'n': 1, 'board': false}, 60),
  (['next', '3', '--board'], 'nav.next', {'n': 3, 'board': true}, 60),
  (['prev'], 'nav.prev', {'n': 1, 'board': false}, 60),
  (['prev', '2'], 'nav.prev', {'n': 2, 'board': false}, 60),
  (['branch', 'next'], 'nav.branch', {'direction': 1, 'board': false}, 60),
  (['branch', 'prev', '--board'], 'nav.branch', {'direction': -1, 'board': true}, 60),
  (['branch', '2'], 'nav.branch', {'index': '2', 'board': false}, 60),
  (
    ['play', 'D4', 'Q16'],
    'play',
    {
      'moves': ['D4', 'Q16'],
      'analyze': true,
      'board': false,
    },
    60,
  ),
  (
    ['play', 'D4', '--color', 'W', '--no-analyze', '--board'],
    'play',
    {
      'moves': ['D4'],
      'color': 'W',
      'analyze': false,
      'board': true,
    },
    60,
  ),
  (
    ['variation', 'add', 'C3', 'D2'],
    'variation.add',
    {
      'moves': ['C3', 'D2'],
      'goto': false,
      'analyze': 'fast',
    },
    60,
  ),
  (
    ['variation', 'add', 'C3', 'D2', '--from', '45', '--color', 'B', '--goto', '--analyze', 'full'],
    'variation.add',
    {
      'moves': ['C3', 'D2'],
      'from': '45',
      'color': 'B',
      'goto': true,
      'analyze': 'full',
    },
    60,
  ),
  (['variation', 'delete', 'n88'], 'variation.delete', {'node': 'n88', 'force': false}, 60),
  (['variation', 'delete', 'n88', '--force'], 'variation.delete', {'node': 'n88', 'force': true}, 60),
  (['variation', 'promote', 'n88'], 'variation.promote', {'node': 'n88'}, 60),
  (
    ['variation', 'register', 'D4', 'C3', 'D3'],
    'variation.register',
    {
      'moves': ['D4', 'C3', 'D3'],
    },
    60,
  ),
  (
    ['variation', 'register', 'D4', 'C3', '--from', '45', '--color', 'W', '--label', 'main idea'],
    'variation.register',
    {
      'moves': ['D4', 'C3'],
      'from': '45',
      'color': 'W',
      'label': 'main idea',
    },
    60,
  ),
  (['variation', 'list'], 'variation.list', {}, 60),
  (['variation', 'show', 'v1'], 'variation.show', {'id': 'v1', 'as': 'pv'}, 60),
  (
    ['variation', 'show', 'v1', '--as', 'branch', '--step', '2'],
    'variation.show',
    {'id': 'v1', 'as': 'branch', 'step': 2},
    60,
  ),
  (['pv', 'show'], 'pv.show', {}, 60),
  (
    ['pv', 'show', 'C3', 'D2', 'C2', '--step', '3'],
    'pv.show',
    {
      'moves': ['C3', 'D2', 'C2'],
      'step': 3,
    },
    60,
  ),
  (
    ['pv', 'show', '--candidate', 'D4', '--from', '45', '--step', '1'],
    'pv.show',
    {'from': '45', 'candidate': 'D4', 'step': 1},
    60,
  ),
  (['pv', 'step'], 'pv.step', {'delta': 1}, 60),
  (['pv', 'step', '2'], 'pv.step', {'delta': 2}, 60),
  (['pv', 'step', '--', '-1'], 'pv.step', {'delta': -1}, 60),
  (['pv', 'step', '--index', '4'], 'pv.step', {'delta': 1, 'index': 4}, 60),
  (['pv', 'hide'], 'pv.hide', {}, 60),
  (
    ['mark', 'add', 'D4', 'E5'],
    'mark.add',
    {
      'points': ['D4', 'E5'],
      'type': 'circle',
      'scope': 'node',
    },
    60,
  ),
  (
    ['mark', 'add', 'D4', 'E5', '--type', 'label', '--text', 'A,B', '--color', 'orange', '--global'],
    'mark.add',
    {
      'points': ['D4', 'E5'],
      'type': 'label',
      'text': ['A', 'B'],
      'color': 'orange',
      'scope': 'global',
    },
    60,
  ),
  (
    ['mark', 'add', 'D4', '-t', 'square', '-c', 'red'],
    'mark.add',
    {
      'points': ['D4'],
      'type': 'square',
      'color': 'red',
      'scope': 'node',
    },
    60,
  ),
  (['mark', 'area', 'C3:G7'], 'mark.area', {'region': 'C3:G7', 'scope': 'node'}, 60),
  (
    ['mark', 'area', 'C3:G7', '--text', 'weak group', '-c', 'orange', '--global'],
    'mark.area',
    {'region': 'C3:G7', 'text': 'weak group', 'color': 'orange', 'scope': 'global'},
    60,
  ),
  (['mark', 'list'], 'mark.list', {}, 60),
  (['mark', 'clear'], 'mark.clear', {}, 60),
  (
    ['mark', 'clear', 'D4', 'E5'],
    'mark.clear',
    {
      'points': ['D4', 'E5'],
    },
    60,
  ),
  (
    ['mark', 'clear', '--ids', 'm1,m2'],
    'mark.clear',
    {
      'ids': ['m1', 'm2'],
    },
    60,
  ),
  (['region', 'set', 'C3:G7'], 'region.set', {'region': 'C3:G7'}, 60),
  (['region', 'clear'], 'region.clear', {}, 60),
  (['view'], 'view.set', {}, 60),
  (
    [
      'view',
      '--hints',
      'on',
      '--ownership',
      'off',
      '--policy',
      'yes',
      '--eval',
      '0',
      '--children',
      'true',
      '--move-numbers',
      'no',
    ],
    'view.set',
    {'hints': true, 'ownership': false, 'policy': true, 'eval': false, 'children': true, 'move_numbers': false},
    60,
  ),
  (['view', '--zoom', 'auto', '--hide-frame', 'on'], 'view.set', {'zoom': 'auto', 'hide_frame': true}, 60),
  (['mode', 'play'], 'mode.set', {'mode': 'play'}, 60),
  (['mode', 'analyze'], 'mode.set', {'mode': 'analyze'}, 60),
  (['message', 'Look here'], 'message', {'text': 'Look here'}, 60),
  (['state', 'save'], 'state.save', {'name': 'default'}, 60),
  (['state', 'save', 'before'], 'state.save', {'name': 'before'}, 60),
  (['state', 'restore', 'before'], 'state.restore', {'name': 'before'}, 60),
  (['state', 'restore'], 'state.restore', {'name': 'default'}, 60),
  (['state', 'list'], 'state.list', {}, 60),
  (['demo', 'start'], 'demo.start', {}, 60),
  (['demo', 'start', '--label', 'why C3 fails'], 'demo.start', {'label': 'why C3 fails'}, 60),
  (['demo', 'end'], 'demo.end', {'keep': false}, 60),
  (['demo', 'end', '--keep'], 'demo.end', {'keep': true}, 60),
  (['demo', 'status'], 'demo.status', {}, 60),
  (['tsumego', 'list', 'probs'], 'tsumego.list', {'source': '/abs/probs', 'limit': 200}, 60),
  (
    ['tsumego', 'list', 'probs', '--set', 'cho', '--difficulty', 'elementary', '--limit', '20'],
    'tsumego.list',
    {'source': '/abs/probs', 'set': 'cho', 'difficulty': 'elementary', 'limit': 20},
    60,
  ),
  (
    ['tsumego', 'list', 'probs', '--level', '2-4'],
    'tsumego.list',
    {'source': '/abs/probs', 'level': '2-4', 'limit': 200},
    60,
  ),
  (
    ['tsumego', 'list', 'probs', '--unanswered'],
    'tsumego.list',
    {'source': '/abs/probs', 'answered': false, 'limit': 200},
    60,
  ),
  (
    ['tsumego', 'load', 'probs'],
    'tsumego.load',
    {'source': '/abs/probs', 'index': 0, 'margin': 4, 'ko': false, 'zoom': true},
    60,
  ),
  (
    [
      'tsumego',
      'load',
      'probs',
      '--no-zoom',
      '-i',
      '3',
      '--set',
      'cho',
      '--difficulty',
      'hard',
      '--frame',
      'off',
      '--margin',
      '2',
      '--ko',
    ],
    'tsumego.load',
    {
      'source': '/abs/probs',
      'index': 3,
      'set': 'cho',
      'difficulty': 'hard',
      'frame': false,
      'margin': 2,
      'ko': true,
      'zoom': false,
    },
    60,
  ),
  (['tsumego', 'target'], 'tsumego.target', {}, 60),
  (
    ['tsumego', 'target', '--goal', 'kill', '--group', 'C2', '--region', 'A1:F6'],
    'tsumego.target',
    {'goal': 'kill', 'group': 'C2', 'region': 'A1:F6'},
    60,
  ),
  (['tsumego', 'try', 'B2'], 'tsumego.try', {'move': 'B2', 'reply': true, 'timeout': 300}, 330),
  (
    ['tsumego', 'try', 'B2', '-v', '500', '--no-reply', '--timeout', '30'],
    'tsumego.try',
    {'move': 'B2', 'visits': 500, 'reply': false, 'timeout': 30},
    60,
  ),
  (['tsumego', 'eval'], 'tsumego.eval', {'timeout': 300}, 330),
  (['tsumego', 'eval', '-v', '100'], 'tsumego.eval', {'visits': 100, 'timeout': 300}, 330),
  (['tsumego', 'reset'], 'tsumego.reset', {}, 60),
  (['tsumego', 'solution'], 'tsumego.solution', {'show': false, 'timeout': 300}, 330),
  (['tsumego', 'hint', '--level', '1'], 'tsumego.hint', {'level': 1, 'timeout': 300}, 330),
  (
    ['tsumego', 'solution', '--show', '-v', '200'],
    'tsumego.solution',
    {'show': true, 'visits': 200, 'timeout': 300},
    330,
  ),
  (['tsumego', 'status'], 'tsumego.status', {}, 60),
  (['sandbox', 'new'], 'sandbox.new', {}, 60),
  (['sandbox', 'new', '--from', '36', '--name', 'mine'], 'sandbox.new', {'from': '36', 'name': 'mine'}, 60),
  (
    ['sandbox', 'play', 's1', 'H5', 'B8'],
    'sandbox.play',
    {
      'id': 's1',
      'moves': ['H5', 'B8'],
    },
    60,
  ),
  (
    ['sandbox', 'play', 's1', 'H5', '--color', 'W'],
    'sandbox.play',
    {
      'id': 's1',
      'moves': ['H5'],
      'color': 'W',
    },
    60,
  ),
  (['sandbox', 'back', 's1'], 'sandbox.back', {'id': 's1', 'n': 1}, 60),
  (['sandbox', 'back', 's1', '2'], 'sandbox.back', {'id': 's1', 'n': 2}, 60),
  (['sandbox', 'board', 's1'], 'sandbox.board', {'id': 's1'}, 60),
  (
    ['sandbox', 'analyze', 's1'],
    'sandbox.analyze',
    {'id': 's1', 'pv': true, 'ownership': false, 'force': false, 'timeout': 300},
    330,
  ),
  (
    [
      'sandbox',
      'analyze',
      's1',
      '-v',
      '2000',
      '--moves',
      'H6,H4',
      '--top',
      '3',
      '--no-pv',
      '--pv-limit',
      '4',
      '--ownership',
      '--force',
    ],
    'sandbox.analyze',
    {
      'id': 's1',
      'visits': 2000,
      'moves': ['H6', 'H4'],
      'top': 3,
      'pv': false,
      'pv_limit': 4,
      'ownership': true,
      'force': true,
      'timeout': 300,
    },
    330,
  ),
  (['sandbox', 'show', 's1'], 'sandbox.show', {'id': 's1', 'as': 'pv'}, 60),
  (['sandbox', 'show', 's1', '--as', 'goto', '--step', '3'], 'sandbox.show', {'id': 's1', 'as': 'goto', 'step': 3}, 60),
  (['sandbox', 'list'], 'sandbox.list', {}, 60),
  (['sandbox', 'drop', 's1'], 'sandbox.drop', {'id': 's1', 'prune': false}, 60),
  (['sandbox', 'drop', 'all', '--prune'], 'sandbox.drop', {'id': 'all', 'prune': true}, 60),
  (['commands'], 'commands', {}, 60),
  (['call', 'nav.goto', '{"node": "45"}'], 'nav.goto', {'node': '45'}, 60),
  (['call', 'analysis.run', '{"timeout": 100}'], 'analysis.run', {'timeout': 100}, 160),
  (['call', 'analysis.run', '{"timeout": 100}', '--timeout', '7'], 'analysis.run', {'timeout': 100}, 7),
  (['call', 'status'], 'status', {}, 60),
  // several values: comma separated, repeated, or both
  (
    ['analysis', 'get', '--moves', 'D4', '--moves', 'Q16,R4'],
    'analysis.get',
    {
      'moves': ['D4', 'Q16', 'R4'],
      'pv': true,
      'ownership': false,
      'policy': false,
    },
    60,
  ),
  (
    ['mark', 'add', 'D4', 'E5', '--text', 'A', '--text', 'B'],
    'mark.add',
    {
      'points': ['D4', 'E5'],
      'type': 'circle',
      'text': ['A', 'B'],
      'scope': 'node',
    },
    60,
  ),
  (
    ['mark', 'clear', '--ids', '3', '--ids', '4'],
    'mark.clear',
    {
      'ids': ['3', '4'],
    },
    60,
  ),
  (
    ['sandbox', 'analyze', 's1', '--moves', 'H6', '--moves', 'H4'],
    'sandbox.analyze',
    {
      'id': 's1',
      'moves': ['H6', 'H4'],
      'pv': true,
      'ownership': false,
      'force': false,
      'timeout': 300,
    },
    330,
  ),
  // option spellings package:args accepts
  (
    ['analysis', 'run', '-v100', '--node=45'],
    'analysis.run',
    {
      'node': '45',
      'visits': 100,
      'force': false,
      'wait': true,
      'timeout': 300,
      'pv': true,
      'ownership': false,
      'policy': false,
    },
    330,
  ),
  (
    ['play', 'D4', '--color', 'B', 'Q16'],
    'play',
    {
      'moves': ['D4', 'Q16'],
      'color': 'B',
      'analyze': true,
      'board': false,
    },
    60,
  ),
  (['message', '--', '--not an option'], 'message', {'text': '--not an option'}, 60),
  // --timeout also bounds the commands that do not wait for the engine
  (['commands', '--timeout', '5'], 'commands', {}, 5),
  (['open', 'katrain://goto/45', '--timeout', '5'], 'nav.goto', {'node': '45'}, 5),
];

void _requestTests() {
  group('requests', () {
    for (final (argv, command, args, timeout) in _requests) {
      test(argv.join(' '), () async {
        final r = await _record(argv);
        expect(r.code, exitOk, reason: r.err);
        expect(r.requests, hasLength(1));
        final sent = r.requests.single;
        expect([sent.command, sent.args, sent.timeout, sent.port], [command, args, timeout, null]);
      });
    }

    test('every command is in the table', () {
      final runner = CliRunner(CliEnvironment(out: StringBuffer(), err: StringBuffer()), buildCommands());
      const local = {'gui', 'ping', 'guide', 'help'}; // tested end to end
      final commands = [
        for (final MapEntry(:key, :value) in runner.commands.entries)
          if (!local.contains(key))
            if (value.subcommands.isEmpty) key else ...value.subcommands.keys.map((sub) => '$key $sub'),
      ];
      final tested = {
        for (final (argv, _, _, _) in _requests) argv.take(2).join(' '),
        for (final (argv, _, _, _) in _requests) argv.first,
      };
      expect(commands.where((c) => !tested.contains(c)), isEmpty);
    });

    test('--port, --timeout and --compact work before, between and after the command words', () async {
      for (final argv in [
        ['--port', '9', '--timeout', '7', '--compact', 'analysis', 'wait'],
        ['analysis', '--port', '9', '--compact', 'wait', '--timeout', '7'],
        ['analysis', 'wait', '--compact', '--timeout=7', '--port=9'],
      ]) {
        final r = await _record(argv);
        expect(r.code, exitOk, reason: r.err);
        final sent = r.requests.single;
        expect(
          [sent.command, sent.args, sent.timeout, sent.port],
          [
            'analysis.wait',
            {'timeout': 7},
            37,
            9,
          ],
        );
        expect(r.out, '{}\n');
      }
      expect((await _record(['status'])).out, '{}\n');
      expect((await _record(['status', '--compact'])).out, '{}\n');
    });
  });
}

void _usageTests() {
  group('usage', () {
    /// (command line, start of the message, start of the usage line)
    const errors = [
      (['--compact'], 'Missing command.', 'katrain-neo <command>'),
      (['nope'], 'Could not find a command named "nope".', 'katrain-neo <command>'),
      (['analysis'], 'Missing subcommand for "katrain-neo analysis".', 'katrain-neo analysis <subcommand>'),
      (
        ['analysis', 'rn'],
        'Could not find a subcommand named "rn" for "katrain-neo analysis".',
        'katrain-neo analysis',
      ),
      (['play'], 'Missing argument <moves>.', 'katrain-neo play <moves>... [options]'),
      (['sandbox', 'play', 's1'], 'Missing argument <moves>.', 'katrain-neo sandbox play <id> <moves>... [options]'),
      (['goto', '45', '46'], 'Unexpected argument "46".', 'katrain-neo goto <ref> [options]'),
      (['status', 'now'], 'Command "status" does not take any arguments.', 'katrain-neo status [options]'),
      (['analysis', 'run', '--vis', '100'], 'Could not find an option named "--vis".', 'katrain-neo analysis run'),
      (['analysis', 'run', '--visits'], 'Missing argument for "--visits".', 'katrain-neo analysis run'),
      (
        ['analysis', 'run', '-v', 'many'],
        'Invalid value for --visits: "many" is not an integer.',
        'katrain-neo analysis run',
      ),
      (['game', 'new', '--komi', 'x'], 'Invalid value for --komi: "x" is not a number.', 'katrain-neo game new'),
      (['next', 'two'], 'Invalid value for <n>: "two" is not an integer.', 'katrain-neo next [<n>]'),
      (['pv', 'step', '-1'], 'Could not find an option or flag "-1".', 'katrain-neo pv step [<delta>]'),
      (['view', '--hints', 'maybe'], 'Invalid value for --hints: "maybe" is not on or off.', 'katrain-neo view'),
      (
        ['analysis', 'ponder', 'later'],
        'Invalid value for <state>: "later" is not on or off.',
        'katrain-neo analysis ponder',
      ),
      (['mode', 'edit'], '"edit" is not an allowed value for <mode> (play, analyze).', 'katrain-neo mode <mode>'),
      (
        ['mark', 'add', 'D4', '--type', 'star'],
        '"star" is not an allowed value for option "--type".',
        'katrain-neo mark add',
      ),
      (['board', '--ascii=yes'], 'Flag option "--ascii" should not be given a value.', 'katrain-neo board'),
      (
        ['status', '--port', '0'],
        'Invalid value for --port: "0" is not a whole number from 1 to 65535.',
        'katrain-neo status',
      ),
      (
        ['status', '--timeout', '-5'],
        'Invalid value for --timeout: "-5" is not a whole number from 1.',
        'katrain-neo status',
      ),
    ];
    for (final (argv, message, usage) in errors) {
      test(argv.join(' '), () async {
        final r = await _record(argv);
        expect(r.code, exitUsage);
        expect(r.out, isEmpty);
        expect(r.err, startsWith(message));
        expect(r.err, contains('\n\nUsage: $usage'));
        expect(r.requests, isEmpty);
      });
    }

    test('--help on every level and the help command print usage on stdout and exit 0', () async {
      for (final (argv, start, line) in const [
        (['--help'], 'Control a running KaTrain Neo.', 'Usage: katrain-neo <command> [arguments]'),
        (['help'], 'Control a running KaTrain Neo.', 'Available commands:'),
        (['analysis', '--help'], 'KataGo analysis\n', 'Usage: katrain-neo analysis <subcommand> [arguments]'),
        (['analysis', 'run', '--help'], 'search a position', 'Usage: katrain-neo analysis run [options]'),
        (['help', 'sandbox', 'play'], 'play moves at the cursor', 'Usage: katrain-neo sandbox play <id> <moves>...'),
        (['play', '-h', 'D4'], 'play moves from the current position', '<moves>...    D4 Q16 ...'),
        (['status', '--compact', '--help'], 'game info', 'Run "katrain-neo help" to see global options.'),
      ]) {
        final r = await _record(argv);
        expect(r.code, exitOk, reason: argv.join(' '));
        expect(r.out, startsWith(start), reason: argv.join(' '));
        expect(r.out, contains(line), reason: argv.join(' '));
        expect(r.err, isEmpty);
        expect(r.requests, isEmpty);
      }
    });

    test('help lists options with their defaults and allowed values', () async {
      final r = await _record(['variation', 'add', '--help']);
      expect(r.out, contains('--analyze'));
      expect(r.out, contains('[fast (default), full, none]'));
      expect(r.out, contains('--from=<REF>'));
      expect((await _record(['tsumego', 'list', '--help'])).out, contains('(defaults to "200")'));
      expect((await _record(['pv', 'step', '--help'])).out, contains('[<delta>]    moves to add'));
    });
  });
}

void _linkTests() {
  group('links', () {
    const links = [
      ('katrain://goto/45', 'nav.goto', {'node': '45'}),
      ('katrain://goto?node=n12', 'nav.goto', {'node': 'n12'}),
      ('katrain://state/my%20pos', 'state.restore', {'name': 'my pos'}),
      ('katrain://state/a%2Fb', 'state.restore', {'name': 'a/b'}),
      ('katrain://state?name=a%2Fb', 'state.restore', {'name': 'a/b'}),
      ('katrain://variation/v3?step=2&as=branch', 'variation.show', {'id': 'v3', 'step': '2', 'as': 'branch'}),
      ('katrain://variation?id=v2', 'variation.show', {'id': 'v2'}),
      ('katrain://pv?from=45&moves=D4,Q16&step=1', 'pv.show', {'from': '45', 'moves': 'D4,Q16', 'step': '1'}),
      ('katrain://pv?candidate=D4&step=&x', 'pv.show', {'candidate': 'D4'}),
      ('katrain://pv?step=1&step=3&step=', 'pv.show', {'step': '3'}),
      ('katrain://analysis?node=45', 'analysis.get', {'node': '45'}),
      ('katrain://analysis/n3/', 'analysis.get', {'node': 'n3'}),
      ('  KATRAIN://Goto/5#top', 'nav.goto', {'node': '5'}),
    ];
    for (final (url, command, args) in links) {
      test(url, () {
        final call = linkToCommand(url);
        expect(call.command, command);
        expect({for (final MapEntry(:key, :value) in call.args.entries) key: ?value}, args);
      });
    }

    test('the link of a saved state leads back to it', () {
      const name = 'before 30/b ü';
      expect(linkToCommand('katrain://state/${Uri.encodeComponent(name)}').args, {'name': name});
    });

    test('bad links', () {
      for (final (url, message) in const [
        ('http://example.com/goto/4', 'links must start with katrain://'),
        ('katrain:goto/45', 'links must start with katrain://'),
        ('goto/45', 'links must start with katrain://'),
        ('katrain://nope/1', "unknown link action 'nope'"),
        ('katrain://[::1/goto', 'invalid link: '),
      ]) {
        expect(
          () => linkToCommand(url),
          throwsA(isA<LinkError>().having((e) => e.message, 'message', startsWith(message))),
          reason: url,
        );
      }
    });
  });
}

void main() {
  _requestTests();
  _usageTests();
  _linkTests();
  _endToEndTests();
}

void _endToEndTests() {
  group('end to end', () {
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
      expect(r.err, startsWith('Invalid JSON arguments'));
      r = await run(['call', 'status', '[1]']);
      expect(r.code, exitUsage);
      expect(r.err, startsWith('The JSON arguments must be an object.\n\nUsage: katrain-neo call <command> [<json>]'));
      r = await run(['call', 'status', '{"timeout": "soon"}']);
      expect(r.code, exitUsage);
      expect(r.err, startsWith('Invalid timeout in the JSON arguments: soon'));
      expect(api.requests, hasLength(2));
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

    test('usage errors exit 2 with the message and usage on stderr', () async {
      final r = await run(['play']);
      expect(r.code, exitUsage);
      expect(r.out, isEmpty);
      expect(r.err, startsWith('Missing argument <moves>.\n\nUsage: katrain-neo play <moves>... [options]\n'));
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
  });
}
