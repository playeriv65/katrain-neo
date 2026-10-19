// Board rules of BaseGame: chains and captures, ko, suicide per ruleset, illegal moves, setup stones, handicap
// placement and ruleset names.

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

/// A position given as rows of `B`, `W` and `-`, top row first (the format of [BaseGame.boardString]), as setup
/// stones on the root, with [toPlay] to move.
BaseGame<GoNode> position(List<String> rows, {String toPlay = 'B', String rules = 'japanese'}) {
  final size = (rows[0].length, rows.length);
  final black = <String>[];
  final white = <String>[];
  for (var r = 0; r < rows.length; r++) {
    for (var x = 0; x < rows[r].length; x++) {
      final point = Move(coords: (x, rows.length - 1 - r)).sgf(size);
      if (rows[r][x] == 'B') black.add(point);
      if (rows[r][x] == 'W') white.add(point);
    }
  }
  final root = GoNode(
    properties: {
      'SZ': size.$1 == size.$2 ? '${size.$1}' : '${size.$1}:${size.$2}',
      'RU': rules,
      'PL': toPlay,
      'AB': ?(black.isEmpty ? null : black),
      'AW': ?(white.isEmpty ? null : white),
    },
  );
  return BaseGame<GoNode>(root);
}

/// Plays [gtp] for the player to move.
GoNode play(BaseGame<GoNode> game, String gtp) => game.play(Move.fromGtp(gtp, player: game.currentNode.nextPlayer))!;

String board(List<String> rows) => rows.join('\n');

/// The message of the [IllegalMoveException] thrown by playing [gtp], or null if it is legal.
String? illegality(BaseGame<GoNode> game, String gtp) {
  try {
    play(game, gtp);
    return null;
  } on IllegalMoveException catch (e) {
    return e.message;
  }
}

/// The handicap stones a game with this size and handicap gets, as GTP points.
Set<String> handicapStones(int size, int handicap) {
  final game = BaseGame<GoNode>(GoNode(properties: {'SZ': size, 'HA': handicap}));
  return {for (final m in game.root.placements) m.gtp()};
}

