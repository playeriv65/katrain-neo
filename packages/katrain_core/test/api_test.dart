// The local API end to end: the HTTP server, its token, and a few commands on a game with an engine that answers
// at once.

import 'dart:convert';
import 'dart:io';

import 'package:katrain_core/api.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'game_script.dart';

class TestHost extends RecordingHost implements ApiHost {
  late AnalysisEngine<GameNode> testEngine;
  TestHost(super.settings);

  @override
  bool pondering = false;
  @override
  String mode = modePlay;
  @override
  String statusMessage = '';
  @override
  ApiPv? pv;
  final controls = <String, bool>{};
  @override
  bool showMoveNumbers = false;
  @override
  List<int>? zoomRegion;
  @override
  Set<(int, int)> hiddenCoords = {};

  @override
  AnalysisEngine<GameNode>? get engine => testEngine;
  @override
  bool engineAlive(AnalysisEngine<GameNode> engine) => true;
  @override
  bool engineIdle(AnalysisEngine<GameNode> engine) => true;
  @override
  int engineQueriesRemaining(AnalysisEngine<GameNode> engine) => 0;
  @override
  void saveConfig([String? key]) {}
  @override
  void redrawOverlay() {}
  @override
  void toggleContinuousAnalysis({bool quiet = false}) => pondering = !pondering;
  @override
  void selectMode(String mode) => this.mode = mode;
  @override
  void showStatus(String text) => statusMessage = text;
  @override
  void newGame(GameNode? moveTree, {bool analyzeFast = false, String? sgfFilename}) {
    if (moveTree != null) mode = modeAnalyze;
    game = Game(this, testEngine, moveTree: moveTree, analyzeFast: analyzeFast, sgfFilename: sgfFilename);
  }

  @override
  void tsumegoFrame(bool ko, int margin) {}
  @override
  bool analysisControl(String key) => controls[key] ?? false;
  @override
  void setAnalysisControl(String key, bool value) => controls[key] = value;
  @override
  void setZoom(List<int>? region, [Set<(int, int)> hidden = const {}]) {
    zoomRegion = region;
    hiddenCoords = hidden;
  }
}

/// Answers every query at once: the first empty points as candidates, Black slightly ahead.
class AnsweringEngine extends RecordingEngine {
  AnsweringEngine(super.host, super.config);

  @override
  void requestAnalysis(
    GameNode analysisNode, {
    required AnalysisCallback callback,
    AnalysisErrorCallback? errorCallback,
    int? visits,
    bool analyzeFast = false,
    bool timeLimit = true,
    bool findAlternatives = false,
    List<int>? regionOfInterest,
    int priority = 0,
    bool ponder = false,
    bool? ownership,
    Move? nextMove,
    Map<String, dynamic>? extraSettings,
    bool includePolicy = true,
    double? reportEvery,
  }) {
    final g = BaseGame<GameNode>.at(analysisNode);
    final (sx, sy) = analysisNode.boardSize;
    final empty = [
      for (var y = 0; y < sy; y++)
        for (var x = 0; x < sx; x++)
          if (g.board[y][x] < 0) Move(coords: (x, y)).gtp(),
    ];
    final v = visits ?? 100;
    callback(<String, dynamic>{
      'rootInfo': <String, dynamic>{'visits': v, 'winrate': 0.55, 'scoreLead': 1.5},
      'moveInfos': [
        for (var i = 0; i < 3; i++)
          <String, dynamic>{
            'move': empty[i],
            'order': i,
            'visits': v ~/ (i + 2),
            'winrate': 0.55 - i * 0.05,
            'scoreLead': 1.5 - i,
            'prior': 0.3 / (i + 1),
            'pv': [empty[i], empty[i + 3]],
          },
      ],
      'ownership': [for (var i = 0; i < sx * sy; i++) 0.0],
      'policy': [for (var i = 0; i <= sx * sy; i++) 1 / (sx * sy + 1)],
    }, false);
  }
}

void main() {
  late Directory tmp;
  late TestHost host;
  late ApiServer server;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('katrain_neo_api');
    final settings = defaultConfig();
    host = TestHost(settings);
    host.testEngine = AnsweringEngine(host, (settings['engine'] as Map).cast<String, dynamic>());
    host.newGame(null);
    final handler = CommandHandler(host, ApiState(), dataFolder: tmp.path);
    server = await ApiServer.start(
      handler,
      version: '0.0.0',
      log: (_, _) {},
      port: 18765,
      discoveryPath: '${tmp.path}/api.json',
    );
  });

  tearDown(() async {
    await server.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> send(String method, String path, {Object? body, String? token}) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      request.headers.set(tokenHeader, token ?? server.token);
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close();
      return (response.statusCode, jsonDecode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>);
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> call(String command, [Map<String, Object?> args = const {}]) async =>
      (await send('POST', commandPath, body: {'command': command, 'args': args})).$2;

  test('discovery file and health, with and without the token', () async {
    final info = readDiscovery('${tmp.path}/api.json')!;
    expect(info['port'], server.port);
    expect(info['token'], server.token);
    expect(info['pid'], pid);
    final (status, health) = await send('GET', healthPath);
    expect(status, 200);
    expect(health['result']['api_version'], apiVersion);
    expect((await send('GET', healthPath, token: 'wrong')).$1, 401);
    expect((await send('GET', '/elsewhere')).$1, 404);
  });

  test('bad requests and unknown commands', () async {
    expect((await send('POST', commandPath, body: {'command': 3})).$1, 400);
    final unknown = await call('nope');
    expect(unknown['ok'], isFalse);
    expect(unknown['error']['code'], 'unknown_command');
    expect(unknown['error']['available'], contains('status'));
  });

  test('import, read, analyse and play', () async {
    final imported = await call('sgf.import', {'content': '(;GM[1]SZ[9]KM[7];B[ee];W[cc];B[gc])', 'at_end': true});
    expect(imported['ok'], isTrue, reason: '$imported');
    expect(imported['result']['current']['move_number'], 3);
    final board = await call('board', {'node': '1'});
    expect(board['result']['black_stones'], ['E5']);
    expect((board['result']['ascii'] as String).split('\n').first, '    A B C D E F G H J');
    final reused = await call('analysis.run', {'visits': 40});
    expect(reused['result']['reused_existing'], isTrue); // already analysed deeper
    final analysis = await call('analysis.run', {'visits': 400});
    expect(analysis['result']['reused_existing'], isFalse);
    expect(analysis['result']['root']['visits'], 400);
    expect(analysis['result']['root']['score_lead'], -1.5); // white to move, Black ahead
    expect(analysis['result']['candidates'], hasLength(3));
    final played = await call('play', {'moves': 'A1 B1'});
    expect(played['result']['played'], ['A1', 'B1']);
    expect(played['result']['game_modified'], isTrue);
    final illegal = await call('play', {
      'moves': ['E5'],
    });
    expect(illegal['error']['code'], 'illegal_move');
    final marks = await call('mark.add', {'points': 'C3 D4', 'type': 'label'});
    expect([for (final m in marks['result']['added']) m['text']], ['A', 'B']);
    expect(host.mode, modeAnalyze);
  });

  test('demo mode removes what was added', () async {
    await call('sgf.import', {'content': '(;GM[1]SZ[9];B[ee];W[cc])', 'at_end': true});
    await call('demo.start');
    await call('play', {'moves': 'G7 G3'});
    expect(host.game!.root.nodesInTree, hasLength(5));
    final ended = await call('demo.end');
    expect(ended['result']['removed_nodes'], 2);
    expect(host.game!.root.nodesInTree, hasLength(3));
  });
}
