// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/ai.py: the AI strategies,
// generate_ai_move, ai_rank_estimation and game_report.
//
// KaTrain runs a strategy on a thread that waits for analyses by polling every 10 ms; here generateMove is async and
// polls the same way. KaTrain also calls engine.check_alive(exception_if_dead=True) while waiting, which only reports
// a dead engine (it does not raise); the port's engine reports that itself when the process ends.
// policy_weighted_move, which KaTrain no longer calls, is not ported.

import 'package:collection/collection.dart';

import 'dart:math' as math;

import '../constants.dart';
import '../engine/analysis_engine.dart';
import '../sgf/move.dart';
import '../utils/format.dart';
import '../utils/random.dart';
import '../utils/utils.dart';
import 'game.dart';
import 'game_node.dart';

// Python's max/min of two numbers: the first one wins a tie, and an int stays an int.
num _max(num a, num b) => b > a ? b : a;
num _min(num a, num b) => b < a ? b : a;

String _pct(num x, int digits) => formatPercent(x.toDouble(), digits);
String _fix(num x, int digits) => formatFixed(x.toDouble(), digits);

/// `(i, t)`: the segment of [lst] that [x] falls in and the position within it, clamped to [0, 1].
(int, num) interpIx(List<num> lst, num x) {
  var i = 0;
  while (i + 1 < lst.length - 1 && lst[i + 1] < x) {
    i += 1;
  }
  final t = _max(0, _min(1, (x - lst[i]) / (lst[i + 1] - lst[i])));
  return (i, t);
}

num interp1d(List<(num, num)> lst, num x) {
  final xs = [for (final p in lst) p.$1];
  final ys = [for (final p in lst) p.$2];
  final (i, t) = interpIx(xs, x);
  return (1 - t) * ys[i] + t * ys[i + 1];
}

/// [gridspec] is `[xs, ys, matrix]`, with `matrix[j][i]` the value at `(xs[i], ys[j])`.
num interp2d(List<Object> gridspec, num x, num y) {
  final xs = (gridspec[0] as List).cast<num>();
  final ys = (gridspec[1] as List).cast<num>();
  final matrix = [for (final row in gridspec[2] as List) (row as List).cast<num>()];
  final (i, t) = interpIx(xs, x);
  final (j, s) = interpIx(ys, y);
  return matrix[j][i] * (1 - t) * (1 - s) +
      matrix[j][i + 1] * t * (1 - s) +
      matrix[j + 1][i] * (1 - t) * s +
      matrix[j + 1][i + 1] * t * s;
}

/// The rank (1 = 1 dan, 0 = 1 kyu, negative for weaker kyu ranks) an AI with these settings plays at.
num aiRankEstimation(String strategy, Map<String, dynamic>? settings) {
  if (const [aiDefault, aiHandicap, aiJigo, aiPro].contains(strategy)) return 9;
  if (strategy == aiRank) return 1 - (settings!['kyu_rank'] as num);
  if (strategy == aiHuman) return 1 - (settings!['human_kyu_rank'] as num);
  num pickGrid(List<Object> grid) => interp2d(grid, settings!['pick_frac'] as num, settings['pick_n'] as num);
  final num? elo = switch (strategy) {
    aiWeighted => interp1d(aiWeightedElo, settings!['weaken_fac'] as num),
    aiScoreloss => interp1d(aiScorelossElo, settings!['strength'] as num),
    aiPick => pickGrid(aiPickEloGrid),
    aiLocal => pickGrid(aiLocalEloGrid),
    aiTenuki => pickGrid(aiTenukiEloGrid),
    aiTerritory => pickGrid(aiTerritoryEloGrid),
    aiInfluence => pickGrid(aiInfluenceEloGrid),
    _ => null,
  };
  if (elo != null) {
    final kyu = interp1d(calibratedRankElo, elo);
    return 1 - kyu;
  }
  return aiStrength[strategy]!;
}

/// Statistics for the game report: per player accuracy, complexity, point losses and agreement with the AI, a
/// histogram of moves per evaluation class, and the point loss of every move. [depthFilter] limits the moves to a
/// range of move numbers given as fractions of the board size.
(Map<String, Map<String, double>>, List<Map<String, int>>, Map<String, List<num>>) gameReport(
  Game game,
  List<num> thresholds, {
  List<num>? depthFilter,
}) {
  var cn = game.currentNode;
  var nodes = List.of(cn.nodesFromRoot);
  while (cn.children.isNotEmpty) {
    // main branch
    cn = cn.children[0];
    nodes.add(cn);
  }
  final (x, y) = game.boardSize;
  final depthRange = [
    for (final boardFrac in depthFilter ?? const [0, 1e9]) (boardFrac * x * y).ceil(),
  ];
  nodes = [
    for (final n in nodes)
      if (n.move != null && !n.isRoot && depthRange[0] <= n.depth && n.depth < depthRange[1]) n,
  ];
  final histogram = [
    for (final _ in thresholds) {'B': 0, 'W': 0},
  ];
  final aiTopMoveCount = {'B': 0, 'W': 0};
  final aiApprovedMoveCount = {'B': 0, 'W': 0};
  final playerPtloss = <String, List<num>>{'B': [], 'W': []};
  final weights = <String, List<(num, num)>>{'B': [], 'W': []};

  for (final n in nodes) {
    final lost = n.pointsLost;
    if (lost == null) continue;
    final pointsLost = _max(0, lost);
    final bucket = thresholds.length - 1 - evaluationClass(pointsLost.toDouble(), thresholds);
    playerPtloss[n.player]!.add(pointsLost);
    histogram[bucket][n.player] = histogram[bucket][n.player]! + 1;
    final cands = n.parent!.candidateMoves;
    final filteredCands = [
      for (final d in cands)
        if ((d['order'] as num) < additionalMoveOrder && d.containsKey('prior')) d,
    ];
    final weightedLoss = ([for (final d in filteredCands) _max(d['pointsLost'] as num, 0) * (d['prior'] as num)]).sum;
    final priorSum = ([for (final d in filteredCands) d['prior'] as num]).sum;
    final weight = _min(1.0, weightedLoss / (priorSum == 0 ? 1e-6 : priorSum)); // complexity capped at 1
    // adj_weight between 0.05 - 1, dependent on difficulty and points lost
    final adjWeight = _max(0.05, _min(1.0, _max(weight, pointsLost / 4)));
    weights[n.player]!.add((weight, adjWeight));
    if (n.parent!.analysisComplete) {
      final gtp = n.move!.gtp();
      if (cands[0]['move'] == gtp) aiTopMoveCount[n.player] = aiTopMoveCount[n.player]! + 1;
      final approved = [
        for (final d in filteredCands)
          if (d['order'] == 0 || ((d['pointsLost'] as num) < 0.5 && (d['order'] as num) < 5)) d['move'],
      ];
      if (approved.contains(gtp)) aiApprovedMoveCount[n.player] = aiApprovedMoveCount[n.player]! + 1;
    }
  }

  double sum(Iterable<num> xs) => xs.fold(0.0, (a, b) => a + b);
  final wtLoss = {
    for (final bw in const ['B', 'W'])
      bw:
          sum([for (var i = 0; i < playerPtloss[bw]!.length; i++) playerPtloss[bw]![i] * weights[bw]![i].$2]) /
          _orTiny(sum(weights[bw]!.map((w) => w.$2))),
  };
  final sumStats = {
    for (final bw in const ['B', 'W'])
      bw: playerPtloss[bw]!.isNotEmpty
          ? {
              'accuracy': 100 * math.pow(0.75, wtLoss[bw]!).toDouble(),
              'complexity': sum(weights[bw]!.map((w) => w.$1)) / playerPtloss[bw]!.length,
              'mean_ptloss': sum(playerPtloss[bw]!) / playerPtloss[bw]!.length,
              'weighted_ptloss': wtLoss[bw]!.toDouble(),
              'ai_top_move': aiTopMoveCount[bw]! / playerPtloss[bw]!.length,
              'ai_top5_move': aiApprovedMoveCount[bw]! / playerPtloss[bw]!.length,
            }
          : <String, double>{},
  };
  return (sumStats, histogram, playerPtloss);
}

num _orTiny(num x) => x == 0 ? 1e-6 : x;

String fmtMoves(List<(double, Move)> moves) => [for (final (p, mv) in moves) '${mv.gtp()} (${_pct(p, 2)})'].join(', ');

/// A candidate point for the pick-based strategies: (policy, or policy times weight; weight; x; y).
typedef WeightedCoord = (double, num, int, int);

/// `heapq.nlargest(n, coords)`: the largest tuples first, earlier ones first among equal ones.
List<WeightedCoord> _nlargestCoords(List<WeightedCoord> coords, int n) {
  int cmp(num a, num b) => a < b ? -1 : (a > b ? 1 : 0);
  final indexed = [for (var i = 0; i < coords.length; i++) (i, coords[i])];
  indexed.sort((a, b) {
    final (p, q) = (a.$2, b.$2);
    var c = cmp(q.$1, p.$1);
    if (c == 0) c = cmp(q.$2, p.$2);
    if (c == 0) c = cmp(q.$3, p.$3);
    if (c == 0) c = cmp(q.$4, p.$4);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed.take(n)) e.$2];
}

/// The [n] coords with the largest [key], ties kept in order.
List<WeightedCoord> _nlargestBy(List<WeightedCoord> coords, int n, num Function(WeightedCoord) key) {
  final sorted = List.of(coords);
  stableSortBy(sorted, (c) => key(c), descending: true);
  return sorted.take(n).toList();
}

