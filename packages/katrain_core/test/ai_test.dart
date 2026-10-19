// The AI strategies on positions whose analysis the test makes up: each plays a legal move and follows its settings.
// Random strategies are checked by properties that hold for any random choice, over many runs.

import 'dart:convert';
import 'dart:math' as math;

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'support/ai_engine.dart';

final _defaultAiSettings = (jsonDecode(defaultConfigJson) as Map<String, dynamic>)['ai'] as Map<String, dynamic>;

/// KaTrain's default settings for [mode] (none for some), with [overrides].
Map<String, dynamic> settingsFor(String mode, [Map<String, dynamic> overrides = const {}]) => {
  ...?(_defaultAiSettings[mode] as Map<String, dynamic>?),
  ...overrides,
};

/// A game at the position after [moves], whose analysis is [analysis] (made from the game, so that a policy can
/// follow the board). Later positions are not analysed.
Future<(Game, AiHost, AiEngine)> analysedPosition(
  List<String> moves,
  Map<String, dynamic> Function(Game game) analysis, {
  int size = 9,
  double komi = 6.5,
  int handicap = 0,
}) async {
  final (game, host, engine) = newGame(size: size, komi: komi, handicap: handicap);
  await pump(); // the game asks for the analysis of the root as a later event
  playMoves(game, moves);
  engine.regularQueryFor(game.currentNode).answer(analysis(game));
  return (game, host, engine);
}

/// Generates and plays one AI move, which must be legal; returns it in GTP coordinates.
Future<String> aiMove(Game game, String mode, Map<String, dynamic> settings) async {
  final position = game.currentNode;
  final (move, node) = await generateAiMove(game, mode, settings);
  expect(node, isNotNull, reason: 'the move is played');
  expect(node!.parent, same(position));
  expect(node.move, move);
  expect(node.aiThoughts, isNotEmpty);
  return move!.gtp();
}

/// The AI's moves in [n] runs from the same position.
Future<List<String>> aiMoves(Game game, String mode, Map<String, dynamic> settings, int n) async {
  final position = game.currentNode;
  final moves = <String>[];
  for (var i = 0; i < n; i++) {
    moves.add(await aiMove(game, mode, settings));
    game.setCurrentNode(position);
  }
  return moves;
}

Map<String, int> counts(List<String> moves) {
  final result = <String, int>{};
  for (final m in moves) {
    result[m] = (result[m] ?? 0) + 1;
  }
  return result;
}

/// Distance in lines between two points (the larger of the horizontal and vertical distances).
int distance(String a, String b) {
  final (ax, ay) = Move.fromGtp(a).coords!;
  final (bx, by) = Move.fromGtp(b).coords!;
  return math.max((ax - bx).abs(), (ay - by).abs());
}

/// The line a point is on: 1 for the edge.
int line(String gtp, int size) {
  final (x, y) = Move.fromGtp(gtp).coords!;
  return [x, y, size - 1 - x, size - 1 - y].reduce(math.min) + 1;
}

/// The empty points within [radius] lines of [center].
List<String> pointsAround(Game game, String center, int radius) {
  final (size, _) = game.boardSize;
  final stones = {for (final s in game.stones) s.gtp()};
  return [
    for (var x = 0; x < size; x++)
      for (var y = 0; y < size; y++)
        if (distance(Move(coords: (x, y)).gtp(), center) <= radius && !stones.contains(Move(coords: (x, y)).gtp()))
          Move(coords: (x, y)).gtp(),
  ];
}

