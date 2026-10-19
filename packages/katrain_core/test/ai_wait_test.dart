// The AI waits for analyses that arrive later, gives up when the engine discards its queries, falls back when an
// extra query fails, and does not play when the position changed while it was thinking.

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'support/ai_engine.dart';

void main() {
  late Game game;
  late AiHost host;
  late AiEngine engine;
  late GameNode position;

  // White to play after black E5; nothing is analysed until the test answers.
  setUp(() async {
    (game, host, engine) = newGame();
    await pump();
    playMoves(game, ['E5']);
    position = game.currentNode;
  });

  Map<String, dynamic> regular() => analysisResult([Cand('D4', -1), Cand('F6', -2)], policy: boardPolicy(game, {}));

  void answerPosition() => engine.regularQueryFor(position).answer(regular());

  test('waits for the analysis of the position', () async {
    final generated = generateAiMove(game, aiDefault, {});
    await pump(50);
    expect(game.currentNode, same(position), reason: 'nothing to play yet');
    answerPosition();
    final (move, node) = await generated;
    expect(move!.gtp(), 'D4');
    expect(node!.parent, same(position));
    expect(game.currentNode, same(node));
    expect(node.aiThoughts, isNotEmpty);
  });

  test('ignores partial results', () async {
    final generated = generateAiMove(game, aiDefault, {});
    await pump(20);
    engine.regularQueryFor(position).answer(analysisResult([Cand('C3', -3)]), partial: true);
    await pump(30);
    expect(game.currentNode, same(position), reason: 'a partial analysis is not complete');
    answerPosition();
    final (move, _) = await generated;
    expect(move!.gtp(), 'D4');
  });

  test('waits for an extra query, ignoring its partial results, and for the regular analysis', () async {
    final generated = generateAiMove(game, aiAntimirror, {});
    await pump(20);
    final query = engine.extraQueries.single;
    query.answer(analysisResult([Cand('G4', -1)]), partial: true);
    await pump(30);
    expect(game.currentNode, same(position));
    query.answer(analysisResult([Cand('C7', -1)]));
    await pump(30);
    expect(game.currentNode, same(position), reason: 'the position is not analysed yet');
    answerPosition();
    final (move, _) = await generated;
    expect(move!.gtp(), 'C7');
  });

  test('a human query that arrives later', () async {
    final generated = generateAiMove(game, aiHuman, {'human_kyu_rank': 5, 'modern_style': true});
    await pump(30);
    final humanPolicy = List.filled(82, 0.0)..[policyIndex('G3', 9)] = 1;
    engine.extraQueries.single.answer(analysisResult([], humanPolicy: humanPolicy));
    final (move, _) = await generated;
    expect(move!.gtp(), 'G3');
  });

  group('falls back when an extra query fails later', () {
    for (final mode in [aiAntimirror, aiHandicap]) {
      test(mode, () async {
        answerPosition();
        final generated = generateAiMove(game, mode, {'automatic': true, 'pda': 0});
        await pump(30);
        engine.extraQueries.single.fail();
        final (move, _) = await generated;
        expect(move!.gtp(), 'D4', reason: 'the top move of the regular analysis');
        expect(host.logged(outputError), isNotEmpty);
      });
    }

    test(aiHuman, () async {
      answerPosition();
      final generated = generateAiMove(game, aiHuman, {'human_kyu_rank': 5, 'modern_style': true});
      await pump(30);
      engine.extraQueries.single.fail();
      final (move, _) = await generated;
      expect(move!.gtp(), position.policyRanking!.first.$2.gtp(), reason: 'the top policy move');
    });
  });

  group('gives up when the queries are discarded', () {
    final cases = {'regular analysis': aiDefault, 'antimirror query': aiAntimirror, 'human query': aiHuman};
    for (final MapEntry(key: waitingFor, value: mode) in cases.entries) {
      test(waitingFor, () async {
        if (mode != aiDefault) answerPosition();
        final generated = generateAiMove(game, mode, {'human_kyu_rank': 5, 'modern_style': true});
        await pump(30);
        engine.discardQueries(); // a new game or an engine restart
        final (move, node) = await generated;
        expect(move, isNull);
        expect(node, isNull);
        expect(game.currentNode, same(position));
        expect(position.children, isEmpty);
      });
    }
  });

  test('does not play when the position changed while thinking', () async {
    final generated = generateAiMove(game, aiDefault, {});
    await pump(20);
    game.setCurrentNode(game.root);
    answerPosition();
    final (move, node) = await generated;
    expect(move!.gtp(), 'D4', reason: 'the move it thought of');
    expect(node, isNull);
    expect(game.currentNode, same(game.root));
    expect(position.children, isEmpty);
  });
}
