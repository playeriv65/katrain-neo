// Behaviour tests for GameNode: merging KataGo analysis results, candidate moves and evaluations, comments, and
// writing SGF (comments, marks, KT analysis data) and reading it back.

import 'dart:convert';

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

const size = 9;
const squares = size * size;

/// A move as it appears in KataGo's `moveInfos`.
typedef MoveInfo = ({String move, int visits, double winrate, double score, List<String> pv});

MoveInfo mi(String move, double score, {int visits = 50, double winrate = 0.5, List<String>? pv}) =>
    (move: move, visits: visits, winrate: winrate, score: score, pv: pv ?? [move]);

/// One KataGo analysis result, decoded from JSON as the engine delivers it (dynamic maps, ints for whole numbers).
Map<String, dynamic> katagoResult({
  int visits = 100,
  double winrate = 0.5,
  double score = 0.0,
  List<MoveInfo> moves = const [],
  List<double>? ownership,
  List<double>? policy,
  bool partial = false,
}) {
  final json = {
    'id': 'QUERY:1',
    'isDuringSearch': partial,
    'rootInfo': {'visits': visits, 'winrate': winrate, 'scoreLead': score},
    'moveInfos': [
      for (final (i, m) in moves.indexed)
        {
          'move': m.move,
          'order': i,
          'visits': m.visits,
          'winrate': m.winrate,
          'scoreLead': m.score,
          'prior': 0.1,
          'pv': m.pv,
        },
    ],
    'ownership': ?ownership,
    'policy': ?policy,
  };
  return jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
}

/// A policy with the given values at KataGo's policy indices (row by row from the top, pass last), zero elsewhere.
List<double> policyWith(Map<String, double> values) {
  final policy = List<double>.filled(squares + 1, 0.0);
  for (final MapEntry(key: gtp, value: p) in values.entries) {
    policy[policyIndex(gtp)] = p;
  }
  return policy;
}

int policyIndex(String gtp) {
  if (gtp == 'pass') return squares;
  final (x, y) = Move.fromGtp(gtp).coords!;
  return (size - 1 - y) * size + x;
}

void setFinal(GameNode node, Map<String, dynamic> result) => node.setAnalysis(result, null, false, null, false);

Map<String, dynamic> moveEntry(GameNode node, String gtp) =>
    (node.analysis['moves'] as Map<String, dynamic>)[gtp] as Map<String, dynamic>;

List<String> candidateOrder(GameNode node) => [for (final c in node.candidateMoves) c['move'] as String];

/// The main line of [sgf]: root, then the first child at every step.
List<GameNode> mainLine(String sgf) {
  final nodes = [gameParser.parseSgf(sgf)];
  while (nodes.last.children.isNotEmpty) {
    nodes.add(nodes.last.children.first);
  }
  return nodes;
}

/// Records requests and keeps their callbacks, so tests can deliver results.
class FakeEngine implements AnalysisEngine<GameNode> {
  final List<({GameNode node, List<int>? region, Move? nextMove, AnalysisCallback callback})> requests = [];

  @override
  final Map<String, dynamic> config = {'max_visits': 100};

  @override
  int queryGeneration = 0;

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
  }) => requests.add((node: analysisNode, region: regionOfInterest, nextMove: nextMove, callback: callback));

  @override
  void stopPondering() {}

  @override
  void terminateQueries({GameNode? onlyForNode}) {}
}