void main() {
  setUpAll(() => i18n.switchLang('en'));

  group('default', () {
    test('plays the top move of the engine', () async {
      final (game, _, _) = await analysedPosition(['E5', 'C3'], (_) => analysisResult([Cand('D4', 2), Cand('F6', 1)]));
      expect(await aiMove(game, aiDefault, {}), 'D4');
    });

    test('passes when the engine prefers to pass', () async {
      final (game, _, _) = await analysedPosition(['E5'], (_) => analysisResult([Cand('pass', -1), Cand('D4', -2)]));
      expect(await aiMove(game, aiDefault, {}), 'pass');
    });

    test('passes when the engine returns no moves and no policy', () async {
      final (game, _, _) = await analysedPosition(['E5'], (_) => analysisResult([], rootScore: 0));
      expect(await aiMove(game, aiDefault, {}), 'pass');
    });

    test('an unknown strategy falls back to the default one', () async {
      final (game, host, _) = await analysedPosition([], (_) => analysisResult([Cand('C3', 1), Cand('D4', 0)]));
      expect(await aiMove(game, 'ai:removed', {}), 'C3');
      expect(host.logged(outputError), [contains('ai:removed')]);
    });
  });

  group('engine queries', () {
    // The regular analysis prefers D4; the AI's own query prefers another move.
    Future<(Game, AiHost, AiEngine)> position() =>
        analysedPosition(['E5'], (_) => analysisResult([Cand('D4', -1), Cand('F6', -2)]));

    test('antimirror plays the top move of an antiMirror query', () async {
      final (game, _, engine) = await position();
      engine.onExtraQuery = (q) => q.answer(analysisResult([Cand('C7', -1.5), Cand('D4', -2)]));
      expect(await aiMove(game, aiAntimirror, {}), 'C7');
      final [query] = engine.extraQueries;
      expect(query.node, same(game.currentNode.parent));
      expect(query.extraSettings, {'antiMirror': true});
      expect(query.ownership, isFalse);
    });

    test('handicap plays the top move of a query with a playout doubling advantage', () async {
      final (game, _, engine) = await position();
      engine.onExtraQuery = (q) => q.answer(analysisResult([Cand('G4', -3), Cand('D4', -2)]));
      expect(await aiMove(game, aiHandicap, settingsFor(aiHandicap, {'automatic': false, 'pda': 1.5})), 'G4');
      expect(engine.extraQueries.single.extraSettings, {
        'playoutDoublingAdvantage': 1.5,
        'playoutDoublingAdvantagePla': 'BLACK',
      });
    });

    test('automatic handicap advantage grows with the handicap and is capped', () async {
      Future<num> pda(int handicap, double komi) async {
        final (game, _, engine) = await analysedPosition(
          [],
          (_) => analysisResult([Cand('D4', 0)]),
          size: 19,
          komi: komi,
          handicap: handicap,
        );
        engine.onExtraQuery = (q) => q.answer(analysisResult([Cand('C15', 0)]));
        await aiMove(game, aiHandicap, settingsFor(aiHandicap));
        return engine.extraQueries.single.extraSettings!['playoutDoublingAdvantage'] as num;
      }

      final even = await pda(0, 6.5);
      final two = await pda(2, 0.5);
      final four = await pda(4, 0.5);
      final nine = await pda(9, 0.5);
      expect(even, closeTo(0, 0.05), reason: 'an even game needs no advantage');
      expect(two, lessThan(even));
      expect(four, lessThan(two));
      expect(nine, -3, reason: 'capped at 3');
    });

    test('falls back to the default strategy when the query fails', () async {
      for (final mode in [aiAntimirror, aiHandicap]) {
        final (game, host, engine) = await position();
        engine.onExtraQuery = (q) => q.fail();
        expect(await aiMove(game, mode, settingsFor(mode)), 'D4', reason: mode);
        expect(host.logged(outputError), isNotEmpty, reason: mode);
      }
    });
  });

  group('jigo', () {
    test('plays the move that leads by the target score', () async {
      // Black to play: leads of 6, 1 and -3 points
      Map<String, dynamic> analysis(Game _) => analysisResult([Cand('D4', 6), Cand('E5', 1), Cand('C3', -3)]);
      final (game, _, _) = await analysedPosition([], analysis);
      expect(await aiMove(game, aiJigo, settingsFor(aiJigo)), 'E5');
      game.setCurrentNode(game.root);
      expect(await aiMove(game, aiJigo, {'target_score': 5}), 'D4');
    });

    test('aims at a small lead for white too', () async {
      // White to play: white leads by 6 or 1, or black leads by 3
      final (game, _, _) = await analysedPosition([
        'E5',
      ], (_) => analysisResult([Cand('D4', -6), Cand('F6', -1), Cand('C3', 3)]));
      expect(await aiMove(game, aiJigo, settingsFor(aiJigo)), 'F6');
    });
  });

  group('scoreloss', () {
    // Black to play: D4 is best, E5 loses 1 point, C3 loses 4.
    Future<(Game, AiHost, AiEngine)> position() =>
        analysedPosition([], (_) => analysisResult([Cand('D4', 3), Cand('E5', 2), Cand('C3', -1)]));

    test('plays the best move at a high strength', () async {
      final (game, _, _) = await position();
      expect(await aiMoves(game, aiScoreloss, {'strength': 20}, 20), everyElement('D4'));
    });

    test('plays every candidate at strength 0', () async {
      final (game, _, _) = await position();
      expect(counts(await aiMoves(game, aiScoreloss, {'strength': 0}, 200)).keys, unorderedEquals(['D4', 'E5', 'C3']));
    });

    test('plays moves less often the more points they lose', () async {
      final (game, _, _) = await position();
      final played = counts(await aiMoves(game, aiScoreloss, {'strength': 0.5}, 600));
      expect(played.keys.toSet(), containsAll(['D4', 'E5']));
      expect(played['D4']!, greaterThan(played['E5']!));
      expect(played['E5']!, greaterThan(played['C3'] ?? 0));
    });

    test('passes when the engine prefers to pass', () async {
      final (game, _, _) = await analysedPosition(['E5'], (_) => analysisResult([Cand('pass', -1), Cand('D4', -0.9)]));
      expect(await aiMoves(game, aiScoreloss, {'strength': 0}, 10), everyElement('pass'));
    });
  });

  group('simple ownership', () {
    List<double> owned(double value) => List.filled(81, value);

    test('plays the move that settles the most among those losing few points', () async {
      // Black to play. C3 settles most but loses 3 points; G7 settles everything but has too few visits.
      final (game, _, _) = await analysedPosition(
        [],
        (_) => analysisResult([
          Cand('D4', 3, ownership: owned(0.1)),
          Cand('E5', 2, ownership: owned(0.5)),
          Cand('C3', 0, ownership: owned(0.9)),
          Cand('G7', 2.5, visits: 1, ownership: owned(1)),
        ]),
      );
      expect(await aiMove(game, aiSimpleOwnership, settingsFor(aiSimpleOwnership)), 'E5');
    });

    test('avoids attachments', () async {
      // White to play after black E5: E6 attaches to it.
      Map<String, dynamic> analysis(Game _) =>
          analysisResult([Cand('E6', -1, ownership: owned(0)), Cand('C3', -0.5, ownership: owned(0))]);
      final (game, _, _) = await analysedPosition(['E5'], analysis);
      expect(await aiMove(game, aiSimpleOwnership, settingsFor(aiSimpleOwnership)), 'C3');
      game.setCurrentNode(game.currentNode.parent!);
      expect(await aiMove(game, aiSimpleOwnership, settingsFor(aiSimpleOwnership, {'attach_penalty': 0})), 'E6');
    });

    test('a move next to its own stone is no attachment', () async {
      // White to play after black E5, with a white stone at D6: E6 is a hane, not an attachment.
      final (game, _, _) = await analysedPosition([
        'E5',
        'D6',
        'G3',
      ], (_) => analysisResult([Cand('E6', -1, ownership: owned(0)), Cand('C3', -0.5, ownership: owned(0))]));
      expect(await aiMove(game, aiSimpleOwnership, settingsFor(aiSimpleOwnership)), 'E6');
    });

    test('avoids tenuki', () async {
      // Black to play after C3 and G7: A9 is far from both.
      Map<String, dynamic> analysis(Game _) =>
          analysisResult([Cand('A9', 1, ownership: owned(0)), Cand('D5', 0.7, ownership: owned(0))]);
      final (game, _, _) = await analysedPosition(['C3', 'G7'], analysis);
      expect(await aiMove(game, aiSimpleOwnership, settingsFor(aiSimpleOwnership)), 'D5');
      game.setCurrentNode(game.currentNode.parent!);
      expect(await aiMove(game, aiSimpleOwnership, settingsFor(aiSimpleOwnership, {'tenuki_penalty': 0})), 'A9');
    });

    test('passes when the engine prefers to pass', () async {
      final (game, _, _) = await analysedPosition([
        'E5',
      ], (_) => analysisResult([Cand('pass', -1, ownership: owned(0)), Cand('D4', -0.9, ownership: owned(-1))]));
      expect(await aiMove(game, aiSimpleOwnership, settingsFor(aiSimpleOwnership)), 'pass');
    });

    test('needs the ownership of each move', () async {
      final (game, _, _) = await analysedPosition([], (_) => analysisResult([Cand('D4', 1), Cand('E5', 0.5)]));
      await expectLater(generateAiMove(game, aiSimpleOwnership, settingsFor(aiSimpleOwnership)), throwsException);
    });
  });

  group('settle stones', () {
    test('plays the move that settles its stones', () async {
      // Black to play with stones at E5 (black) and C3 (white); G3 makes the black stone safer.
      final (game, _, _) = await analysedPosition(
        ['E5', 'C3'],
        (_) => analysisResult([
          Cand('D7', 1, ownership: ownershipOf(9, {'E5': 0.2, 'C3': -0.5})),
          Cand('G3', 0.5, ownership: ownershipOf(9, {'E5': 0.9, 'C3': -0.5})),
        ]),
      );
      expect(await aiMove(game, aiSettleStones, settingsFor(aiSimpleOwnership)), 'G3');
    });

    test('reads the ownership at its stones', () async {
      // As above with the black stone at C5: settling it should matter, not the ownership at E3.
      final (game, _, _) = await analysedPosition(
        ['C5', 'C3'],
        (_) => analysisResult([
          Cand('D7', 1, ownership: ownershipOf(9, {'C5': 0.2, 'C3': -0.5})),
          Cand('G3', 0.5, ownership: ownershipOf(9, {'C5': 0.9, 'C3': -0.5})),
        ]),
      );
      expect(await aiMove(game, aiSettleStones, settingsFor(aiSimpleOwnership)), 'G3');
    });
  });

  group('policy', () {
    test('plays the top policy move after the opening', () async {
      final (game, _, _) = await analysedPosition([
        'E5',
        'C3',
      ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {'D4': 0.4, 'F6': 0.3})));
      expect(await aiMoves(game, aiPolicy, {'opening_moves': 0}, 5), everyElement('D4'));
    });

    test('plays a policy weighted move in the opening', () async {
      final (game, _, _) = await analysedPosition([
        'E5',
        'C3',
      ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {'D4': 0.3, 'F6': 0.3, 'D6': 0.2})));
      final played = counts(await aiMoves(game, aiPolicy, settingsFor(aiPolicy), 100));
      expect(played.keys, everyElement(isIn(['D4', 'F6', 'D6'])));
      expect(played.length, greaterThan(1));
    });

    test('plays the top policy move, pass included, when pass is among the best moves', () async {
      final (game, _, _) = await analysedPosition([
        'E5',
        'C3',
      ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {'pass': 0.5, 'D4': 0.3})));
      expect(await aiMove(game, aiPolicy, {'opening_moves': 0}), 'pass');
    });

    test('without a policy the policy strategies play the top move of the engine', () async {
      final (game, _, _) = await analysedPosition(['E5', 'C3'], (_) => analysisResult([Cand('G7', 1)]));
      for (final mode in [aiPolicy, aiWeighted, aiPick, aiRank, aiLocal, aiTenuki, aiInfluence, aiTerritory]) {
        expect(await aiMove(game, mode, settingsFor(mode)), 'G7', reason: mode);
        game.setCurrentNode(game.currentNode.parent!);
      }
    });
  });

  group('weighted', () {
    test('plays moves above the lower bound, weighted by policy', () async {
      final (game, _, _) = await analysedPosition([
        'E5',
        'C3',
      ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {'D4': 0.4, 'F6': 0.3, 'C7': 0.2})));
      final played = counts(await aiMoves(game, aiWeighted, settingsFor(aiWeighted, {'lower_bound': 0.01}), 200));
      expect(played.keys, unorderedEquals(['D4', 'F6', 'C7']));
    });

    test('a larger weaken factor plays the top move less often', () async {
      final (game, _, _) = await analysedPosition([
        'E5',
        'C3',
      ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {'D4': 0.6, 'F6': 0.3, 'C7': 0.1})));
      Future<int> topMoves(num weakenFac) async =>
          counts(
            await aiMoves(
              game,
              aiWeighted,
              settingsFor(aiWeighted, {'weaken_fac': weakenFac, 'lower_bound': 0.05}),
              300,
            ),
          )['D4'] ??
          0;
      expect(await topMoves(0.5), greaterThan(await topMoves(3) + 50));
    });

    test(
      'plays the top move above the override, when pass is among the best, or when no move is above the bound',
      () async {
        Future<List<String>> movesWith(Map<String, double> policy, Map<String, dynamic> settings) async {
          final (game, _, _) = await analysedPosition([
            'E5',
            'C3',
          ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, policy)));
          return aiMoves(game, aiWeighted, settingsFor(aiWeighted, settings), 20);
        }

        expect(await movesWith({'D4': 0.6, 'F6': 0.3}, {'pick_override': 0.5}), everyElement('D4'));
        expect(await movesWith({'D4': 0.35, 'F6': 0.3, 'pass': 0.1}, {}), everyElement('D4'));
        expect(await movesWith({'D4': 0.35, 'F6': 0.3}, {'lower_bound': 0.5}), everyElement('D4'));
      },
    );
  });

  group('pick', () {
    test('plays the top policy move when it picks every move', () async {
      final (game, _, _) = await analysedPosition([
        'E5',
        'C3',
      ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {'D4': 0.1})));
      expect(await aiMoves(game, aiPick, settingsFor(aiPick, {'pick_frac': 1.0}), 10), everyElement('D4'));
    });

    test('plays all over the board when it picks one move', () async {
      final (game, _, _) = await analysedPosition([
        'E5',
        'C3',
      ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {'D4': 0.1})));
      final played = await aiMoves(game, aiPick, settingsFor(aiPick, {'pick_frac': 0.0, 'pick_n': 1}), 100);
      expect(played.toSet().length, greaterThan(20));
      expect(played, isNot(contains('pass')));
    });

    test('plays the top move above the override thresholds', () async {
      Future<List<String>> movesWith(Map<String, double> policy) async {
        final (game, _, _) = await analysedPosition([
          'E5',
          'C3',
        ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, policy)));
        final settings = settingsFor(aiPick, {'pick_frac': 0.0, 'pick_n': 1, 'pick_override_two': 0.7});
        return aiMoves(game, aiPick, settings, 20);
      }

      expect(await movesWith({'D4': 0.96}), everyElement('D4'));
      expect(await movesWith({'D4': 0.4, 'F6': 0.35}), everyElement('D4'));
    });

    test('plays the top policy move instead of a pick that is worse than passing', () async {
      final best = {'C7': 0.15, 'D4': 0.15, 'D6': 0.15, 'F4': 0.15, 'G6': 0.15};
      final (game, _, _) = await analysedPosition([
        'E5',
        'C3',
      ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {...best, 'pass': 0.05})));
      final played = await aiMoves(game, aiPick, settingsFor(aiPick, {'pick_frac': 0.0, 'pick_n': 1}), 30);
      expect(played, everyElement(isIn(best.keys)));
    });
  });

  group('rank', () {
    test('stronger ranks choose from more moves', () async {
      final (game, _, _) = await analysedPosition([
        'E5',
        'C3',
      ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {})));
      final legal = [
        for (final (p, m) in game.currentNode.policyRanking!)
          if (!m.isPass && p > 0) (p, m),
      ];
      final nMoves = [
        for (final kyu in [15, 10, 5, 0, -2]) RankStrategy(game, {'kyu_rank': kyu}).getNMoves(legal),
      ];
      for (var i = 1; i < nMoves.length; i++) {
        expect(nMoves[i], greaterThan(nMoves[i - 1]), reason: 'n moves by rank: $nMoves');
      }
      expect(nMoves.first, greaterThanOrEqualTo(1));
      expect(nMoves.last, lessThanOrEqualTo(legal.length));
    });

    test('stronger ranks play the best move more often', () async {
      final (game, _, _) = await analysedPosition([
        'E5',
        'C3',
      ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {'D4': 0.1})));
      Future<int> topMoves(num kyuRank) async =>
          counts(await aiMoves(game, aiRank, {'kyu_rank': kyuRank}, 200))['D4'] ?? 0;
      expect(await topMoves(-2), greaterThan(await topMoves(15) + 40));
    });

    test('plays an obvious move at any rank', () async {
      final (game, _, _) = await analysedPosition([
        'E5',
        'C3',
      ], (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {'D4': 0.85})));
      expect(await aiMoves(game, aiRank, {'kyu_rank': 15}, 20), everyElement('D4'));
    });
  });

  group('local and tenuki', () {
    // On 19x19 after Q16 and D4, with the best policy move far away at Q4 and slightly better moves near D4.
    Future<(Game, AiHost, AiEngine)> position({bool uniform = false}) {
      Map<String, double> policy(Game g) =>
          uniform ? {} : {'Q4': 0.3, for (final p in pointsAround(g, 'D4', 2)) p: 0.01};
      return analysedPosition(
        ['Q16', 'D4'],
        (g) => analysisResult([Cand('Q4', 1)], policy: boardPolicy(g, policy(g))),
        size: 19,
      );
    }

    test('local plays near the last move', () async {
      final (game, _, _) = await position();
      final played = await aiMoves(game, aiLocal, settingsFor(aiLocal), 40);
      for (final move in played) {
        expect(distance(move, 'D4'), lessThanOrEqualTo(2), reason: move);
      }
    });

    test('tenuki plays away from the last move', () async {
      final (game, _, _) = await position(uniform: true);
      final played = await aiMoves(game, aiTenuki, settingsFor(aiTenuki), 40);
      for (final move in played) {
        expect(distance(move, 'D4'), greaterThanOrEqualTo(5), reason: move);
      }
    });

    test('local weights fall with the distance from the last move, tenuki weights rise', () async {
      final (game, _, _) = await position(uniform: true);
      final policyGrid = varToGrid(game.currentNode.policy!, (19, 19));
      Map<String, num> weights(String mode) {
        final (coords, _) = generateLocalTenukiWeights(mode, {'stddev': 3}, policyGrid, game.currentNode, (19, 19));
        return {for (final (_, w, x, y) in coords) Move(coords: (x, y)).gtp(): w};
      }

      final local = weights(aiLocal);
      final tenuki = weights(aiTenuki);
      expect(local['E4']!, greaterThan(local['G4']!));
      expect(local['G4']!, greaterThan(local['Q10']!));
      expect(tenuki['E4']!, lessThan(tenuki['G4']!));
      expect(tenuki['G4']!, lessThan(tenuki['Q10']!));
      expect(local.keys, isNot(contains('D4')), reason: 'occupied points have no policy');
    });

    test('without a last move they play a policy weighted move', () async {
      for (final moves in [
        <String>[],
        ['E5', 'pass'],
      ]) {
        final (game, _, _) = await analysedPosition(
          moves,
          (g) => analysisResult([Cand('G7', 1)], policy: boardPolicy(g, {'D4': 0.5, 'F6': 0.45})),
        );
        for (final mode in [aiLocal, aiTenuki]) {
          final played = await aiMoves(game, mode, settingsFor(mode), 20);
          expect(played, everyElement(isIn(['D4', 'F6'])), reason: '$mode after $moves');
        }
      }
    });
  });

  group('influence and territory', () {
    Future<(Game, AiHost, AiEngine)> emptyBoard() =>
        analysedPosition([], (g) => analysisResult([Cand('Q16', 1)], policy: boardPolicy(g, {})), size: 19);

    test('influence plays away from the edges', () async {
      final (game, _, _) = await emptyBoard();
      for (final move in await aiMoves(game, aiInfluence, settingsFor(aiInfluence), 40)) {
        expect(line(move, 19), greaterThanOrEqualTo(4), reason: move);
      }
    });

    test('territory plays near the edges', () async {
      final (game, _, _) = await emptyBoard();
      for (final move in await aiMoves(game, aiTerritory, settingsFor(aiTerritory), 40)) {
        expect(line(move, 19), lessThanOrEqualTo(3), reason: move);
      }
    });

    test('the weights favour the lines beyond or within the threshold', () {
      final policyGrid = List.generate(19, (_) => List.filled(19, 0.01));
      // along the middle row, from the edge to the centre
      Map<int, num> weightByLine(String mode) {
        final settings = {'threshold': 3.5, 'line_weight': 10};
        final (coords, _) = generateInfluenceTerritoryWeights(mode, settings, policyGrid, (19, 19));
        return {
          for (final (_, w, x, y) in coords)
            if (y == 9 && x <= 9) x + 1: w,
        };
      }

      final influence = weightByLine(aiInfluence);
      final territory = weightByLine(aiTerritory);
      for (var l = 1; l < 10; l++) {
        expect(influence[l + 1]!, greaterThanOrEqualTo(influence[l]!), reason: 'influence, line $l');
        expect(territory[l + 1]!, lessThanOrEqualTo(territory[l]!), reason: 'territory, line $l');
      }
      expect(influence[4], 1);
      expect(influence[3]!, lessThan(1));
      expect(territory[3], 1);
      expect(territory[4]!, lessThan(1));
    });
  });

  group('human and pro', () {
    // White to play after black E5; the regular analysis prefers D4, also by policy.
    Future<(Game, AiHost, AiEngine)> position({bool policy = true}) => analysedPosition([
      'E5',
    ], (g) => analysisResult([Cand('D4', -1)], policy: policy ? boardPolicy(g, {'D4': 0.5}) : null));

    List<double> humanPolicy(Map<String, double> values) {
      final p = List.filled(82, 0.0);
      values.forEach((gtp, v) => p[policyIndex(gtp, 9)] = v);
      return p;
    }

    test('asks for the human profile of the settings', () async {
      final profiles = {
        'preaz_8k': (aiHuman, {'human_kyu_rank': 8, 'modern_style': false}),
        'rank_3d': (aiHuman, {'human_kyu_rank': -2, 'modern_style': true}),
        'rank_1d': (aiHuman, {'human_kyu_rank': 0, 'modern_style': true}),
        'proyear_1914': (aiPro, {'pro_year': 1914}),
      };
      for (final MapEntry(key: profile, value: (mode, settings)) in profiles.entries) {
        final (game, _, engine) = await position();
        engine.onExtraQuery = (q) => q.answer(analysisResult([], humanPolicy: humanPolicy({'C3': 1})));
        expect(await aiMove(game, mode, settings), 'C3');
        final query = engine.extraQueries.single;
        expect(query.extraSettings!['humanSLProfile'], profile);
        expect(query.includePolicy, isTrue);
      }
    });

    test('plays moves the human policy gives a chance', () async {
      final (game, _, engine) = await position();
      engine.onExtraQuery = (q) => q.answer(analysisResult([], humanPolicy: humanPolicy({'C3': 0.5, 'G7': 0.5})));
      final played = counts(await aiMoves(game, aiHuman, settingsFor(aiHuman), 60));
      expect(played.keys, unorderedEquals(['C3', 'G7']));
    });

    test('passes when the human policy only passes', () async {
      final (game, _, engine) = await position();
      engine.onExtraQuery = (q) => q.answer(analysisResult([], humanPolicy: humanPolicy({'pass': 1})));
      expect(await aiMove(game, aiHuman, settingsFor(aiHuman)), 'pass');
    });

    test('falls back to the top policy move, or a pass, when the query fails', () async {
      final (game, host, engine) = await position();
      engine.onExtraQuery = (q) => q.fail();
      expect(await aiMove(game, aiHuman, settingsFor(aiHuman)), 'D4');
      expect(host.logged(outputError), isNotEmpty);

      final (noPolicy, _, failing) = await position(policy: false);
      failing.onExtraQuery = (q) => q.fail();
      expect(await aiMove(noPolicy, aiPro, settingsFor(aiPro)), 'pass');
    });

    test('needs a human policy', () async {
      final (game, _, engine) = await position();
      engine.onExtraQuery = (q) => q.answer(analysisResult([Cand('C3', -1)]));
      await expectLater(generateAiMove(game, aiHuman, settingsFor(aiHuman)), throwsException);
    });
  });

  group('rank estimation', () {
    test('full strength strategies are 9 dan', () {
      for (final mode in [aiDefault, aiHandicap, aiJigo, aiAntimirror, aiPro]) {
        expect(aiRankEstimation(mode, settingsFor(mode)), 9, reason: mode);
      }
    });

    test('rank settings give the rank, with 0 for 1 kyu and 1 for 1 dan', () {
      expect(aiRankEstimation(aiRank, {'kyu_rank': 4}), -3);
      expect(aiRankEstimation(aiRank, {'kyu_rank': -2}), 3);
      expect(aiRankEstimation(aiHuman, {'human_kyu_rank': 8}), -7);
      expect(aiRankEstimation(aiHuman, {'human_kyu_rank': 0}), 1);
    });

    test('strategies without strength settings have a fixed rank', () {
      expect(aiRankEstimation(aiPolicy, settingsFor(aiPolicy)), 5);
      expect(aiRankEstimation(aiSimpleOwnership, settingsFor(aiSimpleOwnership)), 2);
      expect(aiRankEstimation(aiSettleStones, {}), 2);
    });

    test('weighted gets weaker with the weaken factor, scoreloss stronger with the strength', () {
      final weighted = [
        for (final f in [0.5, 1.0, 1.5, 2.0, 3.0]) aiRankEstimation(aiWeighted, {'weaken_fac': f}),
      ];
      final scoreloss = [
        for (final s in [0.0, 0.1, 0.3, 0.5, 1.0]) aiRankEstimation(aiScoreloss, {'strength': s}),
      ];
      for (var i = 1; i < 5; i++) {
        expect(weighted[i], lessThan(weighted[i - 1]), reason: 'weighted $weighted');
        expect(scoreloss[i], greaterThan(scoreloss[i - 1]), reason: 'scoreloss $scoreloss');
      }
      expect(aiRankEstimation(aiWeighted, {'weaken_fac': 10}), weighted.last, reason: 'clamped to the calibration');
      expect(aiRankEstimation(aiScoreloss, {'strength': 0}), closeTo(-8.278, 0.001), reason: 'about 9 kyu');
    });

    test('pick strategies get stronger with more picked moves', () {
      for (final mode in [aiPick, aiLocal, aiTenuki, aiInfluence, aiTerritory]) {
        num rank(num frac, num n) => aiRankEstimation(mode, {'pick_frac': frac, 'pick_n': n});
        for (final n in [0, 5, 10, 25, 50]) {
          final byFrac = [
            for (final f in [0.0, 0.1, 0.3, 0.5, 1.0]) rank(f, n),
          ];
          for (var i = 1; i < byFrac.length; i++) {
            expect(byFrac[i], greaterThanOrEqualTo(byFrac[i - 1]), reason: '$mode n=$n: $byFrac');
          }
        }
        for (final f in [0.0, 0.1, 0.3, 0.5]) {
          final byN = [
            for (final n in [0, 5, 10, 25, 50]) rank(f, n),
          ];
          for (var i = 1; i < byN.length; i++) {
            expect(byN[i], greaterThanOrEqualTo(byN[i - 1]), reason: '$mode frac=$f: $byN');
          }
        }
        expect(rank(0.5, 10), greaterThan(rank(0, 0)), reason: mode);
      }
      expect(aiRankEstimation(aiPick, {'pick_frac': 1.0, 'pick_n': 0}), 5, reason: 'the strongest calibrated rank');
    });

    test('default settings span the beginner to dan range', () {
      final ranks = {for (final mode in aiStrategies) mode: aiRankEstimation(mode, settingsFor(mode))};
      for (final MapEntry(key: mode, value: rank) in ranks.entries) {
        expect(rank, inInclusiveRange(-20, 9), reason: mode);
      }
    });
  });

  group('game report', () {
    // Black E5 (best move), white C3 (loses 2), black G7 (loses 5), white D4 (best move, loses 0.4 by the score).
    // Scores are black's lead after each move.
    final scores = [0.5, 0.5, 2.5, -2.5, -2.1];
    final topMoves = ['E5', 'D4', 'F6', 'D4', 'C7'];

    Future<Game> reviewedGame() async {
      final (game, _, _) = newGame(
        positions: (node) {
          final depth = node.depth;
          return analysisResult([
            Cand(topMoves[depth], scores[depth], prior: 0.6),
            Cand('B2', scores[depth] - 3, prior: 0.1),
          ], rootScore: scores[depth]);
        },
      );
      await pump();
      playMoves(game, ['E5', 'C3', 'G7', 'D4']);
      return game;
    }

    test('point losses, means and top move agreement by player', () async {
      final game = await reviewedGame();
      game.setCurrentNode(game.root);
      final (stats, _, losses) = gameReport(game, [12, 6, 3, 1.5, 0.5, 0]);
      expect(losses['B'], [closeTo(0, 1e-9), closeTo(5, 1e-9)]);
      expect(losses['W'], [closeTo(2, 1e-9), closeTo(0.4, 1e-9)]);
      expect(stats['B']!['mean_ptloss'], closeTo(2.5, 1e-9));
      expect(stats['W']!['mean_ptloss'], closeTo(1.2, 1e-9));
      expect(stats['B']!['ai_top_move'], 0.5, reason: 'E5 was the top move, G7 was not');
      expect(stats['W']!['ai_top_move'], 0.5, reason: 'D4 was the top move, C3 was not');
      for (final bw in ['B', 'W']) {
        expect(stats[bw]!['accuracy'], inInclusiveRange(0, 100));
        expect(stats[bw]!['ai_top5_move'], greaterThanOrEqualTo(stats[bw]!['ai_top_move']!));
      }
      expect(stats['B']!['accuracy'], lessThan(stats['W']!['accuracy']!), reason: 'black lost more points');
      expect(stats['B']!['weighted_ptloss'], greaterThan(stats['W']!['weighted_ptloss']!));
    });

    test('the histogram counts moves by evaluation class, smallest losses first', () async {
      final game = await reviewedGame();
      final (_, histogram, _) = gameReport(game, [12, 6, 3, 1.5, 0.5, 0]);
      expect(histogram, [
        {'B': 1, 'W': 1}, // E5, D4
        {'B': 0, 'W': 0},
        {'B': 0, 'W': 1}, // C3
        {'B': 1, 'W': 0}, // G7
        {'B': 0, 'W': 0},
        {'B': 0, 'W': 0},
      ]);
    });

    test('covers the main line beyond the current move, and the depth filter limits it', () async {
      final game = await reviewedGame();
      game.setCurrentNode(game.root.children.single);
      final (_, _, losses) = gameReport(game, [12, 6, 3, 1.5, 0.5, 0]);
      expect([...losses['B']!, ...losses['W']!], hasLength(4));
      // move numbers below 3% of the 81 points (2.43, rounded up to 3): moves 1 and 2
      final (_, _, opening) = gameReport(game, [12, 6, 3, 1.5, 0.5, 0], depthFilter: [0, 0.03]);
      expect(opening['B'], [closeTo(0, 1e-9)]);
      expect(opening['W'], [closeTo(2, 1e-9)]);
    });

    test('a perfect game is 100% accurate and gains count as no loss', () async {
      // Each move gains half a point over the expected score.
      final (game, _, _) = newGame(
        positions: (node) {
          final score = node.depth.isOdd ? 0.5 : 0.0;
          return analysisResult([Cand('D4', score, prior: 0.5)], rootScore: score);
        },
      );
      await pump();
      playMoves(game, ['E5', 'C3']);
      final (stats, _, losses) = gameReport(game, [12, 6, 3, 1.5, 0.5, 0]);
      expect(losses, {
        'B': [0],
        'W': [0],
      });
      expect(stats['B']!['accuracy'], 100);
      expect(stats['W']!['mean_ptloss'], 0);
    });

    test('moves without analysis are left out', () async {
      final (game, _, _) = newGame(positions: (node) => node.depth == 3 ? null : analysisResult([Cand('D4', 0)]));
      await pump();
      playMoves(game, ['E5', 'C3', 'G7']);
      final (stats, _, losses) = gameReport(game, [12, 6, 3, 1.5, 0.5, 0]);
      expect(losses['B'], hasLength(1), reason: 'G7 has no analysis');
      expect(losses['W'], hasLength(1));

      final (empty, _, _) = newGame();
      final (emptyStats, emptyHistogram, _) = gameReport(empty, [12, 6, 3, 1.5, 0.5, 0]);
      expect(emptyStats, {'B': <String, double>{}, 'W': <String, double>{}});
      expect(emptyHistogram, everyElement({'B': 0, 'W': 0}));
      expect(stats['B'], isNotEmpty);
    });
  });
}
