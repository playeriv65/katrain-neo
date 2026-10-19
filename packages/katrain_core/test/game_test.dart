// Behaviour of Game: navigation, insert mode, the analysis it asks the engine for, self-play, teaching undo, results
// and saving. The engine is a fake that records requests; tests answer them with made-up results.

import 'dart:io';

import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'support/fake_engine.dart';
import 'support/fake_host.dart';

/// The moves from the root to [node], e.g. `BC3 WG7`.
String line(GameNode node) =>
    [for (final n in node.nodesFromRoot.skip(1)) '${n.move!.player}${n.move!.gtp()}'].join(' ');

void main() {
  setUpAll(() => i18n.switchLang('en'));
  tearDownAll(() => i18n.switchLang(defaultLanguage));

  late FakeHost host;
  late FakeEngine engine;

  setUp(() {
    host = FakeHost()..setConfig('game/size', 9);
    engine = FakeEngine();
  });

  /// A game shown by the host, after its initial analysis requests went out.
  Future<Game> newGame({String? sgf, bool analyzeFast = false, Map<String, Object?>? properties, DateTime? now}) async {
    final game = Game(
      host,
      engine,
      moveTree: sgf == null ? null : gameParser.parseSgf(sgf),
      analyzeFast: analyzeFast,
      gameProperties: properties,
      now: now,
    );
    host.game = game;
    await Future<void>.delayed(Duration.zero);
    return game;
  }

  /// Plays [moves] (GTP coordinates, colours alternating) and returns the new nodes.
  List<GameNode> play(Game game, String moves, {bool analyze = true}) => [
    for (final gtp in moves.split(' '))
      game.play(Move.fromGtp(gtp, player: game.currentNode.nextPlayer), analyze: analyze)!,
  ];

  /// Answers the last analysis request for [node]: the position is worth [scoreLead] for Black.
  void evaluate(
    GameNode node,
    double scoreLead, {
    List<Map<String, dynamic>> moves = const [],
    List<double>? ownership,
    List<double>? policy,
    bool partial = false,
  }) => engine
      .lastRequestFor(node)
      .answer(
        analysisResult(scoreLead: scoreLead, moves: moves, ownership: ownership, policy: policy),
        partial: partial,
      );

  group('a new game', () {
    test('takes size, komi and rules from the settings and is dated by its creation time', () async {
      host
        ..setConfig('game/komi', 7.5)
        ..setConfig('game/rules', 'chinese');
      final game = await newGame(now: DateTime(2024, 3, 5, 7, 8, 9));
      expect(game.boardSize, (9, 9));
      expect(game.komi, 7.5);
      expect(game.root.getProperty('RU'), 'chinese');
      expect(game.gameId, '2024-03-05 07 08 09');
      expect(game.root.getProperty('DT'), game.gameId);
      expect(game.externalGame, isFalse);
      expect(game.currentNode, same(game.root));
    });

    test('places the handicap stones from the settings, and White moves first', () async {
      host.setConfig('game/handicap', 2);
      final game = await newGame();
      expect(game.root.placements, hasLength(2));
      expect(game.stones.map((m) => m.player), everyElement('B'));
      expect(game.currentNode.nextPlayer, 'W');
    });

    test('game properties override the settings', () async {
      final game = await newGame(properties: {'KM': 0.5, 'PB': 'Alice'});
      expect(game.komi, 0.5);
      expect(game.root.getProperty('PB'), 'Alice');
    });

    test('a loaded game is external unless KaTrain wrote it, and gets the default rules', () async {
      final other = await newGame(sgf: '(;SZ[9]AP[OtherApp];B[cc])');
      expect(other.externalGame, isTrue);
      expect(other.root.getProperty('RU'), 'japanese');
      expect((await newGame(sgf: '(;SZ[9]AP[KaTrain:1.16.0];B[cc])')).externalGame, isFalse);
      expect((await newGame(sgf: '(;SZ[9]AP[$writerName:$writerVersion];B[cc])')).externalGame, isFalse);
    });

    test('every node is analysed once the game is shown', () async {
      final game = Game(host, engine, moveTree: gameParser.parseSgf('(;SZ[9];B[cc];W[gg];B[cg])'), analyzeFast: true);
      expect(engine.requests, isEmpty, reason: 'the analysis starts after the game is created');
      await Future<void>.delayed(Duration.zero);
      expect([for (final r in engine.requests) r.node], game.root.nodesInTree);
      for (final r in engine.requests) {
        expect(r.priority, priorityGameAnalysis);
        expect(r.analyzeFast, isTrue);
      }
    });

    test('restores the shortcuts saved in the file', () async {
      final game = await newGame(sgf: '(;SZ[9];B[cc]KTSID[7];W[gg];B[cg]KTSF[7])');
      final from = game.root.children[0];
      final to = from.children[0].children[0];
      expect(to.shortcutFrom, same(from));
      expect([for (final (node, _) in from.shortcutsTo) node], [same(to)]);
    });
  });

  group('navigation', () {
    late Game game;
    late List<GameNode> main;

    setUp(() async {
      game = await newGame();
      main = play(game, 'C3 G7 C7 G3 E5');
    });

    test('undo and redo move back and forth along the line, and stop at its ends', () {
      game.undo();
      expect(game.currentNode, same(main[3]));
      game.undo(2);
      expect(game.currentNode, same(main[1]));
      expect(game.stones, hasLength(2));
      game.redo();
      expect(game.currentNode, same(main[2]));
      expect(game.stones, hasLength(3));
      game.redo(10);
      expect(game.currentNode, same(main[4]));
      game.undo(100);
      expect(game.currentNode, same(game.root));
      expect(game.stones, isEmpty);
    });

    test('undo to the branch goes back to the last point with several moves', () {
      game.setCurrentNode(main[1]);
      final variation = play(game, 'E5 F5 D5');
      game.undo('branch');
      expect(game.currentNode, same(main[1]));
      game.setCurrentNode(main[3]);
      game.undo('branch');
      expect(game.currentNode, same(main[1]));
      game.setCurrentNode(variation[0]);
      game.undo('branch');
      expect(game.currentNode, same(main[1]));
    });

    test('undo to the main branch goes back to where this line left it', () {
      game.setCurrentNode(main[0]);
      final variation = play(game, 'E5 E3');
      game.setCurrentNode(variation[0]);
      play(game, 'D4 F4');
      game.undo('main-branch');
      expect(game.currentNode, same(main[0]));

      game.setCurrentNode(main[4]);
      game.undo('main-branch');
      expect(game.currentNode, same(main[4]), reason: 'already on the main branch');
    });

    group('stopping on mistakes', () {
      setUp(() {
        // Black's C7 loses 5 points
        evaluate(game.root, 0);
        for (final (node, score) in [
          (main[0], 0.0),
          (main[1], 0.0),
          (main[2], -5.0),
          (main[3], -5.0),
          (main[4], -5.0),
        ]) {
          evaluate(node, score);
        }
        expect(main[2].pointsLost, 5);
      });

      test('undo stops before the last human mistake', () {
        game.undo(9999, 3);
        expect(game.currentNode, same(main[1]));
        game.undo(9999, 3);
        expect(game.currentNode, same(game.root));
      });

      test('undo stops before the mistake when standing on it', () {
        game.setCurrentNode(main[2]);
        game.undo(9999, 3);
        expect(game.currentNode, same(main[1]));
      });

      test('undo ignores smaller losses and the mistakes of the AI', () {
        game.undo(9999, 6);
        expect(game.currentNode, same(game.root));
        game.setCurrentNode(main[4]);
        host.setPlayer('B', playerAi);
        game.undo(9999, 3);
        expect(game.currentNode, same(game.root));
      });

      test('redo stops before the next human mistake', () {
        game.setCurrentNode(game.root);
        game.redo(9999, 3);
        expect(game.currentNode, same(main[1]));
      });

      test('redo stays put when there is no further mistake', () {
        game.setCurrentNode(main[1]);
        game.redo(9999, 3);
        expect(game.currentNode, same(main[1]));
      });
    });

    test('redo jumps along a shortcut and undo comes back along it', () {
      main[0].addShortcut(main[3]);
      game.setCurrentNode(main[0]);
      game.redo();
      expect(game.currentNode, same(main[3]));
      game.undo();
      expect(game.currentNode, same(main[0]));
    });

    test('switching to another branch shows its position', () {
      game.setCurrentNode(main[1]);
      final variation = play(game, 'E5 F5');
      game.setCurrentNode(main[3]);
      expect({for (final m in game.stones) m.gtp()}, {'C3', 'G7', 'C7', 'G3'});
      game.setCurrentNode(variation[1]);
      expect({for (final m in game.stones) m.gtp()}, {'C3', 'G7', 'E5', 'F5'});
      expect(game.currentNode.nextPlayer, 'B');
    });

    test('syncBranch adds the moves that are missing and leaves the current node', () {
      final node = game.syncBranch([
        Move.fromGtp('C3', player: 'B'),
        Move.fromGtp('E5', player: 'W'),
        Move.fromGtp('E3', player: 'B'),
      ]);
      expect(line(node), 'BC3 WE5 BE3');
      expect(node.parent!.parent, same(main[0]), reason: 'the existing first move is reused');
      expect(main[0].children, hasLength(2));
      expect(game.currentNode, same(main[4]));
    });
  });

  group('playing', () {
    test('a move is played and its position analysed', () async {
      final game = await newGame();
      final requests = engine.requestsDuring(() => play(game, 'C3'));
      final node = game.currentNode;
      expect(line(node), 'BC3');
      expect(requests, hasLength(1));
      expect(requests[0].node, same(node));
      expect(requests[0].priority, priorityDefault);
      expect(requests[0].analyzeFast, isFalse);
      expect(requests[0].regionOfInterest, isNull);
      evaluate(node, 1.5, moves: [moveInfo('E5', scoreLead: 1.5)]);
      expect(node.analysisComplete, isTrue);
      expect(node.score, 1.5);
    });

    test('a move can be played without analysis', () async {
      final game = await newGame();
      expect(engine.requestsDuring(() => play(game, 'C3', analyze: false)), isEmpty);
    });

    test('the engine for the colour to move does the analysis', () async {
      final black = FakeEngine(), white = FakeEngine();
      final game = Game.withEngines(host, {'B': black, 'W': white});
      host.game = game;
      await Future<void>.delayed(Duration.zero);
      expect([for (final r in black.requests) r.node], [same(game.root)]);
      play(game, 'C3');
      expect([for (final r in white.requests) r.node], [same(game.currentNode)]);
    });

    test('an illegal move is refused and the position stays as it was', () async {
      final game = await newGame();
      final node = play(game, 'C3')[0];
      expect(() => game.play(Move.fromGtp('C3', player: 'W')), throwsA(isA<IllegalMoveException>()));
      expect(() => game.play(Move(coords: (9, 0), player: 'W')), throwsA(isA<IllegalMoveException>()));
      expect(game.currentNode, same(node));
      expect(game.stones, [Move.fromGtp('C3', player: 'B')]);
    });
  });

  group('region of interest', () {
    late Game game;

    setUp(() async => game = await newGame());

    test('is stored with its corners ordered; a single point or the whole board clears it', () {
      game.setRegionOfInterest([5, 2, 7, 1]);
      expect(game.regionOfInterest, [2, 5, 1, 7]);
      expect(host.lastStatus?.message, '');
      game.setRegionOfInterest([3, 3, 4, 4]);
      expect(game.regionOfInterest, isNull);
      game.setRegionOfInterest([2, 5, 1, 7]);
      game.setRegionOfInterest([8, 0, 0, 8]);
      expect(game.regionOfInterest, isNull);
    });

    test('a move is analysed quickly on the whole board, then within the region', () {
      game.setRegionOfInterest([2, 5, 1, 7]);
      final requests = engine.requestsDuring(() => play(game, 'C3'));
      expect([for (final r in requests) r.analyzeFast], [true, false]);
      expect(
        [for (final r in requests) r.regionOfInterest],
        [
          null,
          [2, 5, 1, 7],
        ],
      );
      final node = game.currentNode;
      requests[1].answer(analysisResult(scoreLead: 3, moves: [moveInfo('D4')]));
      expect(node.analysisExists, isFalse, reason: 'a search within the region is not the evaluation');
      expect(node.analysis['moves'], contains('D4'));
      requests[0].answer(analysisResult(scoreLead: 1));
      expect(node.score, 1);
    });

    test('with regionRoot the region search alone is asked for, and it is the evaluation', () {
      game
        ..setRegionOfInterest([2, 5, 1, 7])
        ..regionRoot = true;
      final requests = engine.requestsDuring(() => play(game, 'C3'));
      expect(requests, hasLength(1));
      expect(requests[0].analyzeFast, isFalse);
      expect(requests[0].regionOfInterest, [2, 5, 1, 7]);
      requests[0].answer(analysisResult(scoreLead: 3, moves: [moveInfo('D4')]));
      expect(game.currentNode.score, 3);
    });
  });

  group('analysis requests', () {
    test('analyzeAllNodes throws the analysis away and asks again for every node', () async {
      final game = await newGame();
      final nodes = [game.root, ...play(game, 'C3 G7')];
      for (final node in nodes) {
        evaluate(node, 0);
      }
      final requests = engine.requestsDuring(() => game.analyzeAllNodes(priority: 5, analyzeFast: true));
      expect([for (final r in requests) r.node], nodes);
      expect(requests.map((r) => (r.priority, r.analyzeFast)), everyElement((5, true)));
      expect(nodes.map((n) => n.analysisExists), everyElement(isFalse));
    });

    test('resetCurrentAnalysis drops the queries for the current node and asks again', () async {
      final game = await newGame();
      final node = play(game, 'C3')[0];
      evaluate(node, 2);
      final requests = engine.requestsDuring(game.resetCurrentAnalysis);
      expect(engine.terminations, [same(node)]);
      expect(node.analysisExists, isFalse);
      expect([for (final r in requests) r.node], [same(node)]);
    });
  });

  group('extra analysis', () {
    late Game game;
    late GameNode node;

    setUp(() async {
      game = await newGame();
      evaluate(game.root, 0);
      node = play(game, 'C3')[0];
    });

    test('stop ends pondering and drops every query, once for each engine', () async {
      final black = FakeEngine(), white = FakeEngine();
      final twoEngines = Game.withEngines(host, {'B': black, 'W': white});
      host.pondering = true;
      twoEngines.analyzeExtra('stop');
      expect(host.pondering, isFalse);
      for (final e in [black, white]) {
        expect(e.ponderingStops, 1);
        expect(e.terminations, [null]);
      }
      game.analyzeExtra('stop');
      expect(engine.ponderingStops, 1);
      expect(engine.terminations, [null]);
    });

    test('ponder keeps analysing the current position without a time limit', () {
      final requests = engine.requestsDuring(() => game.analyzeExtra('ponder'));
      expect(requests, hasLength(1));
      final r = requests[0];
      expect(
        (r.node, r.ponder, r.timeLimit, r.priority, r.regionOfInterest),
        (node, true, false, priorityExtraAnalysis, null),
      );
    });

    test('ponder stays within the region; with regionRoot that is the evaluation', () {
      game
        ..setRegionOfInterest([0, 4, 0, 4])
        ..regionRoot = true;
      final requests = engine.requestsDuring(() => game.analyzeExtra('ponder'));
      expect(requests.single.regionOfInterest, [0, 4, 0, 4]);
      requests.single.answer(analysisResult(scoreLead: 4));
      expect(node.score, 4);
    });

    test('extra asks for the maximum visits on top of what was asked for so far', () {
      final first = engine.requestsDuring(() => game.analyzeExtra('extra')).single;
      expect((first.node, first.visits, first.timeLimit, first.priority), (node, 1000, false, priorityExtraAnalysis));
      expect(host.lastStatus!.type, statusAnalysis);
      expect(host.lastStatus!.message, contains('1000'));
      expect(engine.requestsDuring(() => game.analyzeExtra('extra')).single.visits, 1500);
    });

    group('game re-analysis', () {
      late List<GameNode> nodes;

      setUp(() async {
        game = await newGame(sgf: '(;SZ[9];B[cc];W[gg];B[cg];W[gc];B[ee])');
        nodes = game.root.nodesInTree;
      });

      test('analyses every node with more visits than the least analysed one has', () {
        final requests = engine.requestsDuring(() => game.analyzeExtra('game'));
        expect([for (final r in requests) r.node], nodes);
        for (final r in requests) {
          expect((r.visits, r.priority, r.timeLimit, r.reportEvery), (1000, -1000000, false, null));
        }
        expect(host.lastStatus!.message, contains('1000'));
        expect(host.lastStatus!.type, statusAnalysis);
      });

      test('uses the visits it is given', () {
        final requests = engine.requestsDuring(() => game.analyzeExtra('game', visits: 50));
        expect(requests.map((r) => r.visits), everyElement(50));
      });

      test('a move range analyses those moves only', () {
        final requests = engine.requestsDuring(() => game.analyzeExtra('game', moveRange: [2, 4]));
        expect([for (final r in requests) r.node.depth], [2, 3, 4]);
      });

      test('a reversed move range is the same range, and the status names it', () {
        final forward = engine.requestsDuring(() => game.analyzeExtra('game', moveRange: [1, 3]));
        final message = host.lastStatus!.message;
        final reversed = engine.requestsDuring(() => game.analyzeExtra('game', moveRange: [3, 1]));
        expect(forward, hasLength(3));
        expect([for (final r in reversed) r.node], [for (final r in forward) same(r.node)]);
        expect(host.lastStatus!.message, message);
      });

      test('mistakes only analyses the positions before and after a big loss', () {
        // Black's B[cg] (the third move) loses 5 points; the trainer's mistake threshold is 3
        for (final (n, score) in [for (final (i, n) in nodes.indexed) (n, i >= 3 ? -5.0 : 0.0)]) {
          evaluate(n, score);
        }
        final requests = engine.requestsDuring(() => game.analyzeExtra('game', mistakesOnly: true));
        expect([for (final r in requests) r.node], [same(nodes[2]), same(nodes[3])]);
      });
    });

    group('sweep', () {
      test('without a policy, every empty point is searched with the fast visits', () {
        final requests = engine.requestsDuring(() => game.analyzeExtra('sweep'));
        expect(requests, hasLength(80));
        expect(
          {for (final r in requests) r.nextMove},
          {
            for (var x = 0; x < 9; x++)
              for (var y = 0; y < 9; y++)
                if ((x, y) != (2, 2)) Move(coords: (x, y), player: 'W'),
          },
        );
        for (final r in requests) {
          expect((r.node, r.visits, r.priority, r.timeLimit), (node, 25, prioritySweep, false));
        }
        expect(host.lastStatus!.message, contains('25'));
      });

      test('with a policy, the legal moves are searched from the most likely one, skipping those searched enough', () {
        final policy = List.filled(82, -1.0);
        policy[0] = 0.5; // A9
        policy[1] = 0.2; // B9
        policy[80] = 0.3; // J1
        evaluate(node, 0, moves: [moveInfo('A9', visits: 30)], policy: policy);
        final requests = engine.requestsDuring(() => game.analyzeExtra('sweep'));
        expect([for (final r in requests) r.nextMove!.gtp()], ['J1', 'B9']);
      });
    });

    group('equalize', () {
      test('waits for the analysis to finish', () {
        evaluate(node, 0, moves: [moveInfo('D5', visits: 100), moveInfo('E5', visits: 40)], partial: true);
        expect(engine.requestsDuring(() => game.analyzeExtra('equalize')), isEmpty);
        expect(host.lastStatus!.type, statusInfo);
        expect(host.lastStatus!.atNode, same(node));
      });

      test('brings every candidate up to the visits of the most searched one', () {
        evaluate(
          node,
          0,
          moves: [moveInfo('D5', visits: 100), moveInfo('E5', visits: 40), moveInfo('F5', visits: 100)],
        );
        final requests = engine.requestsDuring(() => game.analyzeExtra('equalize'));
        expect(requests, hasLength(1));
        final r = requests.single;
        expect(
          (r.nextMove, r.visits, r.priority, r.timeLimit),
          (Move.fromGtp('E5', player: 'W'), 100, priorityEqualize, false),
        );
        expect(host.lastStatus!.message, contains('100'));
        r.answer(analysisResult(scoreLead: -2, visits: 100, moves: [moveInfo('F6')]));
        expect((node.analysis['moves'] as Map)['E5'], containsPair('visits', 100));
      });
    });

    test('alternative looks for other moves and refines the current candidates quickly', () {
      evaluate(node, 0, moves: [moveInfo('D5', visits: 10), moveInfo('E5', visits: 30)]);
      final requests = engine.requestsDuring(() => game.analyzeExtra('alternative'));
      expect(
        [for (final r in requests) (r.findAlternatives, r.nextMove?.gtp(), r.visits, r.priority)],
        [(true, null, null, priorityAlternatives), (false, 'D5', 25, priorityEqualize)],
      );
      expect(requests.map((r) => r.timeLimit), everyElement(isFalse));
    });

    test('alternative also waits for the analysis to finish', () {
      evaluate(node, 0, moves: [moveInfo('D5', visits: 10)], partial: true);
      expect(engine.requestsDuring(() => game.analyzeExtra('alternative')), isEmpty);
    });

    test('local equalizes the candidates without waiting for the analysis to finish', () {
      evaluate(node, 0, moves: [moveInfo('D5', visits: 10), moveInfo('E5', visits: 30)], partial: true);
      final requests = engine.requestsDuring(() => game.analyzeExtra('local'));
      expect([for (final r in requests) (r.nextMove?.gtp(), r.visits)], [('D5', 30)]);
    });

    test('an unknown mode is an error', () {
      expect(() => game.analyzeExtra('deeper'), throwsArgumentError);
    });
  });

  group('self-play', () {
    test('to the end: the AI moves form one shortcut from the current node until a pass', () async {
      final game = await newGame();
      final start = play(game, 'C3')[0];
      final moves = ['E5', 'D4', 'F4'];
      var request = engine.requestsDuring(() => game.selfplay('end')).single;
      expect((request.node, request.analyzeFast, request.priority), (start, true, priorityDefault));
      for (final move in moves) {
        final next = engine.requestsDuring(
          () => request.answer(analysisResult(moves: [moveInfo(move), moveInfo('A1')])),
        );
        request = next.single;
        final added = request.node;
        expect(added.move!.gtp(), move);
        expect(added.aiThoughts, contains('self-play'));
        expect(game.currentNode, same(start), reason: 'self-play happens off screen');
      }
      final last = request.node;
      expect(line(last), 'BC3 WE5 BD4 WF4');
      expect([for (final (to, _) in start.shortcutsTo) to], [same(last)]);
      expect(last.parent!.shortcutFrom, isNull, reason: 'only the latest move is the shortcut target');
      expect(host.moveTreeRedraws, 3);

      expect(engine.requestsDuring(() => request.answer(analysisResult(moves: [moveInfo('pass')]))), isEmpty);
      expect(game.currentNode, same(last), reason: 'the game ended: show it');
    });

    test('stops once another game is shown', () async {
      final game = await newGame();
      final start = play(game, 'C3')[0];
      final request = engine.requestsDuring(() => game.selfplay('end')).single;
      host.game = null;
      expect(engine.requestsDuring(() => request.answer(analysisResult(moves: [moveInfo('E5')]))), isEmpty);
      expect(start.children, isEmpty);
    });

    test('to set up a position: plays to the move number, moving the score towards the target', () async {
      final game = await newGame();
      var request = engine.requestsDuring(() => game.selfplay(3, targetBAdvantage: 30)).single;
      expect((request.node, request.visits), (game.root, 25));
      expect(request.extraSettings, {'wideRootNoise': 0.03});
      // far from the target, the candidate closest to the score aimed at for that move is played:
      // 10 points after move 1, 20 after move 2, 30 after move 3
      final steps = [
        (0.0, [('C3', 2.0), ('D3', 9.0), ('E3', 20.0)], 'D3'),
        (9.0, [('C7', 12.0), ('D7', 19.0), ('E7', 25.0)], 'D7'),
        (19.0, [('G3', 29.0), ('G4', 35.0)], 'G3'),
      ];
      for (final (i, (score, candidates, expected)) in steps.indexed) {
        request = engine
            .requestsDuring(
              () => request.answer(
                analysisResult(
                  scoreLead: score,
                  moves: [for (final (m, lead) in candidates) moveInfo(m, scoreLead: lead)],
                ),
              ),
            )
            .single;
        expect(request.node.move!.gtp(), expected);
        expect(game.currentNode, same(request.node), reason: 'the moves are shown as they are made');
        expect(host.lastStatus!.message, allOf(contains('${i + 1}'), contains('3')));
      }
      final last = request.node;
      expect(engine.requestsDuring(() => request.answer(analysisResult(scoreLead: 29))), isEmpty);
      expect(game.currentNode, same(last));
      expect(line(last), 'BD3 WD7 BG3');
    });
  });

  group('teaching undo', () {
    late Game game;

    setUp(() async {
      host.setPlayer('B', playerHuman, playingTeaching);
      game = await newGame();
      evaluate(game.root, 0);
    });

    /// Black plays [gtp] and loses [lost] points with it.
    GameNode blunder(String gtp, double lost) {
      final node = play(game, gtp)[0];
      evaluate(node, node.parent!.score! - lost);
      return node;
    }

    test('undoes a move that lost a lot of points, and says why', () {
      final node = blunder('C3', 5);
      game.analyzeUndo(node);
      expect(game.currentNode, same(game.root));
      expect(node.autoUndo, isTrue);
      expect(host.lastStatus!.type, statusTeaching);
      expect(host.lastStatus!.message, allOf(contains('C3'), contains('5.0')));
      expect(host.stateUpdates, 1);
    });

    test('keeps a move that lost little', () {
      final node = blunder('C3', 1);
      game.analyzeUndo(node);
      expect(game.currentNode, same(node));
      expect(node.autoUndo, isFalse);
    });

    test('undoes a medium loss by chance', () {
      final lucky = blunder('C3', 2)..undoThreshold = 0.7;
      game.analyzeUndo(lucky);
      expect(lucky.autoUndo, isFalse);
      expect(game.currentNode, same(lucky));

      final reply = play(game, 'G7')[0];
      evaluate(reply, lucky.score!);
      final unlucky = blunder('C7', 2)..undoThreshold = 0.3;
      game.analyzeUndo(unlucky);
      expect(unlucky.autoUndo, isTrue);
      expect(game.currentNode, same(reply));
    });

    test('lets the second try stand, and puts the undone move last', () {
      final first = blunder('C3', 5);
      game.analyzeUndo(first);
      final second = blunder('D3', 5);
      game.analyzeUndo(second);
      expect(second.autoUndo, isFalse);
      expect(game.currentNode, same(second));
      expect(game.root.orderedChildren, [same(second), same(first)]);
      game.setCurrentNode(game.root);
      game.redo();
      expect(game.currentNode, same(second));
    });

    test('only judges the current move, once its analysis is complete, and only once', () {
      final partial = play(game, 'C3')[0];
      evaluate(partial, -5, partial: true);
      game.analyzeUndo(partial);
      expect(partial.autoUndo, isNull);

      evaluate(partial, -1);
      game.analyzeUndo(partial);
      expect(partial.autoUndo, isFalse);
      evaluate(partial, -5);
      game.analyzeUndo(partial);
      expect(partial.autoUndo, isFalse, reason: 'already judged');
      expect(game.currentNode, same(partial));

      final later = play(game, 'G7')[0];
      evaluate(later, -5);
      game.setCurrentNode(partial);
      game.analyzeUndo(later);
      expect(later.autoUndo, isNull);

      game.setCurrentNode(game.root);
      game.analyzeUndo(game.root);
      expect(game.root.autoUndo, isNull);
    });

    test('follows the trainer settings', () {
      host.setConfig('trainer/num_undo_prompts', [0, 0, 0, 0, 0, 0]);
      final kept = blunder('C3', 20);
      game.analyzeUndo(kept);
      expect(kept.autoUndo, isFalse);

      game.setCurrentNode(game.root);
      host.setConfig('trainer/num_undo_prompts', [2, 0, 0, 0, 0, 0]);
      final undone = blunder('D3', 20);
      game.analyzeUndo(undone);
      expect(undone.autoUndo, isTrue, reason: 'two tries allowed');
    });
  });

  group('end of the game', () {
    test('a resigned game has its end state as the result', () async {
      final game = await newGame();
      play(game, 'C3');
      expect(game.endResult, isNull);
      game.currentNode.endState = 'B+R';
      expect(game.endResult, 'B+R');
    });

    test('one pass does not end the game', () async {
      final game = await newGame();
      play(game, 'C3 pass');
      expect(game.endResult, isNull);
    });

    test("after two passes the engine's score, to half a point, is the result", () async {
      host.setConfig('game/rules', 'chinese');
      final game = await newGame();
      final nodes = play(game, 'C3 pass pass');
      evaluate(nodes[2], 3.3);
      expect(game.endResult, 'B+3.5?');
      evaluate(nodes[2], -2.2);
      expect(game.endResult, 'W+2.0?');
    });

    test('without a score the game just ends', () async {
      final game = await newGame();
      play(game, 'C3 pass pass');
      expect(game.manualScore, isNull);
      expect(game.endResult, i18n.tr('board-game-end'));
    });

    group('japanese counting', () {
      // Black's wall on column E, White's on F, a dead white stone at B2 inside Black's area
      const sgf =
          '(;SZ[9]RU[japanese]KM[6.5]AB[ea][eb][ec][ed][ee][ef][eg][eh][ei]'
          'AW[fa][fb][fc][fd][fe][ff][fg][fh][fi][bh];B[];W[])';

      test('counts territory and dead stones from the ownership', () async {
        final game = await newGame(sgf: sgf);
        final passes = game.root.nodesInTree.skip(1).toList();
        final ownership = [
          for (var y = 0; y < 9; y++)
            for (var x = 0; x < 9; x++) x <= 4 ? 1.0 : -1.0,
        ];
        for (final node in passes) {
          evaluate(node, 0, ownership: ownership);
        }
        game.setCurrentNode(passes.last);
        // Black: 35 points of territory and 2 for the dead stone; White: 27 points and komi
        expect(game.endResult, 'B+3.5');
      });

      test('gives no result when too much of the board is unclear', () async {
        final game = await newGame(sgf: sgf);
        final passes = game.root.nodesInTree.skip(1).toList();
        for (final node in passes) {
          evaluate(node, 0, ownership: List.filled(81, 0.5));
        }
        game.setCurrentNode(passes.last);
        expect(game.manualScore, isNull);
        expect(game.endResult, i18n.tr('board-game-end'));
      });
    });
  });

  group('saving', () {
    test('the file name has the players and the game id, without characters files cannot have', () async {
      final game = await newGame(now: DateTime(2024, 3, 5, 7, 8, 9));
      host.playersInfo['B']!.name = 'Ann/Lee?';
      host.playersInfo['W']!.name = 'Bob:"X"';
      expect(game.generateFilename(), '${writerName}_AnnLee vs BobX 2024-03-05 07 08 09.sgf');
      expect(game.root.getProperty('PB'), 'Ann/Lee?');
    });

    test('AI players are named after their strategy, with their rank', () async {
      final game = await newGame();
      host.setPlayer('W', playerAi, aiDefault);
      host.playersInfo['W']!.calculatedRank = 5;
      final filename = game.generateFilename();
      expect(game.root.getProperty('PW'), startsWith('AI (KataGo)'));
      expect(game.root.getProperty('WR'), rankLabel(5));
      expect(game.root.getProperty('BR'), isNull);
      expect(filename, contains(' vs AI (KataGo) '));
      expect(filename, isNot(contains(sgfInternalCommentsMarker)));
    });

    test("another program's game keeps its player names", () async {
      final game = await newGame(sgf: '(;SZ[9]PB[Shusaku]PW[Gennan];B[cc])', now: DateTime(2024, 3, 5));
      host.playersInfo['B']!.name = 'Me';
      expect(game.generateFilename(), '${writerName}_Shusaku vs Gennan 2024-03-05 00 00 00.sgf');
    });

    test('the result is written once there is one', () async {
      final game = await newGame();
      play(game, 'C3');
      game.updateRootProperties();
      expect(game.root.getProperty('RE'), isNull);
      game.currentNode.endState = 'W+R';
      game.updateRootProperties();
      expect(game.root.getProperty('RE'), 'W+R');
    });

    test('the saved SGF has the moves and names its writer', () async {
      final game = await newGame();
      play(game, 'C3 G7 C7');
      final saved = gameParser.parseSgf(game.sgfToSave());
      expect(line(saved.nodesInTree.last), 'BC3 WG7 BC7');
      expect(saved.getProperty('AP'), '$writerName:$writerVersion');
      expect(saved.getProperty('SZ'), '9');
    });

    group('feedback comments', () {
      late Game game;

      setUp(() async {
        game = await newGame();
        evaluate(game.root, 0, moves: [moveInfo('E5')]);
        final nodes = play(game, 'C3 G7');
        evaluate(nodes[0], -5); // Black loses 5 points
        evaluate(nodes[1], -5); // White's move loses nothing
      });

      /// The comment of each move in the saved SGF.
      List<String?> comments([Map<String, dynamic>? trainer]) {
        final raw = SgfParser<GoNode>(({GoNode? parent}) => GoNode(parent: parent)).parseSgf(game.sgfToSave(trainer));
        return [for (final n in raw.nodesInTree.skip(1)) n.getProperty('C')];
      }

      Map<String, dynamic> trainer(Map<String, dynamic> changes) => {
        ...(host.settings['trainer'] as Map<String, dynamic>),
        ...changes,
      };

      test('are written for the mistakes the trainer settings ask for', () {
        final [black, white] = comments();
        expect(black, contains(i18n.tr('Info:point loss').replaceAll('{points_lost:.1f}', '5.0')));
        expect(white, isNull);
      });

      test('are left out when the settings say so', () {
        expect(comments(trainer({'save_feedback': List.filled(6, false)})), [null, null]);
      });

      test("are left out for the AI's moves unless asked for", () {
        host.setPlayer('B', playerAi);
        expect(comments(trainer({'eval_show_ai': false})), [null, null]);
        expect(comments(trainer({'eval_show_ai': true}))[0], isNotNull);
      });
    });

    test('with save_analysis the analysis is saved, and used instead of analysing again', () async {
      final game = await newGame();
      evaluate(game.root, 0.5, moves: [moveInfo('C3', scoreLead: 0.5)]);
      final nodes = play(game, 'C3 G7');
      evaluate(nodes[0], -5, moves: [moveInfo('G7', scoreLead: -5)]);
      final sgf = game.sgfToSave({...(host.settings['trainer'] as Map<String, dynamic>), 'save_analysis': true});

      final loaded = Game(host, engine, moveTree: gameParser.parseSgf(sgf));
      final requests = <AnalysisRequest>[];
      final before = engine.requests.length;
      await Future<void>.delayed(Duration.zero);
      requests.addAll(engine.requests.skip(before));
      final [root, first, second] = loaded.root.nodesInTree;
      expect([for (final r in requests) r.node], [same(second)], reason: 'only the move without analysis');
      expect(root.score, 0.5);
      expect(first.score, -5);
      expect(first.pointsLost, 5.5);
    });

    test('writeSgf writes the file and remembers its name', () async {
      final game = await newGame();
      play(game, 'C3');
      final dir = Directory.systemTemp.createTempSync('katrain_neo_game_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final filename = '${dir.path}${Platform.pathSeparator}sub${Platform.pathSeparator}game.sgf';
      final message = writeSgf(game, filename);
      expect(File(filename).readAsStringSync(), game.sgfToSave());
      expect(game.sgfFilename, filename);
      expect(message, contains(filename));
    });
  });

  group('insert mode', () {
    late Game game;
    late List<GameNode> main;

    setUp(() async {
      game = await newGame();
      main = play(game, 'C3 G7 C7 G3');
      game.setCurrentNode(main[0]);
    });

    test('starts before the next move, and navigation waits until it ends', () {
      game.setInsertMode(true);
      expect(game.insertMode, isTrue);
      expect(game.insertAfter, same(main[1]));
      expect(host.insertNode, same(main[1]));
      expect(host.lastStatus!.type, statusInfo);
      expect((host.boardRedraws, host.moveTreeRedraws), (1, 1));

      game.setCurrentNode(game.root);
      expect(game.currentNode, same(main[0]));
      expect(host.lastStatus!.type, statusError);
      game.redo();
      expect(game.currentNode, same(main[0]));
    });

    test('cannot start at the end of a line', () {
      game.setCurrentNode(main[3]);
      game.setInsertMode(true);
      expect(game.insertMode, isFalse);
      expect(host.insertNode, isNull);
    });

    test('toggles', () {
      game.setInsertMode('toggle');
      expect(game.insertMode, isTrue);
      game.setInsertMode('toggle');
      expect(game.insertMode, isFalse);
    });

    test('the inserted moves go before the rest of the line, which is copied after them', () {
      game.setInsertMode(true);
      play(game, 'E5 E3');
      final inserted = game.currentNode;
      final requests = engine.requestsDuring(() => game.setInsertMode(false));
      expect(game.insertMode, isFalse);
      expect(host.insertNode, isNull);
      expect(game.currentNode, same(inserted));
      expect(line(main[0].children[1].nodesInTree.last), 'BC3 WE5 BE3 WG7 BC7 WG3');
      expect(line(main[3]), 'BC3 WG7 BC7 WG3', reason: 'the original line is kept');
      expect(host.lastStatus!.message, contains('3'));
      final newNodes = {for (final r in requests) r.node};
      expect(newNodes, containsAll(inserted.nodesInTree));
      expect(requests.map((r) => r.analyzeFast), everyElement(isTrue));
    });

    test('ending keeps the analysis of the nodes that were already there', () {
      for (final node in [game.root, ...main]) {
        evaluate(node, 0);
      }
      game.setInsertMode(true);
      play(game, 'E5 E3');
      final requests = engine.requestsDuring(() => game.setInsertMode(false));
      expect([game.root, ...main].map((n) => n.analysisExists), everyElement(isTrue));
      expect({for (final r in requests) r.node}, isNot(contains(main[3])));
    });

    test('copying stops at the first move that is no longer legal', () {
      game.setInsertMode(true);
      play(game, 'E5 G3'); // Black now has G3, where White played later
      game.setInsertMode(false);
      final copiedLine = main[0].children[1].nodesInTree.last;
      expect(line(copiedLine), 'BC3 WE5 BG3 WG7 BC7');
      expect(host.lastStatus!.message, contains('2'));
    });

    test('moves that were inserted are not copied again', () {
      game.setInsertMode(true);
      play(game, 'E5 C7');
      game.setInsertMode(false);
      expect(line(main[0].children[1].nodesInTree.last), 'BC3 WE5 BC7 WG7 WG3');
    });

    test('undo deletes an inserted move, but not the line it goes into', () {
      game.setInsertMode(true);
      final inserted = play(game, 'E5')[0];
      expect(main[0].children, [same(main[1]), same(inserted)]);
      game.undo();
      expect(game.currentNode, same(main[0]));
      expect(main[0].children, [same(main[1])]);
      game.undo();
      expect(game.currentNode, same(main[0]));
      expect(main[0].children, [same(main[1])]);
    });

    test('ending without inserting anything changes nothing', () {
      game.setInsertMode(true);
      final requests = engine.requestsDuring(() => game.setInsertMode(false));
      expect(requests, isEmpty);
      expect(main[0].children, [same(main[1])]);
      expect(host.lastStatus!.message, '');
    });
  });
}