void main() {
  group('board', () {
    test('starts empty with the size of SZ, square or not', () {
      final game = BaseGame<GoNode>(GoNode(properties: {'SZ': 5}));
      expect(game.boardString, board(['-----', '-----', '-----', '-----', '-----']));
      expect(game.stones, isEmpty);
      expect(game.prisonerCount, {'B': 0, 'W': 0});

      final rect = BaseGame<GoNode>(GoNode(properties: {'SZ': '7:3'}));
      expect(rect.boardSize, (7, 3));
      expect(rect.boardString, board(['-------', '-------', '-------']));
    });

    test('A1 is the bottom left corner, columns skip I', () {
      final game = BaseGame<GoNode>(GoNode(properties: {'SZ': 9}));
      play(game, 'A1');
      play(game, 'J9');
      expect(game.boardString.split('\n').first, '--------W');
      expect(game.boardString.split('\n').last, 'B--------');
    });

    test('players alternate from black, and a pass changes nothing on the board', () {
      final game = BaseGame<GoNode>(GoNode(properties: {'SZ': 5}));
      expect(play(game, 'C3').move, const Move(coords: (2, 2), player: 'B'));
      expect(play(game, 'pass').isPass, isTrue);
      expect(play(game, 'D3').player, 'B');
      expect(game.currentNode.nextPlayer, 'W');
      expect(game.boardString, board(['-----', '-----', '--BB-', '-----', '-----']));
      expect(game.stones.length, 2);
    });

    test('a move off the board is illegal', () {
      final game = BaseGame<GoNode>(GoNode(properties: {'SZ': 5}));
      expect(() => game.play(Move.fromGtp('F1')), throwsA(isA<IllegalMoveException>()));
      expect(() => game.play(Move.fromGtp('A6')), throwsA(isA<IllegalMoveException>()));
      expect(game.currentNode, same(game.root));
    });

    test('a move on an occupied point is illegal and leaves the game as it was', () {
      final game = BaseGame<GoNode>(GoNode(properties: {'SZ': 5}));
      play(game, 'C3');
      final before = game.currentNode;
      expect(illegality(game, 'C3'), 'Space occupied');
      expect(game.currentNode, same(before));
      expect(before.children, isEmpty);
      expect(game.boardString, board(['-----', '-----', '--B--', '-----', '-----']));
    });
  });

  group('captures', () {
    test('a stone without liberties is captured', () {
      final game = position(['-----', '--B--', '-BW--', '--B--', '-----']);
      play(game, 'D3');
      expect(game.boardString, board(['-----', '--B--', '-B-B-', '--B--', '-----']));
      expect(game.prisonerCount, {'B': 0, 'W': 1});
      expect(game.lastCapture, [const Move(coords: (2, 2), player: 'W')]);
    });

    test('a chain is captured as a whole when its last liberty is filled', () {
      final game = position(['BWWW-', '-BBB-', '-----', '-----', '-----']);
      play(game, 'E5');
      expect(game.boardString, board(['B---B', '-BBB-', '-----', '-----', '-----']));
      expect(game.prisonerCount['W'], 3);
    });

    test('a chain with a liberty left is not captured', () {
      final game = position(['-WWW-', '-BBB-', '-----', '-----', '-----']);
      play(game, 'E5');
      expect(game.boardString, board(['-WWWB', '-BBB-', '-----', '-----', '-----']));
      expect(game.prisonerCount['W'], 0);
    });

    test('one move can capture two chains', () {
      final game = position(['WB-BW', '-W-W-', '-----', '-----', '-----'], toPlay: 'W');
      play(game, 'C5');
      expect(game.boardString, board(['W-W-W', '-W-W-', '-----', '-----', '-----']));
      expect(game.prisonerCount, {'B': 2, 'W': 0});
    });

    test('a move without liberties of its own is legal when it captures', () {
      final game = position(['-----', '-----', 'B----', 'WB---', '-WB--']);
      play(game, 'A1');
      expect(game.boardString, board(['-----', '-----', 'B----', '-B---', 'B-B--']));
      expect(game.prisonerCount['W'], 2);
    });

    test('captures in the corner of a non-square board', () {
      final game = position(['----WBB', '-----W-', '-------'], toPlay: 'W');
      expect(game.boardSize, (7, 3));
      play(game, 'G2');
      expect(game.boardString, board(['----W--', '-----WW', '-------']));
      expect(game.prisonerCount['B'], 2);
    });

    test('prisoners are counted per colour over the game', () {
      // black captures the white stone at C1, then white captures the black stones at B5 and D5
      final game = position(['WB-BW', '-W-W-', '-----', '--B--', '-BW--']);
      play(game, 'D1');
      expect(game.prisonerCount, {'B': 0, 'W': 1});
      play(game, 'C5');
      expect(game.prisonerCount, {'B': 2, 'W': 1});
      expect(game.prisoners.length, 3);
    });

    test('going back to an earlier node restores the captured stones', () {
      final game = position(['-----', '--B--', '-BW--', '--B--', '-----']);
      final start = game.currentNode;
      final capture = play(game, 'D3');
      game.setCurrentNode(start);
      expect(game.boardString, board(['-----', '--B--', '-BW--', '--B--', '-----']));
      expect(game.prisonerCount['W'], 0);
      game.setCurrentNode(capture);
      expect(game.prisonerCount['W'], 1);
    });
  });

  group('ko', () {
    // black captures the white stone at B3 by playing C3; white retaking at B3 at once would repeat the position
    const koShape = ['-----', '-BW--', 'BW-W-', '-BW--', '-----'];

    test('the immediate retake of a ko is illegal', () {
      final game = position(koShape);
      play(game, 'C3');
      expect(game.boardString, board(['-----', '-BW--', 'B-BW-', '-BW--', '-----']));
      final before = game.currentNode;
      expect(illegality(game, 'B3'), 'Ko');
      expect(game.currentNode, same(before));
      expect(game.boardString, board(['-----', '-BW--', 'B-BW-', '-BW--', '-----']));
      expect(game.prisonerCount['B'], 0);
    });

    test('the ko can be retaken after an exchange elsewhere, and then black cannot retake at once', () {
      final game = position(koShape);
      play(game, 'C3');
      play(game, 'E5'); // ko threat
      play(game, 'E1'); // answered elsewhere
      expect(illegality(game, 'B3'), isNull);
      expect(game.boardString, board(['----W', '-BW--', 'BW-W-', '-BW--', '----B']));
      expect(game.prisonerCount, {'B': 1, 'W': 1});
      expect(illegality(game, 'C3'), 'Ko');
    });

    test('the ko rule can be ignored', () {
      final game = position(koShape);
      play(game, 'C3');
      game.play(Move.fromGtp('B3', player: 'W'), ignoreKo: true);
      expect(game.boardString, board(['-----', '-BW--', 'BW-W-', '-BW--', '-----']));
    });

    test('a snapback is not a ko: the recapture takes more than one stone', () {
      final game = position(['-----', '-----', 'BBB--', 'WWWB-', '--WB-']);
      play(game, 'B1'); // throw-in, leaving white one liberty
      play(game, 'A1'); // white captures the throw-in
      expect(game.boardString, board(['-----', '-----', 'BBB--', 'WWWB-', 'W-WB-']));
      expect(illegality(game, 'B1'), isNull); // black plays at the captured point again and takes five stones
      expect(game.boardString, board(['-----', '-----', 'BBB--', '---B-', '-B-B-']));
      expect(game.prisonerCount, {'B': 1, 'W': 5});
    });
  });

  group('suicide', () {
    // black at A1 would have no liberties and capture nothing
    const single = ['-----', '-----', '-----', 'W----', '-W---'];
    // black at A1 would join B1, and the two stones would have no liberties
    const multi = ['-----', '-----', '-----', 'WW---', '-BW--'];

    for (final rules in ['japanese', 'chinese', 'korean', 'aga', 'tromp-taylor', 'new zealand', '{"suicide": true}']) {
      test('single stone suicide is illegal under $rules rules', () {
        final game = position(single, rules: rules);
        expect(illegality(game, 'A1'), 'Single stone suicide');
        expect(game.boardString, board(single));
        expect(game.currentNode.children, isEmpty);
      });
    }

    for (final rules in ['japanese', 'chinese', 'korean', 'aga', 'jp', 'unknown rules', '{"suicide": false}']) {
      test('multi-stone suicide is illegal under $rules rules', () {
        final game = position(multi, rules: rules);
        expect(illegality(game, 'A1'), 'Suicide');
        expect(game.boardString, board(multi));
        expect(game.prisonerCount['B'], 0);
      });
    }

    for (final rules in ['tromp-taylor', 'new zealand', 'TT', 'nz', '{"suicide": true}']) {
      test('multi-stone suicide removes the stones under $rules rules', () {
        final game = position(multi, rules: rules);
        expect(illegality(game, 'A1'), isNull);
        expect(game.boardString, board(['-----', '-----', '-----', 'WW---', '--W--']));
        expect(game.prisonerCount, {'B': 2, 'W': 0});
        expect(game.currentNode.nextPlayer, 'W');
      });
    }
  });

  group('setup stones', () {
    test('AB and AW put stones on the board, AE removes them, compressed lists cover rectangles', () {
      final root = goParser.parseSgf('(;SZ[5]AB[aa:bc]AW[ee];AE[ab:bb]AW[dd];B[cc])');
      final game = BaseGame<GoNode>(root);
      expect(game.boardString, board(['BB---', 'BB---', 'BB---', '-----', '----W']));
      game.setCurrentNode(root.children[0]);
      expect(game.boardString, board(['BB---', '-----', 'BB---', '---W-', '----W']));
      game.setCurrentNode(root.children[0].children[0]);
      expect(game.boardString, board(['BB---', '-----', 'BBB--', '---W-', '----W']));
    });
  });

  group('handicap', () {
    test('stones on 19x19 are on the star points', () {
      expect(handicapStones(19, 2), {'D4', 'Q16'});
      expect(handicapStones(19, 3), {'D4', 'Q16', 'Q4'});
      expect(handicapStones(19, 4), {'D4', 'Q16', 'Q4', 'D16'});
      expect(handicapStones(19, 5), {'D4', 'Q16', 'Q4', 'D16', 'K10'});
      expect(handicapStones(19, 6), {'D4', 'Q16', 'Q4', 'D16', 'D10', 'Q10'});
      expect(handicapStones(19, 7), {'D4', 'Q16', 'Q4', 'D16', 'D10', 'Q10', 'K10'});
      expect(handicapStones(19, 8), {'D4', 'Q16', 'Q4', 'D16', 'D10', 'Q10', 'K4', 'K16'});
      expect(handicapStones(19, 9), {'D4', 'Q16', 'Q4', 'D16', 'D10', 'Q10', 'K4', 'K16', 'K10'});
    });

    test('stones on 13x13 and 9x9', () {
      expect(handicapStones(13, 4), {'D4', 'K10', 'K4', 'D10'});
      expect(handicapStones(13, 5), {'D4', 'K10', 'K4', 'D10', 'G7'});
      expect(handicapStones(13, 9), {'D4', 'K10', 'K4', 'D10', 'G7', 'D7', 'K7', 'G4', 'G10'});
      expect(handicapStones(9, 2), {'C3', 'G7'});
      expect(handicapStones(9, 5), {'C3', 'G7', 'G3', 'C7', 'E5'});
      expect(handicapStones(9, 9), {'C3', 'G7', 'G3', 'C7', 'E5', 'C5', 'G5', 'E3', 'E7'});
    });

    test('more than nine stones form a grid', () {
      final stones = handicapStones(19, 16);
      expect(stones, {
        for (final x in ['D', 'H', 'M', 'Q'])
          for (final y in [4, 8, 12, 16]) '$x$y',
      });
    });

    test('Tygem puts the third stone in the other corner', () {
      final root = GoNode(properties: {'SZ': 19});
      root.placeHandicapStones(3, tygem: true);
      expect({for (final m in root.placements) m.gtp()}, {'D4', 'Q16', 'D16'});
    });

    test('white moves first after the handicap stones', () {
      final game = BaseGame<GoNode>(GoNode(properties: {'SZ': 19, 'HA': 2}));
      expect(game.stones.length, 2);
      expect(game.stones.every((m) => m.player == 'B'), isTrue);
      expect(game.root.nextPlayer, 'W');
    });

    test('stones are not placed when the record has them, plays them as moves, or for one stone', () {
      final withSetup = goParser.parseSgf('(;SZ[19]HA[2]AB[cc][qq];W[dd])');
      BaseGame<GoNode>(withSetup);
      expect(withSetup.getListProperty('AB'), ['cc', 'qq']);

      final asMoves = goParser.parseSgf('(;SZ[19]HA[2];B[pd];B[dp];W[dd])');
      final game = BaseGame<GoNode>(asMoves);
      expect(asMoves.placements, isEmpty);
      game.setCurrentNode(asMoves.children[0].children[0]);
      expect(game.stones.length, 2);

      final one = goParser.parseSgf('(;SZ[19]HA[1];B[pd])');
      BaseGame<GoNode>(one);
      expect(one.placements, isEmpty);

      final notLoaded = GoNode(properties: {'SZ': 19, 'HA': 3});
      BaseGame<GoNode>(notLoaded, loaded: false);
      expect(notLoaded.placements, isEmpty);
    });
  });

  group('rulesets', () {
    test('names and abbreviations', () {
      expect(getRules('JP'), 'japanese');
      expect(getRules('Japanese'), 'japanese');
      expect(getRules('cn'), 'chinese');
      expect(getRules('ko'), 'korean');
      expect(getRules('aga'), 'aga');
      expect(getRules('Tromp-Taylor'), 'tromp-taylor');
      expect(getRules('NZ'), 'new zealand');
      expect(getRules('stone_scoring'), 'stone_scoring');
      expect(getRules('unknown'), 'japanese');
      expect(getRules('{"suicide": true}'), {'suicide': true});
      expect(getRules('{not json'), 'japanese');
    });

    test('a game without RU gets the default rules', () {
      final root = GoNode(properties: {'SZ': 9});
      final game = BaseGame<GoNode>(root, defaultRules: 'chinese');
      expect(root.getProperty('RU'), 'chinese');
      expect(game.rules, 'chinese');
      final kept = GoNode(properties: {'SZ': 9, 'RU': 'nz'});
      expect(BaseGame<GoNode>(kept, defaultRules: 'chinese').rules, 'new zealand');
    });
  });
}