(List<WeightedCoord>, String) generateInfluenceTerritoryWeights(
  String aiMode,
  Map<String, dynamic> aiSettings,
  List<List<double>> policyGrid,
  (int, int) size,
) {
  final (sx, sy) = size;
  final thrLine = (aiSettings['threshold'] as num) - 1; // zero-based
  final lineWeight = aiSettings['line_weight'] as num;
  final num Function(int, int) weight;
  if (aiMode == aiInfluence) {
    weight = (x, y) => math.pow(
      1 / lineWeight,
      _max(0, thrLine - math.min(sx - 1 - x, x)) + _max(0, thrLine - math.min(sy - 1 - y, y)),
    );
  } else {
    weight = (x, y) => math.pow(1 / lineWeight, _max(0, [sx - 1 - x, x, sy - 1 - y, y].reduce(math.min) - thrLine));
  }
  final weightedCoords = <WeightedCoord>[
    for (var x = 0; x < sx; x++)
      for (var y = 0; y < sy; y++)
        if (policyGrid[y][x] > 0) (policyGrid[y][x] * weight(x, y), weight(x, y), x, y),
  ];
  final aiThoughts =
      'Generated weights for $aiMode according to weight factor $lineWeight and distance from '
      '${thrLine + 1}th line. ';
  return (weightedCoords, aiThoughts);
}

(List<WeightedCoord>, String) generateLocalTenukiWeights(
  String aiMode,
  Map<String, dynamic> aiSettings,
  List<List<double>> policyGrid,
  GameNode cn,
  (int, int) size,
) {
  final (sx, sy) = size;
  final variance = math.pow(aiSettings['stddev'] as num, 2);
  final (mx, my) = cn.move!.coords!;
  var weightedCoords = <WeightedCoord>[
    for (var x = 0; x < sx; x++)
      for (var y = 0; y < sy; y++)
        if (policyGrid[y][x] > 0)
          (policyGrid[y][x], math.exp(-0.5 * ((x - mx) * (x - mx) + (y - my) * (y - my)) / variance), x, y),
  ];
  var aiThoughts = 'Generated weights based on one minus gaussian with variance $variance around coordinates $mx,$my. ';
  if (aiMode == aiTenuki) {
    weightedCoords = [for (final (p, w, x, y) in weightedCoords) (p, 1 - w, x, y)];
    aiThoughts = 'Generated weights based on one minus gaussian with variance $variance around coordinates $mx,$my. ';
  }
  return (weightedCoords, aiThoughts);
}

/// The analysis a strategy was waiting for was thrown away, so there is nothing left to wait for.
class AnalysisDiscardedException implements Exception {
  final String message;
  AnalysisDiscardedException(this.message);

  @override
  String toString() => message;
}

/// Base strategy class for AI move generation.
abstract class AIStrategy {
  final Game game;
  final Map<String, dynamic> settings;
  final GameNode cn;
  final String strategyName;

  /// A new game or an engine restart discards outstanding queries without calling back, so remember which
  /// generation our work belongs to and stop waiting once the engine moves past it.
  late final Map<String, int> queryGenerations;

  static const _pollInterval = Duration(milliseconds: 10);

  AIStrategy(this.game, this.settings, this.strategyName) : cn = game.currentNode {
    queryGenerations = {for (final e in game.engines.entries) e.key: e.value.queryGeneration};
    log('Initializing $strategyName with settings: $settings', outputDebug);
  }

  void log(String message, int level) => game.katrain.log(message, level);

  /// Generate a move and explanation.
  Future<(Move, String)> generateMove();

  /// Abort if the engine threw our queries away -- nothing will ever call back for them.
  void raiseIfDiscarded(AnalysisEngine<GameNode> engine, String player) {
    if (engine.queryGeneration != (queryGenerations[player] ?? engine.queryGeneration)) {
      throw AnalysisDiscardedException('analysis for $strategyName discarded by a new game or an engine restart');
    }
  }

  /// Helper to request additional analysis with custom settings.
  Future<Map<String, dynamic>?> requestAnalysis(Map<String, dynamic> extraSettings) async {
    log('[$strategyName] Requesting analysis with settings: $extraSettings', outputDebug);
    var error = false;
    Map<String, dynamic>? analysis;
    final engine = game.engines[cn.player]!;
    engine.requestAnalysis(
      cn,
      callback: (a, partialResult) {
        if (!partialResult) {
          analysis = a;
          log('[$strategyName] Analysis received', outputDebug);
        }
      },
      errorCallback: (a) {
        log('[$strategyName] Error in additional analysis query: $a', outputError);
        error = true;
      },
      priority: priorityExtraAiQuery,
      ownership: false,
      extraSettings: extraSettings,
    );
    log('[$strategyName] Waiting for analysis to complete...', outputDebug);
    while (true) {
      raiseIfDiscarded(engine, cn.player);
      if (error || (analysis?.isNotEmpty ?? false)) break;
      await Future<void>.delayed(_pollInterval);
    }
    if (analysis?.isNotEmpty ?? false) log('[$strategyName] Analysis completed successfully', outputDebug);
    return analysis;
  }

  /// Wait for the analysis to complete.
  Future<void> waitForAnalysis() async {
    log('[$strategyName] Waiting for regular analysis to complete...', outputDebug);
    final engine = game.engines[cn.nextPlayer]!;
    while (!cn.analysisComplete) {
      raiseIfDiscarded(engine, cn.nextPlayer);
      await Future<void>.delayed(_pollInterval);
    }
    log('[$strategyName] Regular analysis completed', outputDebug);
  }

  /// Check if we should play the top policy move, regardless of strategy.
  (Move?, String) shouldPlayTopMove(
    List<(double, Move)> policyMoves,
    bool top5Pass, {
    num override = 0.0,
    num overridetwo = 1.0,
  }) {
    final topPolicyMove = policyMoves[0].$2;
    log(
      '[$strategyName] Checking if should play top move. Top move: ${topPolicyMove.gtp()} '
      '(${_pct(policyMoves[0].$1, 2)})',
      outputDebug,
    );
    log(
      '[$strategyName] Override thresholds: single=${_pct(override, 2)}, combined=${_pct(overridetwo, 2)}',
      outputDebug,
    );
    log('[$strategyName] Top 5 pass: $top5Pass', outputDebug);

    if (top5Pass) {
      log('[$strategyName] Playing top move because pass is in top 5', outputDebug);
      return (topPolicyMove, 'Playing top one because one of them is pass.');
    }
    if (policyMoves[0].$1 > override) {
      log(
        '[$strategyName] Playing top move because weight ${_pct(policyMoves[0].$1, 2)} > override '
        '${_pct(override, 2)}',
        outputDebug,
      );
      return (topPolicyMove, 'Top policy move has weight > ${_pct(override, 1)}, so overriding other strategies.');
    }
    if (policyMoves[0].$1 + policyMoves[1].$1 > overridetwo) {
      final combined = policyMoves[0].$1 + policyMoves[1].$1;
      log(
        '[$strategyName] Playing top move because combined weight ${_pct(combined, 2)} > overridetwo '
        '${_pct(overridetwo, 2)}',
        outputDebug,
      );
      return (
        topPolicyMove,
        'Top two policy moves have cumulative weight > ${_pct(overridetwo, 1)}, so overriding other strategies.',
      );
    }
    log('[$strategyName] No override condition met, continuing with strategy', outputDebug);
    return (null, '');
  }

  // The policy based strategies start the same way: the ranking and the pass policy.
  (List<(double, Move)>, double) _policyMovesWithLogs() {
    final policyMoves = cn.policyRanking!;
    final passPolicy = cn.policy!.last;
    log('[$strategyName] Got ${policyMoves.length} policy moves', outputDebug);
    return (policyMoves, passPolicy);
  }

  void _logTopPolicyMoves(List<(double, Move)> policyMoves, double passPolicy) {
    log('[$strategyName] Top 5 policy moves:', outputDebug);
    var i = 0;
    for (final (prob, move) in policyMoves.take(5)) {
      log('[$strategyName] #${i + 1}: ${move.gtp()} - ${_pct(prob, 2)}', outputDebug);
      i += 1;
    }
    log('[$strategyName] Pass policy: ${_pct(passPolicy, 2)}', outputDebug);
  }

  bool get _hasPolicy => cn.policy?.isNotEmpty ?? false;
}

/// Default strategy - simply plays the top move from the engine.
class DefaultStrategy extends AIStrategy {
  DefaultStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'DefaultStrategy');

  @override
  Future<(Move, String)> generateMove() async {
    log('[DefaultStrategy] Starting move generation', outputDebug);
    await waitForAnalysis();
    final candidateMoves = cn.candidateMoves;
    log('[DefaultStrategy] Analysis found ${candidateMoves.length} candidate moves', outputDebug);
    final Move topCand;
    if (candidateMoves.isEmpty) {
      log('[DefaultStrategy] No candidate moves found, will play pass', outputDebug);
      topCand = Move(player: cn.nextPlayer); // KaTrain's Move(is_pass=True) fails here
    } else {
      final topMoveData = candidateMoves[0];
      topCand = Move.fromGtp(topMoveData['move'] as String, player: cn.nextPlayer);
      log('[DefaultStrategy] Top move: ${topCand.gtp()} with stats: $topMoveData', outputDebug);
    }
    final aiThoughts =
        'Default strategy found ${candidateMoves.length} moves returned from the engine and chose ${topCand.gtp()} '
        'as top move';
    log('[DefaultStrategy] Final decision: ${topCand.gtp()}', outputDebug);
    return (topCand, aiThoughts);
  }
}

