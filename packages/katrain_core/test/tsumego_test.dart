// Differential tests: tsumego frames must match KaTrain's (fixtures from tools/fixtures/tsumego_fixtures.py).

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'fixtures_util.dart';

List<List<int>> ijList(List<(int, int)> ijs) => [
  for (final (i, j) in ijs) [i, j],
];

List<List<int>>? regionList(((int, int), (int, int))? r) => r == null
    ? null
    : [
        [r.$1.$1, r.$1.$2],
        [r.$2.$1, r.$2.$2],
      ];

void main() {
  final cases = (loadFixture('tsumego.json')['cases'] as List).cast<Map<String, dynamic>>();

  test('frames match KaTrain', () {
    for (final c in cases.where((c) => c.containsKey('sgf'))) {
      final reason = '${c['sgf']} komi ${c['komi']} black ${c['black_to_play']} ko ${c['ko']} margin ${c['margin']}';
      final game = BaseGame<GameNode>(gameParser.parseSgf(c['sgf'] as String));
      final bwBoard = [
        for (final line in game.board) [for (final ch in line) ch >= 0 ? game.chains[ch][0].player : '-'],
      ];
      final komi = (c['komi'] as num).toDouble();
      final blackToPlay = c['black_to_play'] as bool;
      final ko = c['ko'] as bool;
      final margin = c['margin'] as int;
      final (blacks, whites, region) = tsumegoFrame(bwBoard, komi, blackToPlay, ko, margin);
      expect(ijList(blacks), c['blacks'], reason: reason);
      expect(ijList(whites), c['whites'], reason: reason);
      expect(regionList(region), c['region'], reason: reason);

      final (node, katrainRegion) = tsumegoFrameFromKatrainGame(game, komi, blackToPlay, ko, margin);
      expect(node.parent, same(game.currentNode));
      expect(node.getListProperty('AB'), c['AB'], reason: reason);
      expect(node.getListProperty('AW'), c['AW'], reason: reason);
      expect(regionList(katrainRegion), c['katrain_region'], reason: reason);
    }
  });

  test('an empty board gets no frame', () {
    final c = cases.firstWhere((c) => c.containsKey('bw_board'));
    final board = [for (final row in c['bw_board'] as List) (row as List).cast<String>()];
    final (blacks, whites, region) = tsumegoFrame(board, 6.5, true, false, 4);
    expect([ijList(blacks), ijList(whites), regionList(region)], c['frame']);
  });
}
