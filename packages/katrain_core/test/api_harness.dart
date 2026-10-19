// Stand-ins for the app and KataGo used by the API tests: a host that keeps the board display state in fields, and an
// engine that answers every query at once.

import 'package:katrain_core/api.dart';
import 'package:katrain_core/katrain_core.dart';

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
  int newGames = 0;

  @override
  AnalysisEngine<GameNode>? get engine => testEngine;
  @override
  bool engineAlive(AnalysisEngine<GameNode> engine) => true;
  @override
  bool engineIdle(AnalysisEngine<GameNode> engine) => true;
  @override
  int engineQueriesRemaining(AnalysisEngine<GameNode> engine) => 0;
  final saved = <String?>[];
  @override
  void saveConfig([String? key]) => saved.add(key);
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
    newGames += 1;
    if (moveTree != null) mode = modeAnalyze;
    pv = null;
    game = Game(this, testEngine, moveTree: moveTree, analyzeFast: analyzeFast, sgfFilename: sgfFilename);
  }

  @override
  void tsumegoFrame(bool ko, int margin) {
    final g = game!;
    if (g.stones.isEmpty) return;
    final (node, region) = tsumegoFrameFromKatrainGame(g, g.komi, g.currentNode.nextPlayer == 'B', ko, margin);
    g.setCurrentNode(node);
    if (region != null) {
      g.setRegionOfInterest([region.$1.$2, region.$1.$1, region.$2.$2, region.$2.$1]);
      g.regionRoot = true;
      node.analyze(g.engines[node.nextPlayer]!, regionOfInterest: g.regionOfInterest, regionRoot: true);
    } else {
      node.analyze(g.engines[node.nextPlayer]!);
    }
  }

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

/// Answers every query at once: the first empty points as candidates, Black slightly ahead. A search of one move
/// (a refinement) scores worse the further its column is from A; the ownership says Black owns everything.
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
    super.requestAnalysis(
      analysisNode,
      callback: callback,
      errorCallback: errorCallback,
      visits: visits,
      analyzeFast: analyzeFast,
      timeLimit: timeLimit,
      findAlternatives: findAlternatives,
      regionOfInterest: regionOfInterest,
      priority: priority,
      ponder: ponder,
      ownership: ownership,
      nextMove: nextMove,
      extraSettings: extraSettings,
      includePolicy: includePolicy,
      reportEvery: reportEvery,
    );
    final g = BaseGame<GameNode>.at(analysisNode);
    final (sx, sy) = analysisNode.boardSize;
    final empty = [
      for (var y = 0; y < sy; y++)
        for (var x = 0; x < sx; x++)
          if (g.board[y][x] < 0) Move(coords: (x, y)).gtp(),
    ];
    final v = visits ?? 100;
    final penalty = nextMove?.coords == null ? 0 : nextMove!.coords!.$1 * 0.5;
    final black = analysisNode.nextPlayer == 'B';
    callback(<String, dynamic>{
      'rootInfo': <String, dynamic>{'visits': v, 'winrate': 0.55, 'scoreLead': 1.5 + (black ? -penalty : penalty)},
      'moveInfos': [
        for (var i = 0; i < 3; i++)
          <String, dynamic>{
            'move': empty[i],
            'order': i,
            'visits': v ~/ (i + 2),
            'winrate': 0.55 - i * 0.05,
            'scoreLead': 1.5 - i,
            'prior': 0.3 / (i + 1),
            'pv': [empty[i], empty[i + 3], empty[i + 6]],
          },
      ],
      'ownership': [for (var i = 0; i < sx * sy; i++) 0.9],
      'policy': [for (var i = 0; i <= sx * sy; i++) 1 / (sx * sy + 1)],
    }, false);
  }
}

/// A host with an empty 19x19 game, and the command handler on it.
(TestHost, CommandHandler) apiFixture(String dataFolder) {
  final settings = defaultConfig();
  final host = TestHost(settings);
  host.testEngine = AnsweringEngine(host, (settings['engine'] as Map).cast<String, dynamic>());
  host.newGame(null);
  return (host, CommandHandler(host, ApiState(), dataFolder: dataFolder));
}