/// Handicap strategy - uses playoutDoublingAdvantage to analyze the position.
class HandicapStrategy extends AIStrategy {
  HandicapStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'HandicapStrategy');

  @override
  Future<(Move, String)> generateMove() async {
    log('[HandicapStrategy] Starting move generation', outputDebug);
    // Calculate PDA (Playout Doubling Advantage)
    var pda = settings['pda'] as num;
    log('[HandicapStrategy] Initial PDA from settings: $pda', outputDebug);
    if (settings['automatic'] == true) {
      final nHandicaps = (game.root.getListProperty('AB') ?? const []).length;
      const moveValue = 14; // could be rules dependent
      final bStonesAdvantage = math.max(nHandicaps - 1, 0) - (cn.komi - moveValue / 2) / moveValue;
      // max PDA at 8 stone adv, normal 9 stone game is 8.46
      pda = _min(3, _max(-3, -bStonesAdvantage * (3 / 8)));
      log('[HandicapStrategy] Automatic PDA calculation:', outputDebug);
      log('[HandicapStrategy] - Handicap stones: $nHandicaps', outputDebug);
      log('[HandicapStrategy] - Komi: ${cn.komi}', outputDebug);
      log('[HandicapStrategy] - Stone advantage: $bStonesAdvantage', outputDebug);
      log('[HandicapStrategy] - Calculated PDA: $pda', outputDebug);
    }
    log('[HandicapStrategy] Requesting analysis with PDA=$pda', outputDebug);
    final handicapAnalysis = await requestAnalysis({
      'playoutDoublingAdvantage': pda,
      'playoutDoublingAdvantagePla': 'BLACK',
    });
    if (handicapAnalysis == null || handicapAnalysis.isEmpty) {
      log('[HandicapStrategy] Error getting handicap-based move, falling back to DefaultStrategy', outputError);
      return DefaultStrategy(game, settings).generateMove();
    }
    await waitForAnalysis();
    final candidateMoves = (handicapAnalysis['moveInfos'] as List).cast<Map<String, dynamic>>();
    log('[HandicapStrategy] Analysis returned ${candidateMoves.length} candidate moves', outputDebug);
    final topCand = Move.fromGtp(candidateMoves[0]['move'] as String, player: cn.nextPlayer);
    final rootInfo = handicapAnalysis['rootInfo'] as Map<String, dynamic>;
    log('[HandicapStrategy] Top move: ${topCand.gtp()}', outputDebug);
    log('[HandicapStrategy] Score lead: ${rootInfo['scoreLead']}', outputDebug);
    log('[HandicapStrategy] Win rate: ${rootInfo['winrate']}', outputDebug);
    final aiThoughts =
        'Handicap strategy found ${candidateMoves.length} moves returned from the engine and chose ${topCand.gtp()} '
        'as top move. PDA based score ${cn.formatScore((rootInfo['scoreLead'] as num).toDouble())} and win rate '
        '${cn.formatWinrate((rootInfo['winrate'] as num).toDouble())}';
    log('[HandicapStrategy] Final decision: ${topCand.gtp()}', outputDebug);
    return (topCand, aiThoughts);
  }
}

/// Antimirror strategy - uses antiMirror to analyze the position.
class AntimirrorStrategy extends AIStrategy {
  AntimirrorStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'AntimirrorStrategy');

  @override
  Future<(Move, String)> generateMove() async {
    log('[AntimirrorStrategy] Starting move generation', outputDebug);
    log('[AntimirrorStrategy] Requesting analysis with antiMirror=True', outputDebug);
    final antimirrorAnalysis = await requestAnalysis({'antiMirror': true});
    if (antimirrorAnalysis == null || antimirrorAnalysis.isEmpty) {
      log('[AntimirrorStrategy] Error getting antimirror move, falling back to DefaultStrategy', outputError);
      return DefaultStrategy(game, settings).generateMove();
    }
    await waitForAnalysis();
    final candidateMoves = (antimirrorAnalysis['moveInfos'] as List).cast<Map<String, dynamic>>();
    log('[AntimirrorStrategy] Analysis returned ${candidateMoves.length} candidate moves', outputDebug);
    final topCand = Move.fromGtp(candidateMoves[0]['move'] as String, player: cn.nextPlayer);
    final rootInfo = antimirrorAnalysis['rootInfo'] as Map<String, dynamic>;
    log('[AntimirrorStrategy] Top move: ${topCand.gtp()}', outputDebug);
    log('[AntimirrorStrategy] Score lead: ${rootInfo['scoreLead']}', outputDebug);
    log('[AntimirrorStrategy] Win rate: ${rootInfo['winrate']}', outputDebug);
    // Log the top 3 moves for comparison
    var i = 0;
    for (final moveData in candidateMoves.take(3)) {
      final move = Move.fromGtp(moveData['move'] as String, player: cn.nextPlayer);
      final visits = moveData.containsKey('visits') ? moveData['visits'] : 'N/A';
      final lost = moveData.containsKey('pointsLost') ? moveData['pointsLost'] : 'N/A';
      log('[AntimirrorStrategy] Move #${i + 1}: ${move.gtp()} - visits: $visits, points lost: $lost', outputDebug);
      i += 1;
    }
    final aiThoughts =
        'AntiMirror strategy found ${candidateMoves.length} moves returned from the engine and chose '
        '${topCand.gtp()} as top move. antiMirror based score '
        '${cn.formatScore((rootInfo['scoreLead'] as num).toDouble())} and win rate '
        '${cn.formatWinrate((rootInfo['winrate'] as num).toDouble())}';
    log('[AntimirrorStrategy] Final decision: ${topCand.gtp()}', outputDebug);
    return (topCand, aiThoughts);
  }
}

/// Jigo strategy - aims for a specific score difference.
class JigoStrategy extends AIStrategy {
  JigoStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'JigoStrategy');

  @override
  Future<(Move, String)> generateMove() async {
    log('[JigoStrategy] Starting move generation', outputDebug);
    await waitForAnalysis();
    final candidateMoves = cn.candidateMoves;
    log('[JigoStrategy] Analysis found ${candidateMoves.length} candidate moves', outputDebug);
    if (candidateMoves.isEmpty) {
      log('[JigoStrategy] No candidate moves found, will play pass', outputDebug);
      return (Move(player: cn.nextPlayer), 'No candidate moves found, passing');
    }
    final topCand = Move.fromGtp(candidateMoves[0]['move'] as String, player: cn.nextPlayer);
    log('[JigoStrategy] Top engine move would be: ${topCand.gtp()}', outputDebug);
    final sign = GameNode.playerSign(cn.nextPlayer);
    log('[JigoStrategy] Player sign: $sign', outputDebug);
    final targetScore = settings['target_score'] as num;
    log('[JigoStrategy] Target score: $targetScore', outputDebug);
    num diff(Map<String, dynamic> d) => (sign * (d['scoreLead'] as num) - targetScore).abs();
    log('[JigoStrategy] Candidate move score leads:', outputDebug);
    for (final moveData in candidateMoves.take(5)) {
      final move = Move.fromGtp(moveData['move'] as String, player: cn.nextPlayer);
      log(
        '[JigoStrategy] - ${move.gtp()}: scoreLead=${moveData['scoreLead']}, diff from target='
        '${diff(moveData)}',
        outputDebug,
      );
    }
    // Find the move that gives a score closest to the target
    var jigoMove = candidateMoves[0];
    for (final d in candidateMoves.skip(1)) {
      if (diff(d) < diff(jigoMove)) jigoMove = d;
    }
    final aimove = Move.fromGtp(jigoMove['move'] as String, player: cn.nextPlayer);
    log('[JigoStrategy] Selected move: ${aimove.gtp()}', outputDebug);
    log('[JigoStrategy] Selected move score lead: ${jigoMove['scoreLead']}', outputDebug);
    log('[JigoStrategy] Distance from target: ${diff(jigoMove)}', outputDebug);
    final aiThoughts =
        'Jigo strategy found ${candidateMoves.length} candidate moves (best ${topCand.gtp()}) and chose '
        '${aimove.gtp()} as closest to 0.5 point win';
    log('[JigoStrategy] Final decision: ${aimove.gtp()}', outputDebug);
    return (aimove, aiThoughts);
  }
}

/// ScoreLoss strategy - weights moves based on point loss.
class ScoreLossStrategy extends AIStrategy {
  ScoreLossStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'ScoreLossStrategy');

  @override
  Future<(Move, String)> generateMove() async {
    log('[ScoreLossStrategy] Starting move generation', outputDebug);
    await waitForAnalysis();
    final candidateMoves = cn.candidateMoves;
    log('[ScoreLossStrategy] Analysis found ${candidateMoves.length} candidate moves', outputDebug);
    if (candidateMoves.isEmpty) {
      log('[ScoreLossStrategy] No candidate moves found, will play pass', outputDebug);
      return (Move(player: cn.nextPlayer), 'No candidate moves found, passing');
    }
    final topCand = Move.fromGtp(candidateMoves[0]['move'] as String, player: cn.nextPlayer);
    log('[ScoreLossStrategy] Top engine move would be: ${topCand.gtp()}', outputDebug);
    if (topCand.isPass) {
      log('[ScoreLossStrategy] Top move is pass, so passing regardless of strategy', outputDebug);
      return (topCand, 'Top move is pass, so passing regardless of strategy.');
    }
    final c = settings['strength'] as num;
    log('[ScoreLossStrategy] Strength parameter: $c', outputDebug);
    log('[ScoreLossStrategy] Calculating weights for candidate moves', outputDebug);
    final moves = <(num, double, Move)>[];
    for (var i = 0; i < candidateMoves.length; i++) {
      final d = candidateMoves[i];
      final move = Move.fromGtp(d['move'] as String, player: cn.nextPlayer);
      final pointsLost = d['pointsLost'] as num;
      final weight = math.exp(_min(200, -c * _max(0, pointsLost)));
      log(
        '[ScoreLossStrategy] Move ${i + 1}: ${move.gtp()} - Points lost: ${_fix(pointsLost, 2)}, Weight: '
        '${_fix(weight, 6)}',
        outputDebug,
      );
      moves.add((pointsLost, weight, move));
    }
    log('[ScoreLossStrategy] Selecting move with weighted selection', outputDebug);
    final topmove = weightedSelectionWithoutReplacement(moves, 1, (m) => m.$2, random)[0];
    final aimove = topmove.$3;
    log('[ScoreLossStrategy] Selected move: ${aimove.gtp()}', outputDebug);
    log('[ScoreLossStrategy] Selected move points lost: ${_fix(topmove.$1, 2)}', outputDebug);
    log('[ScoreLossStrategy] Selected move weight: ${_fix(topmove.$2, 6)}', outputDebug);
    final aiThoughts =
        'ScoreLoss strategy found ${candidateMoves.length} candidate moves (best ${topCand.gtp()}) and chose '
        '${aimove.gtp()} (weight ${_fix(topmove.$2, 3)}, point loss ${_fix(topmove.$1, 1)}) based on score weights.';
    log('[ScoreLossStrategy] Final decision: ${aimove.gtp()}', outputDebug);
    return (aimove, aiThoughts);
  }
}

