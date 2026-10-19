// The AI strategies wait for analyses that arrive later, and give up when the engine discards their queries. The
// differential script answers right away, so these paths are tested here.

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'fixtures_util.dart';
import 'game_script.dart';

Map<String, dynamic> result(GameNode node, {String move = 'D4'}) => {
  'id': 'QUERY:1',
  'rootInfo': {'visits': 10, 'winrate': 0.5, 'scoreLead': 0.5},
  'moveInfos': [
    {
      'move': move,
      'order': 0,
      'visits': 10,
      'winrate': 0.5,
      'scoreLead': 0.5,
      'prior': 0.2,
      'pv': [move],
    },
  ],
  'ownership': List.filled(81, 0.0),
  'policy': List.filled(82, 1 / 82),
};

void main() {
  late ScriptRunner runner;
  late Game game;

  setUp(() async {
    runner = ScriptRunner(loadFixture('game.json'));
    await runner.run({'op': 'new_game', 'sgf': '(;GM[1]FF[4]SZ[9])', 'props': null, 'analyze_fast': false});
    game = runner.game!;
  });

  test('waits for the regular analysis', () async {
    final generated = generateAiMove(game, aiDefault, {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(game.currentNode.isRoot, isTrue, reason: 'nothing to play yet');
    runner.engine.callbacks[0](result(game.root), false);
    final (move, node) = await generated;
    expect(move!.gtp(), 'D4');
    expect(node!.parent, same(game.root));
    expect(node.aiThoughts, contains('chose D4 as top move'));
  });

  test('waits for an extra query and ignores partial results', () async {
    runner.engine.callbacks[0](result(game.root, move: 'E5'), false);
    final generated = generateAiMove(game, aiAntimirror, {});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    runner.engine.callbacks.last(result(game.root, move: 'C3'), true); // partial results are ignored
    await Future<void>.delayed(const Duration(milliseconds: 30));
    runner.engine.callbacks.last(result(game.root, move: 'C3'), false);
    final (move, _) = await generated;
    expect(move!.gtp(), 'C3');
  });

  test('gives up when the queries are discarded', () async {
    final generated = generateAiMove(game, aiDefault, {});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    runner.engine.queryGeneration += 1; // a new game or an engine restart
    final (move, node) = await generated;
    expect(move, isNull);
    expect(node, isNull);
    expect(game.currentNode.isRoot, isTrue);
    expect(
      runner.host.events.where((e) => (e as List)[0] == 'log' && (e[1] as String).startsWith('Discarding AI move')),
      hasLength(1),
    );
  });
}
