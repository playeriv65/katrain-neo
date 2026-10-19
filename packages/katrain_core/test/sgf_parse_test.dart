// Differential tests: SGF, NGF and GIB parsing and writing must match pysgf (fixtures from tools/fixtures).

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'fixtures_util.dart';

Iterable<GoNode> preorder(GoNode root) sync* {
  final stack = [root];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    yield node;
    stack.addAll(node.children.reversed);
  }
}

/// pysgf writes handicap stones from a Python set, whose order changes from run to run (string hashes are
/// randomised), so setup stone lists are compared as sets.
const unorderedProperties = {'AB', 'AW'};

Map<String, Object?> canonicalProperties(Map<String, dynamic> properties) => {
  for (final e in properties.entries)
    e.key: unorderedProperties.contains(e.key) ? ([...(e.value as List)]..sort()) : e.value,
};

/// The SGF text with the values of AB and AW sorted, see [unorderedProperties].
String canonicalSgf(String sgf) => sgf.replaceAllMapped(RegExp(r'(?<![A-Z])(AB|AW)((?:\[[^\]]*\])+)'), (m) {
  final values = RegExp(r'\[[^\]]*\]').allMatches(m[2]!).map((v) => v[0]!).toList()..sort();
  return '${m[1]}${values.join()}';
});

Map<String, Object?> nodeInfo(GoNode node) => {
  'properties': canonicalProperties({for (final e in node.properties.entries) e.key: e.value}),
  'depth': node.depth,
  'move': node.move?.gtp(),
  'moves': [for (final m in node.moves) '${m.player}${m.gtp()}'],
  'placements': ([for (final m in node.placements) '${m.player}${m.gtp()}']..sort()),
  'clear_placements': ([for (final m in node.clearPlacements) m.gtp()]..sort()),
  'player': node.player,
  'next_player': node.nextPlayer,
  'is_pass': node.isPass,
  'children': node.children.length,
};

void main() {
  final fixtures = loadFixture('sgf_parse.json');

  for (final MapEntry(key: fileName, value: expectedRaw) in fixtures.entries) {
    final expected = expectedRaw as Map<String, dynamic>;
    group(fileName, () {
      late GoNode root;

      setUp(() {
        root = goParser.parseBytes(fixtureInput(fileName).readAsBytesSync(), fileName: fileName);
      });

      test('game info', () {
        expect([root.boardSize.$1, root.boardSize.$2], expected['board_size']);
        expect(root.komi, expected['komi']);
        expect(root.handicap, expected['handicap']);
        expect(root.ruleset, expected['ruleset']);
        expect(root.initialPlayer, expected['initial_player']);
        expect(root.nodesInTree.length, expected['nodes_in_tree']);
      });

      test('every node', () {
        final nodes = preorder(root).toList();
        final expectedNodes = expected['nodes'] as List;
        expect(nodes.length, expectedNodes.length);
        for (var i = 0; i < nodes.length; i++) {
          final expectedNode = Map<String, dynamic>.of(expectedNodes[i] as Map<String, dynamic>);
          expectedNode['properties'] = canonicalProperties(expectedNode['properties'] as Map<String, dynamic>);
          expect(nodeInfo(nodes[i]), expectedNode, reason: 'node $i');
        }
      });

      test('writes the same SGF', () {
        expect(canonicalSgf(root.sgf()), canonicalSgf(expected['sgf'] as String));
      });

      test('reparses its own SGF to the same tree', () {
        final again = goParser.parseSgf(root.sgf());
        expect(again.sgf(), root.sgf());
      });
    });
  }

  group('Move', () {
    test('GTP round trip', () {
      for (final gtp in ['A1', 'T19', 'J9', 'Z25', 'AA26', 'pass']) {
        expect(Move.fromGtp(gtp).gtp(), gtp);
      }
    });

    test('SGF coordinates', () {
      expect(Move.fromSgf('dd', (19, 19)).gtp(), 'D16');
      expect(Move.fromSgf('tt', (19, 19)).isPass, isTrue);
      expect(Move.fromSgf('tt', (21, 21)).isPass, isFalse);
      expect(Move(coords: (3, 15)).sgf((19, 19)), 'dd');
    });
  });
}
