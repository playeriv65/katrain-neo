// Differential tests: board positions, captures and illegal moves must match KaTrain's BaseGame
// (fixtures from tools/fixtures).

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'fixtures_util.dart';

void main() {
  group('main lines of the test records', () {
    final fixtures = loadFixture('rules_mainline.json');
    for (final MapEntry(key: fileName, value: expectedRaw) in fixtures.entries) {
      final expected = expectedRaw as Map<String, dynamic>;
      test(fileName, () {
        final root = goParser.parseBytes(fixtureInput(fileName).readAsBytesSync(), fileName: fileName);
        final game = BaseGame<GoNode>(root);
        expect((root.getListProperty('AB') ?? <String>[]).toList()..sort(), expected['root_ab']);
        final steps = expected['steps'] as List;
        var node = root;
        for (var i = 0; i < steps.length; i++) {
          game.setCurrentNode(node);
          final step = steps[i] as Map<String, dynamic>;
          expect(game.boardString, step['board'], reason: 'board after node $i');
          expect(game.prisonerCount, step['prisoners'], reason: 'prisoners after node $i');
          expect(game.stones.length, step['stones'], reason: 'stones after node $i');
          if (node.children.isEmpty) break;
          node = node.children[0];
        }
      });
    }
  });

  group('random move attempts', () {
    final scenarios = loadFixture('rules_random.json')['scenarios'] as List;
    for (var s = 0; s < scenarios.length; s++) {
      final scenario = scenarios[s] as Map<String, dynamic>;
      test('#$s ${scenario['size']}x${scenario['size']} ${scenario['rules']}', () {
        final root = GoNode(properties: {'SZ': scenario['size'], 'RU': scenario['rules'], 'KM': 6.5});
        final game = BaseGame<GoNode>(root);
        final attempts = scenario['attempts'] as List;
        for (var i = 0; i < attempts.length; i++) {
          final attempt = attempts[i] as Map<String, dynamic>;
          final text = attempt['move'] as String;
          final player = text[0];
          expect(game.currentNode.nextPlayer, player, reason: 'player to move at attempt $i');
          final move = Move.fromGtp(text.substring(1), player: player);
          String result;
          try {
            game.play(move);
            result = 'ok';
          } on IllegalMoveException catch (e) {
            result = e.message;
          }
          expect(result, attempt['result'], reason: 'attempt $i: $text');
          expect(game.boardString, attempt['board'], reason: 'board after attempt $i: $text');
          expect(game.prisonerCount, attempt['prisoners'], reason: 'prisoners after attempt $i: $text');
        }
      });
    }
  });

  group('rulesets', () {
    test('names and abbreviations', () {
      expect(getRules('JP'), 'japanese');
      expect(getRules('cn'), 'chinese');
      expect(getRules('Tromp-Taylor'), 'tromp-taylor');
      expect(getRules('unknown'), 'japanese');
      expect(getRules('{"suicide": true}'), {'suicide': true});
    });
  });
}