/// A candidate for the ownership strategies: the move, its own and the opponent's settledness, whether it is an
/// attachment or a tenuki, and the candidate move data.
typedef SettlednessMove = (Move, num, num, bool, bool, Map<String, dynamic>);

/// Base class for ownership-based strategies.
abstract class OwnershipBaseStrategy extends AIStrategy {
  OwnershipBaseStrategy(super.game, super.settings, super.strategyName);

  /// Calculate settledness for Simple Ownership strategy.
  num settledness(Map<String, dynamic> d, int playerSign, String player) {
    final ownershipSum = ([
      for (final o in (d['ownership'] as List).cast<num>())
        if (playerSign * o > 0) o.abs(),
    ]).sum;
    log('[$strategyName] Calculating settledness for $player, sign=$playerSign: ${_fix(ownershipSum, 2)}', outputDebug);
    return ownershipSum;
  }

  /// Check if a move is an attachment.
  bool isAttachment(Move move) {
    if (move.isPass) return false;
    final stonesWithPlayer = {for (final s in game.stones) (s.coords!.$1, s.coords!.$2, s.player)};
    final (mx, my) = move.coords!;
    var attachOpponentStones = 0;
    for (final dx in const [-1, 0, 1]) {
      for (final dy in const [-1, 0, 1]) {
        if (dx.abs() + dy.abs() == 1 && stonesWithPlayer.contains((mx + dx, my + dy, cn.player))) {
          attachOpponentStones += 1;
        }
      }
    }
    var nearbyOwnStones = 0;
    for (var dx = -2; dx <= 2; dx++) {
      for (var dy = -2; dy <= 2; dy++) {
        // allows clamps/jumps
        if (dx.abs() + dy.abs() <= 2 && stonesWithPlayer.contains((mx + dx, my + dy, cn.nextPlayer))) {
          nearbyOwnStones += 1;
        }
      }
    }
    final isAttach = attachOpponentStones >= 1 && nearbyOwnStones == 0;
    log(
      '[$strategyName] Is move ${move.gtp()} an attachment? $isAttach (opponent stones: '
      '$attachOpponentStones, own stones: $nearbyOwnStones)',
      outputDebug,
    );
    return isAttach;
  }

  /// Check if a move is a tenuki (far from previous moves).
  bool isTenuki(Move move) {
    if (move.isPass) return false;
    int distance(GameNode node) {
      final (lx, ly) = node.move!.coords!;
      final (cx, cy) = move.coords!;
      return math.max((lx - cx).abs(), (ly - cy).abs());
    }

    final nodes = [cn, cn.parent];
    final result = !nodes.any((node) => node == null || node.move == null || node.move!.isPass || distance(node) < 5);
    final distances = [
      for (final node in nodes)
        if (node != null && node.move != null && !node.move!.isPass) distance(node),
    ];
    if (distances.isNotEmpty) {
      log('[$strategyName] Is move ${move.gtp()} a tenuki? $result (distances: $distances)', outputDebug);
    } else {
      log('[$strategyName] Is move ${move.gtp()} a tenuki? $result (no valid previous moves)', outputDebug);
    }
    return result;
  }

  /// Get moves with ownership and settledness information.
  List<SettlednessMove> getMovesWithSettledness() {
    log('[$strategyName] Getting moves with settledness information', outputDebug);
    final nextPlayerSign = GameNode.playerSign(cn.nextPlayer);
    final candidateMoves = cn.candidateMoves;
    final minVisits = settings.containsKey('min_visits') ? settings['min_visits'] : 1;
    log('[$strategyName] Processing ${candidateMoves.length} candidate moves', outputDebug);
    log('[$strategyName] Settings: max_points_lost=${settings['max_points_lost']}, min_visits=$minVisits', outputDebug);
    log(
      '[$strategyName] Penalties: attach=${settings['attach_penalty']}, tenuki=${settings['tenuki_penalty']}',
      outputDebug,
    );
    log(
      '[$strategyName] Weights: settled=${settings['settled_weight']}, opponent_fac='
      '${settings['opponent_fac']}',
      outputDebug,
    );
    final movesData = <(SettlednessMove, num)>[];
    for (final d in candidateMoves) {
      if (!d.containsKey('pointsLost')) {
        log('[$strategyName] Move ${d['move']} has no pointsLost, skipping', outputDebug);
        continue;
      }
      final pointsLost = d['pointsLost'] as num;
      if (pointsLost >= (settings['max_points_lost'] as num)) {
        log(
          '[$strategyName] Move ${d['move']} has pointsLost=$pointsLost, which exceeds max_points_lost='
          '${settings['max_points_lost']}, skipping',
          outputDebug,
        );
        continue;
      }
      if (!d.containsKey('ownership')) {
        log('[$strategyName] Move ${d['move']} has no ownership data, skipping', outputDebug);
        continue;
      }
      if (!((d['order'] as num) <= 1 || (d['visits'] as num) >= (minVisits as num))) {
        final visits = d.containsKey('visits') ? d['visits'] : 'N/A';
        log(
          "[$strategyName] Move ${d['move']} has order=${d['order']} and visits=$visits, doesn't "
          'meet criteria, skipping',
          outputDebug,
        );
        continue;
      }
      final move = Move.fromGtp(d['move'] as String, player: cn.nextPlayer);
      if (move.isPass && pointsLost > 0.75) {
        log('[$strategyName] Move ${move.gtp()} is pass with high point loss ($pointsLost), skipping', outputDebug);
        continue;
      }
      // Calculate metrics
      final ownSettledness = settledness(d, nextPlayerSign, cn.nextPlayer);
      final oppSettledness = settledness(d, -nextPlayerSign, cn.player);
      final isAttach = isAttachment(move);
      final isTenukiMove = isTenuki(move);
      // Calculate total score for sorting
      final score =
          pointsLost +
          (settings['attach_penalty'] as num) * (isAttach ? 1 : 0) +
          (settings['tenuki_penalty'] as num) * (isTenukiMove ? 1 : 0) -
          (settings['settled_weight'] as num) * (ownSettledness + (settings['opponent_fac'] as num) * oppSettledness);
      log(
        '[$strategyName] Move ${move.gtp()}: points_lost=${_fix(pointsLost, 2)}, own_settled='
        '${_fix(ownSettledness, 2)}, opp_settled=${_fix(oppSettledness, 2)}, attach=$isAttach, tenuki='
        '$isTenukiMove, score=${_fix(score, 2)}',
        outputDebug,
      );
      movesData.add(((move, ownSettledness, oppSettledness, isAttach, isTenukiMove, d), score));
    }
    // Sort moves by score
    final sortedMoves = List.of(movesData);
    stableSortBy(sortedMoves, (t) => t.$2);
    log('[$strategyName] Found ${sortedMoves.length} valid moves with settledness data', outputDebug);
    if (sortedMoves.isNotEmpty) {
      log(
        '[$strategyName] Top move after sorting: ${sortedMoves[0].$1.$1.gtp()} with score ${_fix(sortedMoves[0].$2, 2)}',
        outputDebug,
      );
    }
    return [for (final m in sortedMoves) m.$1];
  }