void main() {
  setUp(() => i18n.switchLang('en'));
  tearDownAll(() => i18n.switchLang(defaultLanguage));

  group('merging analysis results', () {
    test('a fresh node has no analysis', () {
      final node = mainLine('(;SZ[9];B[ee])')[1];
      expect(node.analysisExists, isFalse);
      expect(node.analysisComplete, isFalse);
      expect(node.rootVisits, 0);
      expect(node.score, isNull);
      expect(node.winrate, isNull);
      expect(node.candidateMoves, isEmpty);
      expect(node.pointsLost, isNull);
    });

    test('a complete result sets root info, candidates, ownership and policy', () {
      final node = mainLine('(;SZ[9];B[ee])')[1];
      final ownership = List<double>.generate(squares, (i) => i.isEven ? 1 : -1);
      final policy = policyWith({'C7': 0.5});
      setFinal(
        node,
        katagoResult(
          visits: 400,
          winrate: 0.3,
          score: -2.5,
          moves: [
            mi('C7', -2.5, pv: ['C7', 'D4']),
            mi('D4', -4),
          ],
          ownership: ownership,
          policy: policy,
        ),
      );
      expect(node.analysisExists, isTrue);
      expect(node.analysisComplete, isTrue);
      expect(node.rootVisits, 400);
      expect(node.score, -2.5);
      expect(node.winrate, 0.3);
      expect((node.analysis['moves'] as Map).keys, ['C7', 'D4']);
      expect(moveEntry(node, 'C7')['pv'], ['C7', 'D4']);
      expect(moveEntry(node, 'D4')['order'], 1);
      expect(node.ownership, ownership);
      expect(node.policy, policy);
    });

    test('partial results make analysis visible but not complete, until the final one arrives', () {
      final node = mainLine('(;SZ[9];B[ee])')[1];
      node.setAnalysis(katagoResult(visits: 20, score: 1, moves: [mi('C7', 1)]), null, false, null, true);
      expect(node.analysisExists, isTrue);
      expect(node.analysisComplete, isFalse);
      expect(node.rootVisits, 20);

      setFinal(node, katagoResult(visits: 400, score: 2, moves: [mi('D4', 2)]));
      expect(node.analysisComplete, isTrue);
      expect(node.rootVisits, 400);

      // a later partial result (e.g. pondering) updates the values but the node stays complete
      node.setAnalysis(katagoResult(visits: 30, score: 3, moves: [mi('D4', 3)]), null, false, null, true);
      expect(node.analysisComplete, isTrue);
      expect(node.score, 3);
    });

    test('a new result reorders candidates; moves it no longer mentions go to the end', () {
      final node = mainLine('(;SZ[9];B[ee])')[1];
      setFinal(node, katagoResult(moves: [mi('C7', 1, visits: 60), mi('D4', 0, visits: 40), mi('F3', -1, visits: 9)]));
      setFinal(node, katagoResult(moves: [mi('D4', 3, visits: 300), mi('C7', 2, visits: 200)]));
      expect(moveEntry(node, 'D4')['order'], 0);
      expect(moveEntry(node, 'C7')['order'], 1);
      expect(moveEntry(node, 'F3')['order'], additionalMoveOrder);
      expect(moveEntry(node, 'D4')['scoreLead'], 3);
      expect(candidateOrder(node), ['D4', 'C7', 'F3']);
    });

    test('a move evaluated with fewer visits than before only fills in missing values', () {
      final node = mainLine('(;SZ[9];B[ee])')[1];
      setFinal(
        node,
        katagoResult(
          moves: [
            mi('C7', 1, visits: 300, pv: ['C7', 'D4', 'E3']),
          ],
        ),
      );
      final small = katagoResult(
        moves: [
          mi('C7', 5, visits: 10, pv: ['C7']),
        ],
      );
      ((small['moveInfos'] as List)[0] as Map)['lcb'] = 0.42;
      setFinal(node, small);
      final c7 = moveEntry(node, 'C7');
      expect(c7['scoreLead'], 1);
      expect(c7['visits'], 300);
      expect(c7['pv'], ['C7', 'D4', 'E3']);
      expect(c7['lcb'], 0.42);
      expect(c7['order'], 0);
    });

    test('a child result updates the parent\'s entry for the move played', () {
      final [root, b1] = mainLine('(;SZ[9];B[ee])');
      setFinal(root, katagoResult(score: 1, moves: [mi('D4', 1, visits: 60), mi('E5', 0, visits: 30)]));
      setFinal(
        b1,
        katagoResult(
          visits: 200,
          winrate: 0.4,
          score: -1.5,
          moves: [
            mi('C7', -1.5, pv: ['C7', 'D4']),
          ],
        ),
      );
      final e5 = moveEntry(root, 'E5');
      expect(e5['visits'], 200);
      expect(e5['scoreLead'], -1.5);
      expect(e5['winrate'], 0.4);
      expect(e5['pv'], ['E5', 'C7', 'D4']);
      expect(e5['order'], 1);
      // the parent's own evaluation is untouched
      expect(root.score, 1);
      expect(root.rootVisits, 100);
    });

    test('a child analysed before its parent adds the move to the parent, ordered after the others', () {
      final [root, b1] = mainLine('(;SZ[9];B[ee])');
      setFinal(b1, katagoResult(visits: 80, score: -1, moves: [mi('C7', -1)]));
      expect(root.analysisExists, isFalse);
      expect(moveEntry(root, 'E5')['order'], additionalMoveOrder);
      expect(moveEntry(root, 'E5')['move'], 'E5');

      // the parent's own result later ranks it, with more visits
      setFinal(root, katagoResult(score: 1, moves: [mi('D4', 1, visits: 300), mi('E5', 0.5, visits: 150)]));
      expect(moveEntry(root, 'E5')['order'], 1);
      expect(moveEntry(root, 'E5')['scoreLead'], 0.5);
      expect(candidateOrder(root), ['D4', 'E5']);
    });

    test('alternative moves are added after the existing candidates, keeping root info and their order', () {
      final node = mainLine('(;SZ[9];B[ee])')[1];
      node.setAnalysis(katagoResult(visits: 100, score: 2, moves: [mi('D4', 2), mi('C3', 1)]), null, false, null, true);
      node.setAnalysis(
        katagoResult(visits: 50, score: -5, moves: [mi('G7', -6), mi('F3', -1)]),
        null,
        true,
        null,
        false,
      );
      expect(node.score, 2);
      expect(node.rootVisits, 100);
      expect(moveEntry(node, 'D4')['order'], 0);
      expect(moveEntry(node, 'C3')['order'], 1);
      expect(moveEntry(node, 'G7')['order'], additionalMoveOrder);
      expect(moveEntry(node, 'F3')['order'], additionalMoveOrder);
      // the extra moves come after the original ones, the better for white (to move) first
      expect(candidateOrder(node), ['D4', 'C3', 'G7', 'F3']);
      // an alternatives query is no normal analysis: it does not complete the node
      expect(node.analysisComplete, isFalse);
    });

    test('a refined move gets the result\'s root info and principal variation', () {
      final node = mainLine('(;SZ[9];B[ee])')[1]; // white to play
      setFinal(node, katagoResult(score: -1, moves: [mi('C7', -1)], policy: policyWith({'C7': 0.5})));
      final refine = Move.fromGtp('G3', player: 'W');
      node.setAnalysis(
        katagoResult(
          visits: 300,
          winrate: 0.8,
          score: 4,
          moves: [
            mi('C3', 4, pv: ['C3', 'D4']),
          ],
        ),
        refine,
        false,
        null,
        false,
      );
      final g3 = moveEntry(node, 'G3');
      expect(g3['visits'], 300);
      expect(g3['scoreLead'], 4);
      expect(g3['winrate'], 0.8);
      expect(g3['pv'], ['G3', 'C3', 'D4']);
      expect(g3['order'], additionalMoveOrder);
      // only the move is updated: not the root, the policy or the moves of the reply
      expect(node.score, -1);
      expect(node.policy, policyWith({'C7': 0.5}));
      expect((node.analysis['moves'] as Map).keys, ['C7', 'G3']);
    });

    test('a refined move that was a candidate keeps its rank', () {
      final node = mainLine('(;SZ[9];B[ee])')[1];
      setFinal(node, katagoResult(moves: [mi('C7', -1, visits: 50), mi('G3', -3, visits: 10)]));
      node.setAnalysis(katagoResult(visits: 300, score: -2), Move.fromGtp('G3', player: 'W'), false, null, false);
      expect(moveEntry(node, 'G3')['order'], 1);
      expect(moveEntry(node, 'G3')['scoreLead'], -2);
      expect(moveEntry(node, 'G3')['pv'], ['G3']);
    });

    test('a region result ranks the candidates but leaves the evaluation and the parent alone', () {
      final [root, b1] = mainLine('(;SZ[9];B[ee])');
      setFinal(root, katagoResult(score: 1, moves: [mi('D4', 1, visits: 300), mi('E5', 0, visits: 200)]));
      setFinal(b1, katagoResult(visits: 100, score: -1, moves: [mi('C7', -1), mi('G3', -2)]));
      final e5Before = Map.of(moveEntry(root, 'E5'));

      b1.setAnalysis(
        katagoResult(visits: 500, score: -9, moves: [mi('B8', -9, visits: 400), mi('C7', -10, visits: 90)]),
        null,
        false,
        [1, 3, 5, 8],
        false,
      );
      expect(b1.score, -1);
      expect(b1.rootVisits, 100);
      expect(candidateOrder(b1), ['B8', 'C7', 'G3']);
      expect(moveEntry(root, 'E5'), e5Before);
    });

    test('analyze() with regionRoot makes the region result the node\'s evaluation', () {
      final [root, b1] = mainLine('(;SZ[9];B[ee])');
      setFinal(root, katagoResult(score: 1, moves: [mi('D4', 1, visits: 300), mi('E5', 0, visits: 200)]));
      setFinal(b1, katagoResult(visits: 100, score: -1, moves: [mi('C7', -1)]));
      final engine = FakeEngine();
      const region = [1, 3, 5, 8];
      b1.analyze(engine, regionOfInterest: region);
      b1.analyze(engine, regionOfInterest: region, regionRoot: true);
      expect([for (final r in engine.requests) r.region], [region, region]);

      engine.requests[0].callback(katagoResult(visits: 500, score: -9, moves: [mi('B8', -9, visits: 400)]), false);
      expect(b1.score, -1);
      expect(moveEntry(root, 'E5')['scoreLead'], 0);

      engine.requests[1].callback(katagoResult(visits: 600, score: -7, moves: [mi('B8', -7, visits: 500)]), false);
      expect(b1.score, -7);
      expect(b1.rootVisits, 600);
      expect(moveEntry(root, 'E5')['scoreLead'], -7);
    });

    test('analyze() merges partial and final engine results into the node', () {
      final b1 = mainLine('(;SZ[9];B[ee])')[1];
      final engine = FakeEngine();
      b1.analyze(engine, refineMove: Move.fromGtp('G3', player: 'W'));
      b1.analyze(engine);
      expect(engine.requests[0].nextMove, Move.fromGtp('G3', player: 'W'));
      engine.requests[1].callback(katagoResult(visits: 10, score: 1, moves: [mi('C7', 1)], partial: true), true);
      expect(b1.analysisExists, isTrue);
      expect(b1.analysisComplete, isFalse);
      engine.requests[1].callback(katagoResult(visits: 100, score: 2, moves: [mi('C7', 2)]), false);
      expect(b1.analysisComplete, isTrue);
      engine.requests[0].callback(katagoResult(visits: 50, score: 6, moves: [mi('C3', 6)]), false);
      expect(moveEntry(b1, 'G3')['scoreLead'], 6);
      expect(b1.score, 2);
    });

    test('clearAnalysis forgets everything', () {
      final node = mainLine('(;SZ[9];B[ee])')[1];
      setFinal(node, katagoResult(moves: [mi('C7', 1)], policy: policyWith({}), ownership: List.filled(squares, 0)));
      node.analysisVisitsRequested = 100;
      node.clearAnalysis();
      expect(node.analysisExists, isFalse);
      expect(node.analysisComplete, isFalse);
      expect(node.analysis['moves'], isEmpty);
      expect(node.policy, isNull);
      expect(node.ownership, isNull);
      expect(node.analysisVisitsRequested, 0);
    });
  });

  group('evaluations', () {
    // root (B to play) -> B E5 -> W C7 -> B G3
    late GameNode root, b1, w2, b3;
    setUp(() {
      [root, b1, w2, b3] = mainLine('(;SZ[9]KM[6.5];B[ee];W[cc];B[gg])');
      setFinal(
        root,
        katagoResult(
          score: 2,
          winrate: 0.6,
          moves: [mi('D4', 2, winrate: 0.6, visits: 300), mi('E5', 1, winrate: 0.55, visits: 50)],
        ),
      );
      setFinal(b1, katagoResult(score: -1, winrate: 0.4, moves: [mi('C7', -1, winrate: 0.4), mi('F5', 1)]));
      setFinal(w2, katagoResult(score: 1.5, winrate: 0.55));
    });

    test('points lost are from the player\'s point of view', () {
      expect(b1.pointsLost, closeTo(3, 1e-9)); // black: 2 -> -1
      expect(w2.pointsLost, closeTo(2.5, 1e-9)); // white: -1 -> 1.5
      expect(b3.pointsLost, isNull); // not analysed
      expect(root.pointsLost, isNull);
    });

    test('points lost realized by the parent compare with the grandparent', () {
      expect(w2.parentRealizedPointsLost, closeTo(0.5, 1e-9)); // white: 2 -> 1.5
      expect(b1.parentRealizedPointsLost, isNull);
    });

    test('candidate moves carry points and win rate lost for the player to move', () {
      final rootCandidates = root.candidateMoves; // black to move
      expect(candidateOrder(root), ['D4', 'E5']);
      expect(rootCandidates[0]['pointsLost'], closeTo(0, 1e-9));
      // E5 now carries the child's evaluation
      expect(rootCandidates[1]['scoreLead'], -1);
      expect(rootCandidates[1]['pointsLost'], closeTo(3, 1e-9));
      expect(rootCandidates[1]['relativePointsLost'], closeTo(3, 1e-9));
      expect(rootCandidates[1]['winrateLost'], closeTo(0.2, 1e-9));

      final b1Candidates = b1.candidateMoves; // white to move
      expect(candidateOrder(b1), ['C7', 'F5']);
      // C7 was played: it carries the evaluation of W C7
      expect(b1Candidates[0]['scoreLead'], 1.5);
      expect(b1Candidates[0]['pointsLost'], closeTo(2.5, 1e-9));
      expect(b1Candidates[1]['pointsLost'], closeTo(2, 1e-9));
      expect(b1Candidates[1]['winrateLost'], closeTo(0.1, 1e-9));
    });

    test('relative points lost compare with the top candidate, not the root', () {
      final node = mainLine('(;SZ[9];B[ee])')[1]; // white to move
      setFinal(node, katagoResult(score: 0, moves: [mi('C7', -1), mi('F5', 2)]));
      final [top, second] = node.candidateMoves;
      expect(top['pointsLost'], closeTo(-1, 1e-9));
      expect(top['relativePointsLost'], closeTo(0, 1e-9));
      expect(second['pointsLost'], closeTo(2, 1e-9));
      expect(second['relativePointsLost'], closeTo(3, 1e-9));
    });

    test('candidates of the same rank are ordered by points lost', () {
      final node = mainLine('(;SZ[9];B[ee])')[1]; // white to move
      setFinal(node, katagoResult(score: 0, moves: [mi('C7', 0)]));
      node.setAnalysis(katagoResult(moves: [mi('A1', 6), mi('B2', 1), mi('C3', 3)]), null, true, null, false);
      expect(candidateOrder(node), ['C7', 'B2', 'C3', 'A1']);
    });

    test('without candidate moves, the top policy move stands in, or a pass', () {
      expect(w2.candidateMoves, [
        {
          'visits': 100,
          'winrate': 0.55,
          'scoreLead': 1.5,
          'pointsLost': 0,
          'winrateLost': 0,
          'order': 0,
          'move': 'pass',
          'pv': ['pass'],
        },
      ]);
      final node = mainLine('(;SZ[9];B[ee])')[1];
      setFinal(node, katagoResult(score: 1, policy: policyWith({'G3': 0.7, 'C7': 0.2})));
      expect(node.candidateMoves.single['move'], 'G3');
      expect(node.candidateMoves.single['pv'], ['G3']);
      expect(node.candidateMoves.single['scoreLead'], 1);
    });

    test('score and win rate are shown for the leading player', () {
      expect(root.formatScore(), 'B+2.0');
      expect(b1.formatScore(), 'W+1.0');
      expect(root.formatWinrate(), 'B 60.0%');
      expect(b1.formatWinrate(), 'W 60.0%');
      expect(b1.formatScore(3.5), 'B+3.5');
      expect(b1.formatWinrate(0.75), 'B 75.0%');
      expect(b3.formatScore(), isNull);
      expect(b3.formatWinrate(), isNull);
    });

    test('children: good moves first, unanalysed next, undone moves last', () {
      final r = gameParser.parseSgf('(;SZ[9](;B[aa])(;B[bb])(;B[cc])(;B[dd]))');
      final [a, b, c, d] = r.children;
      a.autoUndo = true;
      b.autoUndo = null;
      c.autoUndo = false;
      d.autoUndo = null;
      expect(r.orderedChildren, [c, b, d, a]);
      // the tree itself is not reordered
      expect(r.children, [a, b, c, d]);
    });
  });

  group('policy', () {
    test('ranking: highest policy first, as moves for the player to move, pass included', () {
      final node = mainLine('(;SZ[9];B[ee])')[1]; // white to move
      setFinal(node, katagoResult(policy: policyWith({'C7': 0.5, 'pass': 0.25, 'A9': 0.125, 'J1': 0.0625})));
      final ranking = node.policyRanking!;
      expect(ranking.length, squares + 1);
      expect(
        [for (final (p, m) in ranking.take(4)) (p, m.gtp())],
        [(0.5, 'C7'), (0.25, 'pass'), (0.125, 'A9'), (0.0625, 'J1')],
      );
      expect(ranking.every((r) => r.$2.player == 'W'), isTrue);
    });

    test('ranking: illegal moves (-1) last, pass after board points of equal policy', () {
      final node = mainLine('(;SZ[9];B[ee])')[1];
      final policy = List<double>.filled(squares + 1, 0.01)
        ..[policyIndex('E5')] = -1
        ..[policyIndex('D4')] = 0.5;
      setFinal(node, katagoResult(policy: policy));
      final ranking = node.policyRanking!;
      expect(ranking.first.$2.gtp(), 'D4');
      expect(ranking.last.$2.gtp(), 'E5');
      expect(ranking[ranking.length - 2].$2.gtp(), 'pass');
    });

    test('no policy, no ranking', () {
      final node = mainLine('(;SZ[9];B[ee])')[1];
      expect(node.policyRanking, isNull);
      setFinal(node, katagoResult(moves: [mi('C7', 1)]));
      expect(node.policyRanking, isNull);
    });

    test('move policy stats: the rank and probability of the move played in the parent\'s policy', () {
      final [root, b1, w2] = mainLine('(;SZ[9];B[ee];W[cc])');
      setFinal(root, katagoResult(policy: policyWith({'D4': 0.5, 'E5': 0.25})));
      final (rank, probability, ranking) = b1.movePolicyStats();
      expect(rank, 2);
      expect(probability, 0.25);
      expect(ranking.first.$2, Move.fromGtp('D4'));
      // the parent has no policy
      final (rank2, probability2, ranking2) = w2.movePolicyStats();
      expect(rank2, isNull);
      expect(probability2, 0.0);
      expect(ranking2, isEmpty);
      expect(root.movePolicyStats().$1, isNull);
    });
  });

  group('comments', () {
    // root (B to play) -> B E5 (a mistake) -> W C7 (the best move) -> B G3 (not analysed)
    late GameNode root, b1, w2, b3;
    setUp(() {
      [root, b1, w2, b3] = mainLine('(;SZ[9]KM[6.5]RU[japanese];B[ee];W[cc];B[gg])');
      setFinal(
        root,
        katagoResult(
          score: 2,
          winrate: 0.6,
          moves: [
            mi('D4', 2, pv: ['D4', 'F6'], visits: 60),
            mi('E5', -1, visits: 30),
          ],
          policy: policyWith({'D4': 0.5, 'E5': 0.25}),
        ),
      );
      setFinal(
        b1,
        katagoResult(
          visits: 80,
          score: -1,
          winrate: 0.4,
          moves: [
            mi('C7', -1, pv: ['C7', 'D4']),
            mi('F5', 1),
          ],
          policy: policyWith({'C7': 0.5}),
        ),
      );
      setFinal(w2, katagoResult(visits: 70, score: -0.5, winrate: 0.45, moves: [mi('G3', -0.5)]));
    });

    test('root: komi and rules', () {
      expect(root.comment(), 'Komi: 6.5\nRules: Japanese\n');
      expect(root.comment(sgf: true), 'Komi: 6.5\nRules: Japanese\n');
    });

    test('a mistake, written to SGF', () {
      expect(
        b1.comment(sgf: true),
        'Move 1: B E5\n'
        'Score: W+1.0\n'
        'Win rate: W 60.0%\n'
        'Estimated point loss: 3.0\n'
        'Predicted top move was D4 (B+2.0).\n'
        'PV: BD4 F6\n'
        'Move was #2 according to policy  (25.00%).\n'
        'Top policy move was D4 (50.0%).\n',
      );
    });

    test('a mistake, with details on screen: the PV is a part of its own, to show on the board', () {
      expect(
        b1.comment(details: true),
        'Move 1: B E5\n'
        'Predicted top move was D4 (B+2.0).\n'
        'PV: BD4 F6\n'
        'Move was #2 according to policy  (25.00%).\n'
        'Top policy move was D4 (50.0%).\n',
      );
      final parts = b1.commentParts(details: true);
      final pv = parts.whereType<CommentVariation>().single;
      expect(pv.player, 'B');
      expect(pv.moves, ['D4', 'F6']);
      expect(parts.first.text, endsWith('PV: '));
    });

    test('comments from the file come under a heading', () {
      b1.setProperty('C', 'nice shape');
      final parts = b1.commentParts();
      expect(
        [
          for (final p in parts)
            if (p is CommentText && p.heading) p.text,
        ],
        ['SGF Comments:'],
      );
      expect(b1.comment(), 'Move 1: B E5\n\nSGF Comments:\nnice shape');
    });

    test('a mistake, in teaching mode and by default', () {
      expect(b1.comment(teach: true), 'Move 1: B E5\nMove was #2 according to policy  (25.00%).\n');
      expect(b1.comment(), 'Move 1: B E5\n');
    });

    test('the best move', () {
      expect(
        w2.comment(sgf: true),
        'Move 2: W C7\n'
        'Score: W+0.5\n'
        'Win rate: W 55.0%\n'
        'Move was predicted best move\n'
        'PV: WC7 G3\n'
        'Move was #1 according to policy  (50.00%).\n',
      );
    });

    test('small losses are not mentioned', () {
      final [r, b] = mainLine('(;SZ[9];B[ee])');
      setFinal(r, katagoResult(score: 1, moves: [mi('D4', 1, visits: 300)]));
      setFinal(b, katagoResult(score: 0.6));
      final text = b.comment(sgf: true);
      expect(text, contains('Predicted top move was D4'));
      expect(text, isNot(contains('point loss')));
    });

    test('a move without analysis', () {
      expect(b3.comment(), 'Analyzing move...');
      expect(b3.comment(sgf: true), 'No analysis available');
    });

    test('a move undone in teaching mode shows the predicted follow-up', () {
      b1.autoUndo = true;
      expect(
        b1.comment(sgf: true),
        endsWith('Move was automatically undone in teaching mode.\nPredicted follow-up: WC7 G3\n'),
      );
      expect(b1.comment(details: true), isNot(contains('undone')));
    });

    test('AI thoughts are shown with details and in SGF', () {
      b1.aiThoughts = 'played the policy move';
      expect(b1.comment(details: true), endsWith('\nAI thought process: played the policy move'));
      expect(b1.comment(sgf: true), endsWith('\nAI thought process: played the policy move'));
      expect(b1.comment(), isNot(contains('AI thought')));
    });

    test('comments follow the language', () {
      i18n.switchLang('cn');
      expect(w2.comment(sgf: true), contains('该手为最佳选点'));
      expect(b1.comment(sgf: true), contains('目数损失: 3.0'));
    });
  });

  group('SGF', () {
    const thresholds = [12, 6, 3, 1.5, 0.5, 0];
    final allComments = SgfSaveOptions(
      saveCommentsPlayer: {'B': true, 'W': true},
      saveCommentsClass: List.filled(6, true),
      evalThresholds: thresholds,
    );

    /// root -> B E5 (loses 8) -> W C7 (loses 8) -> B G3 (loses 1.5) -> W G7 (loses nothing)
    List<GameNode> analysedGame() {
      final nodes = mainLine('(;SZ[9]KM[6.5]RU[japanese];B[ee];W[cc];B[gg];W[gc])');
      final scores = [2.0, -6.0, 2.0, 0.5, 0.5];
      for (final (i, node) in nodes.indexed) {
        setFinal(node, katagoResult(visits: 100, score: scores[i], moves: [mi('D4', scores[i], visits: 40)]));
      }
      return nodes;
    }

    Map<String, GameNode> byMove(GameNode root) => {
      for (final n in root.nodesInTree)
        if (n.move != null) n.move!.gtp(): n,
    };

    test('the root records the writer, encoding and analysis format', () {
      final root = gameParser.parseSgf('(;SZ[9]KM[6.5];B[ee])');
      final again = gameParser.parseSgf(root.sgf());
      expect(again.getProperty('CA'), 'UTF-8');
      expect(again.getProperty('AP'), '$appName:$appVersion');
      expect(again.getProperty('KTV'), analysisFormatVersion);
      expect(again.getProperty('SZ'), '9');
      expect(again.getProperty('KM'), '6.5');
      // the generated "SGF generated by" comment is dropped on reading
      expect(again.note, isEmpty);
      expect(again.properties.containsKey('C'), isFalse);
      expect(again.children.single.move, Move.fromGtp('E5'));
    });

    test('moves, variations and setup stones survive a round trip', () {
      const sgf = '(;SZ[9]KM[7.5]RU[chinese]AB[cc][gg]PL[W];W[ee](;B[dd];W[ff])(;B[ec]))';
      final root = gameParser.parseSgf(sgf);
      final again = gameParser.parseSgf(root.sgf());
      expect(again.placements, root.placements);
      expect(again.ruleset, 'chinese');
      expect(again.komi, 7.5);
      expect(again.nextPlayer, 'W');
      expect([for (final n in again.nodesInTree) n.move], [for (final n in root.nodesInTree) n.move]);
      expect(again.children.single.children.length, 2);
    });

    const blackMistakes = SgfSaveOptions(
      saveCommentsPlayer: {'B': true, 'W': false},
      saveCommentsClass: [true, true, false, false, false, false],
      evalThresholds: thresholds,
    );

    test('by default no generated comments are written', () {
      final sgf = analysedGame()[0].sgf();
      expect(sgf, isNot(contains('Move 1:')));
      expect(sgf, isNot(contains('Estimated point loss')));
    });

    test('generated comments are written for the chosen players and mistake classes, and dropped on reading', () {
      final nodes = analysedGame();
      final all = nodes[0].sgf(allComments);
      expect(all, contains('Move 1: B E5'));
      expect(all, contains('Score: W+6.0'));
      expect(all, contains('Estimated point loss: 8.0'));
      expect(all, contains('Move 2: W C7'));
      expect(all, contains('Move 3: B G3'));
      expect(all, isNot(contains('Move 4: W G7'))); // lost nothing: no class to report
      for (final node in byMove(gameParser.parseSgf(all)).values) {
        expect(node.note, isEmpty);
        expect(node.properties.containsKey('C'), isFalse);
      }

      final some = nodes[0].sgf(blackMistakes);
      expect(some, contains('Move 1: B E5')); // black, lost 8
      expect(some, isNot(contains('Move 2: W C7'))); // white
      expect(some, isNot(contains('Move 3: B G3'))); // lost 1.5: class not chosen
    });

    test('a note is written, with the generated comment, and reads back alone', () {
      final nodes = analysedGame();
      nodes[2].note = 'my note\nsecond line';
      for (final sgf in [nodes[0].sgf(), nodes[0].sgf(blackMistakes)]) {
        expect(sgf, contains('Move 2: W C7'));
        final moves = byMove(gameParser.parseSgf(sgf));
        expect(moves['C7']!.note, 'my note\nsecond line');
        expect(moves['E5']!.note, isEmpty);
      }

      final [root, unanalysed] = mainLine('(;SZ[9];B[ee])');
      unanalysed.note = 'hello';
      expect(mainLine(root.sgf())[1].note, 'hello');
    });

    test('marks: the top move with a cross, moves losing at most half a point with a square', () {
      final [root, b1] = mainLine('(;SZ[9]KM[6.5];B[ee])');
      setFinal(
        root,
        katagoResult(
          score: 2,
          moves: [
            mi('D4', 2, visits: 90),
            mi('E5', 1.8, visits: 80),
            mi('C3', 1, visits: 70),
            mi('pass', 1.9, visits: 5),
          ],
        ),
      );
      setFinal(b1, katagoResult(score: 1.8, moves: [mi('C7', 1.8)]));
      final sgf = root.sgf(
        SgfSaveOptions(
          saveCommentsPlayer: {'B': true, 'W': true},
          saveCommentsClass: List.filled(6, true),
          evalThresholds: thresholds,
          saveMarks: true,
        ),
      );
      final again = gameParser.parseSgf(sgf);
      final move = again.children.single;
      expect(move.getListProperty('MA'), [Move.fromGtp('D4').sgf((9, 9))]);
      expect(move.getListProperty('SQ'), [Move.fromGtp('E5').sgf((9, 9))]);
      expect(sgf, contains(i18n.tr('SGF start message')));
      expect(again.note, isEmpty);
      expect(move.note, isEmpty);
    });

    test('analysis is saved for completely analysed nodes and loads back', () {
      final [root, b1, w2] = mainLine('(;SZ[9]KM[6.5];B[ee];W[cc])');
      // values exactly representable in half precision, the precision of KT data
      final ownership = List<double>.generate(squares, (i) => [1.0, -1.0, 0.5, -0.25, 0.125][i % 5]);
      final policy = policyWith({'D4': 0.5, 'E5': 0.25, 'pass': 0.0625})..[0] = -1;
      setFinal(
        root,
        katagoResult(
          visits: 400,
          winrate: 0.625,
          score: 2.5,
          moves: [
            mi('D4', 2.5, visits: 300, pv: ['D4', 'F6']),
            mi('C3', 1, visits: 50),
          ],
          ownership: ownership,
          policy: policy,
        ),
      );
      final perMove = katagoResult(moves: [mi('C7', -1, visits: 60)]);
      ((perMove['moveInfos'] as List)[0] as Map)['ownership'] = List.filled(squares, 0.5);
      setFinal(b1, perMove);
      // partial only; fewer visits than b1's C7, so it leaves that entry alone
      w2.setAnalysis(katagoResult(visits: 10, moves: [mi('G3', 0)]), null, false, null, true);

      final again = mainLine(root.sgf(const SgfSaveOptions(saveAnalysis: true)));
      expect(again[0].analysisFromSgf, hasLength(3));
      expect(again[1].analysisFromSgf, hasLength(3));
      expect(again[2].analysisFromSgf, isNull);
      expect(again[0].properties.containsKey('KT'), isFalse);

      expect(again[0].loadAnalysis(), isTrue);
      final loaded = again[0].analysis;
      expect(loaded['completed'], isTrue);
      expect(loaded['root'], root.analysis['root']);
      expect(loaded['moves'], root.analysis['moves']);
      expect((loaded['moves'] as Map).keys, ['D4', 'C3', 'E5']);
      expect(loaded['ownership'], ownership);
      expect(loaded['policy'], policy);
      expect(again[0].candidateMoves, root.candidateMoves);
      expect(again[0].policyRanking, root.policyRanking);

      // per-move ownership is not saved; a result without ownership or policy loads without them
      expect(again[1].loadAnalysis(), isTrue);
      expect(moveEntry(again[1], 'C7').containsKey('ownership'), isFalse);
      expect(moveEntry(again[1], 'C7')['scoreLead'], -1);
      expect(again[1].ownership, isNull);
      expect(again[1].policy, isNull);

      expect(again[2].loadAnalysis(), isFalse);
    });

    test('analysis from a newer format version is not loaded', () {
      final [root, b1] = mainLine('(;SZ[9];B[ee])');
      setFinal(b1, katagoResult(moves: [mi('C7', 1)]));
      final sgf = root.sgf(const SgfSaveOptions(saveAnalysis: true));
      final newer = mainLine(sgf.replaceFirst('KTV[$analysisFormatVersion]', 'KTV[9.0]'));
      expect(newer[1].loadAnalysis(), isFalse);
      expect(newer[1].analysisExists, isFalse);
      expect(mainLine(sgf)[1].loadAnalysis(), isTrue);
    });

    test('KT data that cannot be decoded is not loaded', () {
      final node = GameNode(properties: {'SZ': 9})..analysisFromSgf = ['not', 'base64', '!'];
      expect(node.loadAnalysis(), isFalse);
      expect(GameNode(properties: {'SZ': 9}).loadAnalysis(), isFalse);
    });

    test('notes and KT are read from SGF, generated comments are dropped', () {
      final parsed = gameParser.parseSgf(
        '(;SZ[9]KT[a][b][c];B[cc]C[my note${sgfSeparatorMarker}generated$sgfInternalCommentsMarker])',
      );
      expect(parsed.analysisFromSgf, ['a', 'b', 'c']);
      expect(parsed.properties.containsKey('KT'), isFalse);
      expect(parsed.children[0].note, 'my note');
      expect(parsed.children[0].properties.containsKey('C'), isFalse);
    });

    test('shortcuts are written with matching ids', () {
      final r = gameParser.parseSgf('(;SZ[9];B[aa];W[bb];B[cc];W[dd])');
      final from = r.children[0];
      final to = from.children[0].children[0].children[0];
      from.addShortcut(to);
      final sgf = r.sgf();
      final sid = RegExp(r'KTSID\[(\d+)\]').firstMatch(sgf)![1];
      final sf = RegExp(r'KTSF\[(\d+)\]').firstMatch(sgf)![1];
      expect(sid, sf);
      to.removeShortcut();
      expect(r.sgf().contains('KTSF'), isFalse);
    });
  });
}