  /// The shared move choice of the ownership strategies; [label] is the strategy constant in the thoughts.
  Future<(Move, String)> _generateOwnershipMove(String label, {void Function()? beforeSettledness}) async {
    final name = strategyName;
    log('[$name] Starting move generation', outputDebug);
    await waitForAnalysis();
    final candidateMoves = cn.candidateMoves;
    log('[$name] Analysis found ${candidateMoves.length} candidate moves', outputDebug);
    if (candidateMoves.isEmpty) {
      log('[$name] No candidate moves found, will play pass', outputDebug);
      return (Move(player: cn.nextPlayer), 'No candidate moves found, passing');
    }
    final topCand = Move.fromGtp(candidateMoves[0]['move'] as String, player: cn.nextPlayer);
    log('[$name] Top engine move would be: ${topCand.gtp()}', outputDebug);
    if (topCand.isPass) {
      log('[$name] Top move is pass, so passing regardless of strategy', outputDebug);
      return (topCand, 'Top move is pass, so passing regardless of strategy.');
    }
    beforeSettledness?.call();
    log('[$name] Getting moves with settledness info', outputDebug);
    final movesWithSettledness = getMovesWithSettledness();
    if (movesWithSettledness.isEmpty) {
      const errorMsg = 'No moves found - are you using an older KataGo with no per-move ownership info?';
      log('[$name] Error: $errorMsg', outputError);
      throw Exception(errorMsg);
    }
    log('[$name] Found ${movesWithSettledness.length} moves with settledness info', outputDebug);
    log('[$name] Top 5 candidates:', outputDebug);
    final top5 = movesWithSettledness.take(5).toList();
    for (var i = 0; i < top5.length; i++) {
      final (move, settled, oppsettled, isattach, istenuki, d) = top5[i];
      log(
        '[$name] #${i + 1}: ${move.gtp()} - pt_lost: ${_fix(d['pointsLost'] as num, 1)}, visits: '
        '${d.containsKey('visits') ? d['visits'] : 'N/A'}, settledness: ${_fix(settled, 1)}, opp_settled: '
        '${_fix(oppsettled, 1)}, attach: $isattach, tenuki: $istenuki',
        outputDebug,
      );
    }
    final cands = [
      for (final (move, settled, oppsettled, isattach, istenuki, d) in top5)
        '${move.gtp()} (${_fix(d['pointsLost'] as num, 1)} pt lost, '
            '${d.containsKey('visits') ? d['visits'] : 'N/A'} visits, ${_fix(settled, 1)} settledness, '
            '${_fix(oppsettled, 1)} opponent settledness${isattach ? ', attachment' : ''}'
            '${istenuki ? ', tenuki' : ''})',
    ];
    final aiThoughts = '$label strategy. Top 5 Candidates ${cands.join(', ')} ';
    final aimove = movesWithSettledness[0].$1;
    log('[$name] Selected move: ${aimove.gtp()}', outputDebug);
    log('[$name] Final decision: ${aimove.gtp()}', outputDebug);
    return (aimove, aiThoughts);
  }
}

/// Simple Ownership strategy - weights moves based on territory control.
class SimpleOwnershipStrategy extends OwnershipBaseStrategy {
  SimpleOwnershipStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'SimpleOwnershipStrategy');

  @override
  Future<(Move, String)> generateMove() => _generateOwnershipMove(aiSimpleOwnership);
}

/// Settle Stones strategy - focuses on settled stones.
class SettleStonesStrategy extends OwnershipBaseStrategy {
  SettleStonesStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'SettleStonesStrategy');

  /// Calculate settledness for Settle Stones strategy.
  @override
  num settledness(Map<String, dynamic> d, int playerSign, String player) {
    final (sizeX, sizeY) = game.boardSize;
    final ownershipGrid = varToGrid((d['ownership'] as List).cast<num>(), (sizeX, sizeY));
    // Sum the absolute ownership values of the player's stones; the grid is indexed [y][x]
    final stoneOwnershipValues = [
      for (final s in game.stones)
        if (s.player == player) ownershipGrid[s.coords!.$2][s.coords!.$1].abs(),
    ];
    final totalSettledness = (stoneOwnershipValues).sum;
    log('[SettleStonesStrategy] Calculating settledness for $player, sign=$playerSign', outputDebug);
    log('[SettleStonesStrategy] Number of stones considered: ${stoneOwnershipValues.length}', outputDebug);
    log('[SettleStonesStrategy] Total settledness: ${_fix(totalSettledness, 2)}', outputDebug);
    if (stoneOwnershipValues.isNotEmpty) {
      log('[SettleStonesStrategy] Min stone ownership: ${_fix(stoneOwnershipValues.reduce(_min), 2)}', outputDebug);
      log('[SettleStonesStrategy] Max stone ownership: ${_fix(stoneOwnershipValues.reduce(_max), 2)}', outputDebug);
      log(
        '[SettleStonesStrategy] Avg stone ownership: ${_fix(totalSettledness / stoneOwnershipValues.length, 2)}',
        outputDebug,
      );
    }
    return totalSettledness;
  }

  @override
  Future<(Move, String)> generateMove() => _generateOwnershipMove(
    aiSettleStones,
    beforeSettledness: () {
      final blackStones = game.stones.where((s) => s.player == 'B').length;
      final whiteStones = game.stones.where((s) => s.player == 'W').length;
      log('[SettleStonesStrategy] Stones on board: B=$blackStones, W=$whiteStones', outputDebug);
    },
  );
}

/// Policy strategy - plays the top move suggested by policy network.
class PolicyStrategy extends AIStrategy {
  PolicyStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'PolicyStrategy');

  @override
  Future<(Move, String)> generateMove() async {
    log('[PolicyStrategy] Starting move generation', outputDebug);
    await waitForAnalysis();
    if (!_hasPolicy) {
      log('[PolicyStrategy] No policy data available, falling back to DefaultStrategy', outputDebug);
      return DefaultStrategy(game, settings).generateMove();
    }
    final (policyMoves, passPolicy) = _policyMovesWithLogs();
    final openingMoves = settings.containsKey('opening_moves') ? settings['opening_moves'] : 0;
    log('[PolicyStrategy] Current move depth: ${cn.depth}', outputDebug);
    log('[PolicyStrategy] Opening moves setting: $openingMoves', outputDebug);
    _logTopPolicyMoves(policyMoves, passPolicy);
    final top5Pass = policyMoves.take(5).any((m) => m.$2.isPass);
    log('[PolicyStrategy] Pass in top 5: $top5Pass', outputDebug);
    if (cn.depth <= (openingMoves as num)) {
      log('[PolicyStrategy] In opening phase, using WeightedStrategy instead', outputDebug);
      final weightedSettings = <String, dynamic>{'pick_override': 0.9, 'weaken_fac': 1, 'lower_bound': 0.02};
      log('[PolicyStrategy] Weighted settings: $weightedSettings', outputDebug);
      return WeightedStrategy(game, weightedSettings).generateMove();
    }
    if (top5Pass) {
      final aimove = policyMoves[0].$2;
      log('[PolicyStrategy] Playing top move ${aimove.gtp()} because pass in top 5', outputDebug);
      return (aimove, 'Playing top one because one of them is pass.');
    }
    final aimove = policyMoves[0].$2;
    log(
      '[PolicyStrategy] Playing top policy move ${aimove.gtp()} with probability ${_pct(policyMoves[0].$1, 2)}',
      outputDebug,
    );
    final aiThoughts = 'Playing top policy move ${aimove.gtp()}.';
    log('[PolicyStrategy] Final decision: ${aimove.gtp()}', outputDebug);
    return (aimove, aiThoughts);
  }
}

/// Weighted strategy - weights moves based on policy and a weakening factor.
class WeightedStrategy extends AIStrategy {
  WeightedStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'WeightedStrategy');

  @override
  Future<(Move, String)> generateMove() async {
    log('[WeightedStrategy] Starting move generation', outputDebug);
    await waitForAnalysis();
    if (!_hasPolicy) {
      log('[WeightedStrategy] No policy data available, falling back to DefaultStrategy', outputDebug);
      return DefaultStrategy(game, settings).generateMove();
    }
    final (policyMoves, passPolicy) = _policyMovesWithLogs();
    _logTopPolicyMoves(policyMoves, passPolicy);
    final top5Pass = policyMoves.take(5).any((m) => m.$2.isPass);
    log('[WeightedStrategy] Pass in top 5: $top5Pass', outputDebug);
    final override = (settings.containsKey('pick_override') ? settings['pick_override'] : 0.0) as num;
    log('[WeightedStrategy] Override threshold: ${_pct(override, 2)}', outputDebug);
    final (overrideMove, overrideThoughts) = shouldPlayTopMove(policyMoves, top5Pass, override: override);
    if (overrideMove != null) {
      log('[WeightedStrategy] Using override move: ${overrideMove.gtp()}', outputDebug);
      return (overrideMove, overrideThoughts);
    }
    final lowerBound = (settings.containsKey('lower_bound') ? settings['lower_bound'] : 0.02) as num;
    final weakenFac = (settings.containsKey('weaken_fac') ? settings['weaken_fac'] : 1.0) as num;
    log(
      '[WeightedStrategy] Using weighted selection with lower_bound=${_pct(lowerBound, 2)}, weaken_fac='
      '$weakenFac',
      outputDebug,
    );
    final weightedCoords = [
      for (final (pv, move) in policyMoves)
        if (pv > lowerBound && !move.isPass) (pv, math.pow(pv, 1 / weakenFac).toDouble(), move),
    ];
    log('[WeightedStrategy] Found ${weightedCoords.length} moves above lower bound', outputDebug);
    final Move move;
    final String aiThoughts;
    if (weightedCoords.isNotEmpty) {
      log('[WeightedStrategy] Performing weighted selection', outputDebug);
      final top = weightedSelectionWithoutReplacement(weightedCoords, 1, (c) => c.$2, random)[0];
      move = top.$3;
      final prob = top.$1;
      log('[WeightedStrategy] Selected move ${move.gtp()} with probability ${_pct(prob, 2)}', outputDebug);
      aiThoughts =
          'Playing policy-weighted random move ${move.gtp()} (${_pct(prob, 1)}) from ${weightedCoords.length} moves '
          'above lower_bound of ${_pct(lowerBound, 1)}.';
    } else {
      move = policyMoves[0].$2;
      log('[WeightedStrategy] No moves above lower bound, playing top policy move ${move.gtp()}', outputDebug);
      aiThoughts = 'Playing top policy move because no non-pass move > above lower_bound of ${_pct(lowerBound, 1)}.';
    }
    log('[WeightedStrategy] Final decision: ${move.gtp()}', outputDebug);
    return (move, aiThoughts);
  }
}

/// Base class for pick-based strategies.
abstract class PickBasedStrategy extends AIStrategy {
  PickBasedStrategy(super.game, super.settings, super.strategyName);

  /// Calculate the number of moves to consider.
  int getNMoves(List<(double, Move)> legalPolicyMoves) {
    final int nMoves;
    if (settings['pick_frac'] != null) {
      final pickFrac = settings['pick_frac'] as num;
      final pickN = settings['pick_n'] as num;
      nMoves = math.max(1, (pickFrac * legalPolicyMoves.length + pickN).truncate());
      log(
        '[$strategyName] Calculated n_moves=$nMoves from pick_frac=$pickFrac, pick_n=$pickN, '
        'legal_moves=${legalPolicyMoves.length}',
        outputDebug,
      );
    } else {
      nMoves = 1; // Default
      log('[$strategyName] Using default n_moves=$nMoves (no pick_frac in settings)', outputDebug);
    }
    return nMoves;
  }

  /// Generate weighted coordinates for selection.
  (List<WeightedCoord>, String) generateWeightedCoords(
    List<(double, Move)> legalPolicyMoves,
    List<List<double>> policyGrid,
    (int, int) size,
  ) {
    log('[$strategyName] Generating weighted coordinates (default equal weights implementation)', outputDebug);
    final (sx, sy) = size;
    // Default implementation for AI_PICK - equal weights
    final weightedCoords = <WeightedCoord>[
      for (var x = 0; x < sx; x++)
        for (var y = 0; y < sy; y++)
          if (policyGrid[y][x] > 0) (policyGrid[y][x], 1, x, y),
    ];
    log('[$strategyName] Generated ${weightedCoords.length} weighted coordinates', outputDebug);
    if (weightedCoords.isNotEmpty) {
      final top5 = _nlargestBy(weightedCoords, 5, (t) => t.$1);
      log('[$strategyName] Top 5 weighted coordinates by policy value:', outputDebug);
      for (var i = 0; i < top5.length; i++) {
        final (pol, wt, x, y) = top5[i];
        log('[$strategyName] #${i + 1}: ($x,$y) - policy=${_pct(pol, 2)}, weight=$wt', outputDebug);
      }
    }
    return (weightedCoords, 'Generated equal weights for all moves. ');
  }

  /// Handle special endgame case.
  (List<WeightedCoord>?, String, int?, bool) handleEndgame(
    List<(double, Move)> legalPolicyMoves,
    List<List<double>> policyGrid,
    (int, int) size,
  ) {
    final (sx, sy) = size;
    final boardSquares = sx * sy;
    final endgameThreshold = (settings.containsKey('endgame') ? settings['endgame'] as num : 0.75) * boardSquares;
    log(
      '[$strategyName] Checking endgame condition: move depth ${cn.depth} vs threshold $endgameThreshold',
      outputDebug,
    );
    if (cn.depth > endgameThreshold) {
      log('[$strategyName] In endgame phase (move ${cn.depth} > $endgameThreshold)', outputDebug);
      final weightedCoords = <WeightedCoord>[
        for (final (pol, mv) in legalPolicyMoves) (pol, 1, mv.coords!.$1, mv.coords!.$2),
      ];
      final aiThoughts = 'Generated equal weights as move number >= ${(settings['endgame'] as num) * sx * sy}. ';
      final nMoves = math.max(getNMoves(legalPolicyMoves), legalPolicyMoves.length ~/ 2);
      log('[$strategyName] Using endgame n_moves=$nMoves', outputDebug);
      log('[$strategyName] Generated ${weightedCoords.length} weighted coordinates for endgame', outputDebug);
      return (weightedCoords, aiThoughts, nMoves, true);
    }
    log('[$strategyName] Not in endgame phase yet', outputDebug);
    return (null, '', null, false);
  }

  /// Select moves from weighted coordinates.
  (Move, String) selectFromWeightedCoords(List<WeightedCoord> weightedCoords, int nMoves, double passPolicy) {
    log('[$strategyName] Selecting from ${weightedCoords.length} weighted coordinates, n_moves=$nMoves', outputDebug);
    final pickMoves = weightedSelectionWithoutReplacement(weightedCoords, nMoves, (c) => c.$2.toDouble(), random);
    log('[$strategyName] Picked ${pickMoves.length} moves', outputDebug);
    Move aimove;
    String aiThoughts;
    if (pickMoves.isNotEmpty) {
      final topPicked = _nlargestCoords(pickMoves, 5);
      log('[$strategyName] Top 5 after selection:', outputDebug);
      for (var i = 0; i < topPicked.length; i++) {
        final (p, wt, x, y) = topPicked[i];
        log('[$strategyName] #${i + 1}: ($x,$y) - policy=${_pct(p, 2)}, weight=$wt', outputDebug);
      }
      final newTop = [for (final (p, _, x, y) in topPicked) (p, Move(coords: (x, y), player: cn.nextPlayer))];
      aimove = newTop[0].$2;
      aiThoughts = 'Top 5 among these were ${fmtMoves(newTop)} and picked top ${aimove.gtp()}. ';
      log('[$strategyName] Top picked move: ${aimove.gtp()} (${_pct(newTop[0].$1, 2)})', outputDebug);
      log('[$strategyName] Pass policy: ${_pct(passPolicy, 2)}', outputDebug);
      if (newTop[0].$1 < passPolicy) {
        log(
          '[$strategyName] Pass policy ${_pct(passPolicy, 2)} is better than top move ${aimove.gtp()} '
          '(${_pct(newTop[0].$1, 2)}), switching to top policy move',
          outputDebug,
        );
        final topPolicyMove = cn.policyRanking![0].$2;
        aiThoughts +=
            'But found pass (${_pct(passPolicy, 2)} to be higher rated than ${aimove.gtp()} '
            '(${_pct(newTop[0].$1, 2)}) so will play top policy move instead.';
        aimove = topPolicyMove;
        log('[$strategyName] Final move (after pass check): ${aimove.gtp()}', outputDebug);
      } else {
        log('[$strategyName] Top move is better than pass, keeping it', outputDebug);
      }
    } else {
      log('[$strategyName] No moves selected, falling back to top policy move', outputDebug);
      aimove = cn.policyRanking![0].$2;
      aiThoughts = 'Pick policy strategy failed to find legal moves, so is playing top policy move ${aimove.gtp()}.';
      log('[$strategyName] Final move (fallback): ${aimove.gtp()}', outputDebug);
    }
    return (aimove, aiThoughts);
  }

  @override
  Future<(Move, String)> generateMove() async {
    log('[$strategyName] Starting move generation', outputDebug);
    await waitForAnalysis();
    if (!_hasPolicy) {
      log('[$strategyName] No policy data available, falling back to DefaultStrategy', outputDebug);
      return DefaultStrategy(game, settings).generateMove();
    }
    final (policyMoves, passPolicy) = _policyMovesWithLogs();
    _logTopPolicyMoves(policyMoves, passPolicy);
    final top5Pass = policyMoves.take(5).any((m) => m.$2.isPass);
    log('[$strategyName] Pass in top 5: $top5Pass', outputDebug);
    final override = (settings.containsKey('pick_override') ? settings['pick_override'] : 0.0) as num;
    final overridetwo = (settings.containsKey('pick_override_two') ? settings['pick_override_two'] : 1.0) as num;
    log(
      '[$strategyName] Override settings: single=${_pct(override, 2)}, combined=${_pct(overridetwo, 2)}',
      outputDebug,
    );
    final (overrideMove, overrideThoughts) = shouldPlayTopMove(
      policyMoves,
      top5Pass,
      override: override,
      overridetwo: overridetwo,
    );
    if (overrideMove != null) {
      log('[$strategyName] Using override move: ${overrideMove.gtp()}', outputDebug);
      return (overrideMove, overrideThoughts);
    }
    final legalPolicyMoves = [
      for (final (pol, mv) in policyMoves)
        if (!mv.isPass && pol > 0) (pol, mv),
    ];
    log('[$strategyName] Found ${legalPolicyMoves.length} legal non-pass policy moves', outputDebug);
    final size = game.boardSize;
    log('[$strategyName] Board size: (${size.$1}, ${size.$2})', outputDebug);
    final policyGrid = varToGrid(cn.policy!, size);
    final (endCoords, _, endNMoves, isEndgame) = handleEndgame(legalPolicyMoves, policyGrid, size);
    if (isEndgame) {
      log('[$strategyName] Using endgame logic', outputDebug);
      return selectFromWeightedCoords(endCoords!, endNMoves!, passPolicy); // KaTrain drops the endgame thoughts
    }
    log('[$strategyName] Generating weighted coordinates', outputDebug);
    final (weightedCoords, weightThoughts) = generateWeightedCoords(legalPolicyMoves, policyGrid, size);
    final nMoves = getNMoves(legalPolicyMoves);
    log('[$strategyName] Using n_moves=$nMoves', outputDebug);
    final aiThoughts =
        '${weightThoughts}Picked ${math.min(nMoves, weightedCoords.length)} random moves according to weights. ';
    log('[$strategyName] Selecting move from weighted coordinates', outputDebug);
    final (move, thoughts) = selectFromWeightedCoords(weightedCoords, nMoves, passPolicy);
    log('[$strategyName] Final decision: ${move.gtp()}', outputDebug);
    return (move, aiThoughts + thoughts);
  }

  void _logTop5Combined(List<WeightedCoord> weightedCoords) {
    final top5 = _nlargestBy(weightedCoords, 5, (t) => t.$1 * t.$2);
    log('[$strategyName] Top 5 weighted coordinates (by policy*weight):', outputDebug);
    for (var i = 0; i < top5.length; i++) {
      final (pol, wt, x, y) = top5[i];
      log(
        '[$strategyName] #${i + 1}: ($x,$y) - policy=${_pct(pol, 2)}, weight=$wt, combined='
        '${_pct(pol * wt, 2)}',
        outputDebug,
      );
    }
  }
}

/// Pick strategy - picks a move from a subset of legal moves.
class PickStrategy extends PickBasedStrategy {
  PickStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'PickStrategy');

  @override
  Future<(Move, String)> generateMove() {
    log('[PickStrategy] Starting move generation using base PickBasedStrategy implementation', outputDebug);
    return super.generateMove();
  }

  @override
  (List<WeightedCoord>?, String, int?, bool) handleEndgame(
    List<(double, Move)> legalPolicyMoves,
    List<List<double>> policyGrid,
    (int, int) size,
  ) => (null, '', null, false);
}

/// Rank strategy - similar to Pick but calibrated based on rank.
class RankStrategy extends PickBasedStrategy {
  RankStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'RankStrategy');

  /// Calculate n_moves based on rank.
  @override
  int getNMoves(List<(double, Move)> legalPolicyMoves) {
    log('[RankStrategy] Calculating n_moves based on rank', outputDebug);
    final (sx, sy) = game.boardSize;
    final boardSquares = sx * sy;
    final normLegMoves = legalPolicyMoves.length / boardSquares;
    final kyuRank = settings['kyu_rank'] as num;
    log('[RankStrategy] Board squares: $boardSquares', outputDebug);
    log('[RankStrategy] Legal moves: ${legalPolicyMoves.length}', outputDebug);
    log('[RankStrategy] Normalized legal moves: ${_fix(normLegMoves, 4)}', outputDebug);
    log('[RankStrategy] Kyu rank: $kyuRank', outputDebug);
    // Calculate n_moves using the rank formula
    final origCalibAvemodrank = 0.063015 + 0.7624 * boardSquares / math.pow(10, -0.05737 * kyuRank + 1.9482);
    log('[RankStrategy] Original calibrated average mod rank: ${_fix(origCalibAvemodrank, 4)}', outputDebug);
    final exponentTerm = 3.002 * normLegMoves * normLegMoves - normLegMoves - 0.034889 * kyuRank - 0.5097;
    log('[RankStrategy] Exponent term: ${_fix(exponentTerm, 4)}', outputDebug);
    final modifiedCalibAvemodrank =
        (0.3931 + 0.6559 * normLegMoves * math.exp(-1 * math.pow(exponentTerm, 2)) - 0.01093 * kyuRank) *
        origCalibAvemodrank;
    log('[RankStrategy] Modified calibrated average mod rank: ${_fix(modifiedCalibAvemodrank, 4)}', outputDebug);
    final denominator = 1.31165 * (modifiedCalibAvemodrank + 1) - 0.082653;
    log('[RankStrategy] Denominator: ${_fix(denominator, 4)}', outputDebug);
    final nMoves = math.max(1, (boardSquares * normLegMoves / denominator).round());
    log('[RankStrategy] Calculated n_moves: $nMoves', outputDebug);
    return nMoves;
  }

  /// Special override logic for rank-based.
  @override
  (Move?, String) shouldPlayTopMove(
    List<(double, Move)> policyMoves,
    bool top5Pass, {
    num override = 0.0,
    num overridetwo = 1.0,
  }) {
    log('[RankStrategy] Calculating special override thresholds based on rank', outputDebug);
    final (sx, sy) = game.boardSize;
    final boardSquares = sx * sy;
    final legalPolicyMoves = [
      for (final (pol, mv) in policyMoves)
        if (!mv.isPass && pol > 0) (pol, mv),
    ];
    final kyuRank = settings['kyu_rank'] as num;
    log('[RankStrategy] Board squares: $boardSquares', outputDebug);
    log('[RankStrategy] Legal non-pass moves: ${legalPolicyMoves.length}', outputDebug);
    log('[RankStrategy] Kyu rank: $kyuRank', outputDebug);
    // Calibrated override based on board filling
    final ratio = (boardSquares - legalPolicyMoves.length) / boardSquares;
    final rankOverride = 0.8 * (1 - 0.5 * ratio);
    log(
      '[RankStrategy] Calculated override: ${_pct(rankOverride, 2)} (from board filling ratio ${_fix(ratio, 2)})',
      outputDebug,
    );
    final rankOverridetwo = 0.85 + _max(0, 0.02 * (kyuRank - 8));
    log('[RankStrategy] Calculated overridetwo: ${_pct(rankOverridetwo, 2)} (from kyu rank adjustment)', outputDebug);
    return super.shouldPlayTopMove(policyMoves, top5Pass, override: rankOverride, overridetwo: rankOverridetwo);
  }

  @override
  (List<WeightedCoord>?, String, int?, bool) handleEndgame(
    List<(double, Move)> legalPolicyMoves,
    List<List<double>> policyGrid,
    (int, int) size,
  ) => (null, '', null, false);
}

/// Influence strategy - weights moves based on influence (distance from edge).
class InfluenceStrategy extends PickBasedStrategy {
  InfluenceStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'InfluenceStrategy');

  @override
  (List<WeightedCoord>, String) generateWeightedCoords(
    List<(double, Move)> legalPolicyMoves,
    List<List<double>> policyGrid,
    (int, int) size,
  ) {
    log('[InfluenceStrategy] Generating influence-based weights', outputDebug);
    log(
      '[InfluenceStrategy] Settings: threshold=${settings['threshold']}, line_weight='
      '${settings['line_weight']}',
      outputDebug,
    );
    final (weightedCoords, aiThoughts) = generateInfluenceTerritoryWeights(aiInfluence, settings, policyGrid, size);
    log('[InfluenceStrategy] Generated ${weightedCoords.length} weighted coordinates', outputDebug);
    if (weightedCoords.isNotEmpty) _logTop5Combined(weightedCoords);
    return (weightedCoords, aiThoughts);
  }
}

/// Territory strategy - weights moves based on territory (distance from center).
class TerritoryStrategy extends PickBasedStrategy {
  TerritoryStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'TerritoryStrategy');

  @override
  (List<WeightedCoord>, String) generateWeightedCoords(
    List<(double, Move)> legalPolicyMoves,
    List<List<double>> policyGrid,
    (int, int) size,
  ) {
    log('[TerritoryStrategy] Generating territory-based weights', outputDebug);
    log(
      '[TerritoryStrategy] Settings: threshold=${settings['threshold']}, line_weight='
      '${settings['line_weight']}',
      outputDebug,
    );
    final (weightedCoords, aiThoughts) = generateInfluenceTerritoryWeights(aiTerritory, settings, policyGrid, size);
    log('[TerritoryStrategy] Generated ${weightedCoords.length} weighted coordinates', outputDebug);
    if (weightedCoords.isNotEmpty) _logTop5Combined(weightedCoords);
    return (weightedCoords, aiThoughts);
  }
}

/// The local and tenuki strategies weigh moves by distance from the last move, so they need one.
abstract class _LastMoveStrategy extends PickBasedStrategy {
  _LastMoveStrategy(super.game, super.settings, super.strategyName);

  String get _mode;

  @override
  Future<(Move, String)> generateMove() {
    // Handle the case where there's no previous move
    if (cn.move?.coords == null) {
      log(
        '[$strategyName] No previous move with valid coordinates found, falling back to WeightedStrategy',
        outputDebug,
      );
      log(
        '[$strategyName] Using default weighted settings: pick_override=0.9, weaken_fac=1, lower_bound=0.02',
        outputDebug,
      );
      return WeightedStrategy(game, {'pick_override': 0.9, 'weaken_fac': 1, 'lower_bound': 0.02}).generateMove();
    }
    return super.generateMove();
  }

  @override
  (List<WeightedCoord>, String) generateWeightedCoords(
    List<(double, Move)> legalPolicyMoves,
    List<List<double>> policyGrid,
    (int, int) size,
  ) {
    log(
      _mode == aiLocal
          ? '[LocalStrategy] Generating local-based weights around previous move'
          : '[TenukiStrategy] Generating tenuki-based weights (far from previous move)',
      outputDebug,
    );
    log('[$strategyName] Previous move: ${cn.move!.gtp()}', outputDebug);
    log('[$strategyName] Variance setting: ${settings['stddev']}', outputDebug);
    final (weightedCoords, aiThoughts) = generateLocalTenukiWeights(_mode, settings, policyGrid, cn, size);
    log('[$strategyName] Generated ${weightedCoords.length} weighted coordinates', outputDebug);
    if (weightedCoords.isNotEmpty) _logTop5Combined(weightedCoords);
    return (weightedCoords, aiThoughts);
  }
}

/// Local strategy - weights moves based on proximity to the last move.
class LocalStrategy extends _LastMoveStrategy {
  LocalStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'LocalStrategy');

  @override
  String get _mode => aiLocal;
}

/// Tenuki strategy - weights moves based on distance from the last move.
class TenukiStrategy extends _LastMoveStrategy {
  TenukiStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'TenukiStrategy');

  @override
  String get _mode => aiTenuki;
}

/// Strategy that imitates human play at various skill levels.
class HumanStyleStrategy extends AIStrategy {
  HumanStyleStrategy(Game game, Map<String, dynamic> settings) : super(game, settings, 'HumanStyleStrategy') {
    log('[HumanStyleStrategy] Initializing HumanStyleStrategy', outputDebug);
    log('[HumanStyleStrategy] AI settings: $settings', outputDebug);
  }

  @override
  Future<(Move, String)> generateMove() async {
    log('[HumanStyleStrategy] Starting move generation', outputDebug);
    final String humanProfile;
    if (settings.containsKey('human_kyu_rank')) {
      final humanKyuRank = ((settings['human_kyu_rank'] as num).toDouble()).round();
      final humanStyle = settings['modern_style'] == true ? 'rank' : 'preaz';
      final rankText = humanKyuRank <= 0 ? '${1 - humanKyuRank}d' : '${humanKyuRank}k'; // dan or kyu ranks
      humanProfile = '${humanStyle}_$rankText';
    } else {
      final proYear = ((settings['pro_year'] as num).toDouble()).round();
      humanProfile = 'proyear_$proYear';
    }
    log('[HumanStyleStrategy] Human profile string: $humanProfile', outputDebug);
    // Define override settings (separate from includePolicy)
    final overrideSettings = <String, dynamic>{'humanSLProfile': humanProfile, 'ignorePreRootHistory': false};
    log('[HumanStyleStrategy] Override settings for engine: $overrideSettings', outputDebug);

    Map<String, dynamic>? analysis;
    var error = false;
    log('[HumanStyleStrategy] Getting engine for player', outputDebug);
    final engine = game.engines[cn.player]!;
    log('[HumanStyleStrategy] Using engine for player ${cn.player}', outputDebug);
    log('[HumanStyleStrategy] Requesting analysis with human profile settings', outputDebug);
    engine.requestAnalysis(
      cn,
      callback: (a, partialResult) {
        if (!partialResult) {
          log('[HumanStyleStrategy] Full analysis results received', outputDebug);
          analysis = a;
          if (a.isNotEmpty) {
            log('[HumanStyleStrategy] Analysis contains humanPolicy: ${a.containsKey('humanPolicy')}', outputDebug);
            log(
              '[HumanStyleStrategy] Analysis contains moveInfos: ${(a['moveInfos'] as List? ?? const []).length} moves',
              outputDebug,
            );
            if (a.containsKey('humanPolicy')) {
              final hp = (a['humanPolicy'] as List).cast<num>();
              final policySum = (hp).sum;
              final policyMax = hp.reduce(_max);
              log('[HumanStyleStrategy] Human policy sum: $policySum, max: $policyMax', outputDebug);
            }
          }
        } else {
          log('[HumanStyleStrategy] Received partial analysis results - ignoring', outputDebug);
        }
      },
      errorCallback: (a) {
        error = true;
        log('[HumanStyleStrategy] Error in human analysis query: $a', outputError);
        log('[HumanStyleStrategy] Will attempt to fall back to policy move', outputDebug);
      },
      priority: priorityExtraAiQuery,
      includePolicy: true,
      extraSettings: overrideSettings,
    );
    log('[HumanStyleStrategy] Analysis request sent, waiting for results', outputDebug);
    var waitCount = 0;
    while (true) {
      raiseIfDiscarded(engine, cn.player);
      if (error || (analysis?.isNotEmpty ?? false)) break;
      await Future<void>.delayed(AIStrategy._pollInterval);
      waitCount += 1;
      if (waitCount % 100 == 0) {
        // Log every 1 second
        log('[HumanStyleStrategy] Still waiting for analysis results (${_fix(waitCount / 100, 1)}s)', outputDebug);
      }
    }
    log(
      '[HumanStyleStrategy] Finished waiting for analysis, error=$error, analysis received='
      '${analysis != null}',
      outputDebug,
    );
    final result = analysis;
    if (error || result == null || result.isEmpty) {
      log('[HumanStyleStrategy] Analysis failed or returned empty', outputDebug);
      final ranking = cn.policyRanking;
      final policyMove = (ranking != null && ranking.isNotEmpty) ? ranking[0].$2 : null;
      if (policyMove != null) {
        log('[HumanStyleStrategy] Falling back to top policy move: ${policyMove.gtp()}', outputDebug);
        return (policyMove, 'Falling back to policy move due to error in human analysis.');
      }
      log('[HumanStyleStrategy] No policy moves available for fallback - will return pass', outputDebug);
      return (Move(player: cn.nextPlayer), 'No valid moves found.');
    }
    log('[HumanStyleStrategy] Processing analysis results', outputDebug);
    if (!result.containsKey('humanPolicy')) {
      throw Exception('humanPolicy not found in analysis—have you downloaded and configured your human model yet?');
    }
    log('[HumanStyleStrategy] Human policy found in analysis', outputDebug);
    final (sx, sy) = game.boardSize;
    log('[HumanStyleStrategy] Board size: ($sx, $sy)', outputDebug);
    final humanPolicy = (result['humanPolicy'] as List).cast<num>();
    log('[HumanStyleStrategy] Human policy length: ${humanPolicy.length}', outputDebug);
    if (humanPolicy.length != sx * sy + 1) {
      log('[HumanStyleStrategy] WARNING: Human policy length ${humanPolicy.length} != ${sx * sy + 1}', outputError);
    }
    // Create a list of moves with their human policy weights
    final moves = <(Move, num)>[];
    for (var x = 0; x < sx; x++) {
      for (var y = 0; y < sy; y++) {
        final idx = (sy - y - 1) * sx + x;
        if (idx < humanPolicy.length && humanPolicy[idx] > 0) {
          moves.add((Move(coords: (x, y), player: cn.nextPlayer), humanPolicy[idx]));
        }
      }
    }
    log('[HumanStyleStrategy] Generated ${moves.length} candidate moves from human policy', outputDebug);
    // Add pass move if it has positive probability
    if (humanPolicy.length > sx * sy && humanPolicy.last > 0) {
      log('[HumanStyleStrategy] Adding pass move with probability ${humanPolicy.last}', outputDebug);
      moves.add((Move(player: cn.nextPlayer), humanPolicy.last));
    }
    log('[HumanStyleStrategy] Performing weighted selection from ${moves.length} moves', outputDebug);
    final topMoves = List.of(moves);
    stableSortBy(topMoves, (m) => -m.$2);
    log('[HumanStyleStrategy] Top 5 moves by probability:', outputDebug);
    final top5 = topMoves.take(5).toList();
    final topMovesStr = [
      for (var i = 0; i < top5.length; i++) '#${i + 1}: ${top5[i].$1.gtp()} - ${_pct(top5[i].$2, 1)}',
    ].join('\n');
    log('[HumanStyleStrategy]\n$topMovesStr', outputDebug);
    final selected = weightedSelectionWithoutReplacement(moves, 1, (m) => m.$2.toDouble(), random)[0];
    final move = selected.$1;
    final prob = selected.$2;
    // Find the rank of the selected move
    final rankIndex = topMoves.indexWhere((m) => m.$1.gtp() == move.gtp());
    final selectedRank = rankIndex >= 0 ? '${rankIndex + 1}' : 'ERROR: move not found in ranking';
    log('[HumanStyleStrategy] Selected move ${move.gtp()} with probability ${_fix(prob, 4)}', outputDebug);
    final aiThoughts = '\n$topMovesStr\n\nPlayed move ${move.gtp()} (${_pct(prob, 1)}) as the #$selectedRank top move.';
    log('[HumanStyleStrategy] Final decision: ${move.gtp()}', outputDebug);
    return (move, aiThoughts);
  }
}

typedef StrategyFactory = AIStrategy Function(Game game, Map<String, dynamic> settings);

/// The strategy for each AI mode.
final Map<String, StrategyFactory> strategyRegistry = {
  aiDefault: DefaultStrategy.new,
  aiHandicap: HandicapStrategy.new,
  aiAntimirror: AntimirrorStrategy.new,
  aiJigo: JigoStrategy.new,
  aiScoreloss: ScoreLossStrategy.new,
  aiSimpleOwnership: SimpleOwnershipStrategy.new,
  aiSettleStones: SettleStonesStrategy.new,
  aiPolicy: PolicyStrategy.new,
  aiWeighted: WeightedStrategy.new,
  aiPick: PickStrategy.new,
  aiRank: RankStrategy.new,
  aiInfluence: InfluenceStrategy.new,
  aiTerritory: TerritoryStrategy.new,
  aiLocal: LocalStrategy.new,
  aiTenuki: TenukiStrategy.new,
  aiHuman: HumanStyleStrategy.new,
  aiPro: HumanStyleStrategy.new,
};

/// Generates a move with the selected AI strategy and plays it. Returns no move when the analysis was discarded,
/// and the move without a node when the position changed while thinking.
Future<(Move?, GameNode?)> generateAiMove(Game game, String aiMode, Map<String, dynamic> aiSettings) async {
  // Custom configs may refer to a removed strategy.
  var strategyFactory = strategyRegistry[aiMode];
  if (strategyFactory == null) {
    game.katrain.log("AI strategy '$aiMode' not found, falling back to '$aiDefault'", outputError);
    strategyFactory = strategyRegistry[aiDefault]!;
  }
  final strategy = strategyFactory(game, aiSettings);
  game.katrain.log('Generating move using ${strategy.strategyName} (mode $aiMode)', outputDebug);
  final Move move;
  final String aiThoughts;
  try {
    (move, aiThoughts) = await strategy.generateMove();
  } on AnalysisDiscardedException catch (e) {
    game.katrain.log('Discarding AI move: $e', outputDebug);
    return (null, null);
  }
  final playedNode = game.play(move, expectedNode: strategy.cn);
  if (playedNode == null) {
    game.katrain.log('Discarding AI move ${move.gtp()}: position changed', outputDebug);
    return (move, null);
  }
  playedNode.aiThoughts = aiThoughts;
  game.katrain.log('Move generation complete: ${move.gtp()} -- $aiThoughts', outputDebug);
  return (move, playedNode);
}
