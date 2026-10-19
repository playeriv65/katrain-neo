// SGF parsing and writing (properties, text escapes, variations, point lists, board sizes, players), the Fox komi fix,
// and reading NGF (WBaduk) and GIB (Tygem) records.

import 'dart:convert';
import 'dart:io';

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

GoNode parse(String sgf) => goParser.parseSgf(sgf);

GoNode readData(String fileName) =>
    goParser.parseBytes(File('test/data/$fileName').readAsBytesSync(), fileName: fileName);

/// The nodes of the main line, root first.
List<GoNode> mainLine(GoNode root) {
  final nodes = [root];
  while (nodes.last.children.isNotEmpty) {
    nodes.add(nodes.last.children[0]);
  }
  return nodes;
}

/// The moves of the main line as `B:D4`, `W:pass`, ...
List<String> mainLineMoves(GoNode root) => [
  for (final node in mainLine(root))
    for (final m in node.moves) '${m.player}:${m.gtp()}',
];

Set<String> gtpSet(List<Move> moves) => {for (final m in moves) m.gtp()};

void main() {
  group('properties', () {
    test('game info and moves', () {
      final root = parse('(;GM[1]FF[4]SZ[9]KM[7.5]HA[0]RU[Chinese]PB[Black]PW[White];B[ee];W[cc])');
      expect(root.getProperty('PB'), 'Black');
      expect(root.getProperty('PW'), 'White');
      expect(root.boardSize, (9, 9));
      expect(root.komi, 7.5);
      expect(root.handicap, 0);
      expect(root.ruleset, 'Chinese');
      expect(mainLineMoves(root), ['B:E5', 'W:C7']);
    });

    test('defaults for missing game info', () {
      final root = parse('(;GM[1])');
      expect(root.boardSize, (19, 19));
      expect(root.komi, 6.5);
      expect(root.handicap, 0);
      expect(root.ruleset, 'japanese');
      expect(root.initialPlayer, 'B');
      expect(root.getProperty('PB'), isNull);
    });

    test('a property can have several values, with white space between them', () {
      final root = parse('(;SZ[9]AB[aa] [bb]\n  [cc]\r\n[dd])');
      expect(root.getListProperty('AB'), ['aa', 'bb', 'cc', 'dd']);
      expect(root.getProperty('AB'), 'aa');
    });

    test('white space between nodes and properties is ignored', () {
      final root = parse('(\n;\nGM[1]\r\nSZ[9]\n;\nB[ee]\n ;  W[cc]\n)\n');
      expect(root.getProperty('SZ'), '9');
      expect(mainLineMoves(root), ['B:E5', 'W:C7']);
    });

    test('text around the game is ignored', () {
      final root = parse('From: a mail\nSubject: my game\n\n(;SZ[9];B[ee])\n-- \nsignature');
      expect(mainLineMoves(root), ['B:E5']);
    });

    test('FF[3] property names with lowercase letters are read as their capitals', () {
      final root = parse('(;GaMe[1]FileFormat[3]SiZe[9]PlayerBlack[Old]PlayerWhite[Style];AddBlack[cc]AddWhite[gg])');
      expect(root.properties.keys, ['GM', 'FF', 'SZ', 'PB', 'PW']);
      expect(root.getProperty('PB'), 'Old');
      expect(gtpSet(root.children[0].placements), {'C7', 'G3'});
    });

    test('non-ASCII text is kept', () {
      final root = parse('(;PB[柯洁]PW[신진서]GN[囲碁 – ★])');
      expect(root.getProperty('PB'), '柯洁');
      expect(root.getProperty('PW'), '신진서');
      expect(root.getProperty('GN'), '囲碁 – ★');
    });

    test('a property set twice in a node keeps all values', () {
      final root = parse('(;SZ[9]AB[aa]AB[bb])');
      expect(root.getListProperty('AB'), ['aa', 'bb']);
    });
  });

  group('text values', () {
    test('escaped ] and \\ are read without the backslash', () {
      final root = parse(r'(;C[a \] b \\ c]PB[Black \] player])');
      expect(root.getProperty('C'), r'a ] b \ c');
      expect(root.getProperty('PB'), 'Black ] player');
    });

    test('[ needs no escape inside a value', () {
      expect(parse(r'(;C[see [this\]])').getProperty('C'), 'see [this]');
    });

    test('line breaks are kept', () {
      expect(parse('(;C[first line\nsecond line\n])').getProperty('C'), 'first line\nsecond line\n');
    });

    test('] and \\ are escaped when written', () {
      final root = GoNode(properties: {'C': r'a ] b \ c'});
      expect(root.sgf(), r'(;C[a \] b \\ c])');
      expect(parse(root.sgf()).getProperty('C'), r'a ] b \ c');
    });

    test('an escaped ] followed by [ stays inside the value', () {
      final root = parse(r'(;C[a[0\][1\]])');
      expect(root.getListProperty('C'), ['a[0][1]']);
    }, skip: r'bug: values are split at every "][", also an escaped "\][", so C[a[0\][1\]] reads as two values');

    test('a backslash before another character is dropped (SGF FF[4] text)', () {
      expect(parse(r'(;C[a\:b \x])').getProperty('C'), 'a:b x');
    }, skip: r'bug: only \] and \\ are unescaped, other escaped characters keep their backslash');

    test('a backslash before a line break is a soft line break and is removed (SGF FF[4] text)', () {
      expect(parse('(;C[one \\\ntwo])').getProperty('C'), 'one two');
    }, skip: r'bug: soft line breaks (\ followed by a newline) are kept as a backslash and a newline');
  });

  group('variations', () {
    const sgf = '(;SZ[9];B[ee](;W[cc];B[gg])(;W[gc]))';

    test('make a tree, the first variation is the main line', () {
      final root = parse(sgf);
      expect(root.children.length, 1);
      final branch = root.children[0];
      expect(branch.children.length, 2);
      expect(branch.children[1].move!.gtp(), 'G7');
      expect(mainLineMoves(root), ['B:E5', 'W:C7', 'B:G3']);
      expect(root.nodesInTree.length, 5);
      expect(mainLine(root).last.depth, 3);
      expect(mainLine(root).last.root, same(root));
      expect(branch.children[1].parent, same(branch));
    });

    test('are written back as they were read', () {
      expect(parse(sgf).sgf(), sgf);
    });

    test('nested single variations are one line', () {
      final root = parse('(;SZ[9](;B[aa](;W[bb](;B[cc]))))');
      expect(mainLineMoves(root), ['B:A9', 'W:B8', 'B:C7']);
      expect(root.nodesInTree.length, 4);
      expect(root.sgf(), '(;SZ[9];B[aa];W[bb];B[cc])');
    });

    test('a long main line of nested variations', () {
      // OGS writes every move of a game as its own variation
      final moves = [for (var i = 0; i < 300; i++) '${i.isEven ? 'B' : 'W'}[${'abcdefghijklmnopqrs'[i % 19]}a]'];
      final sgf = '(;SZ[19]${[for (final m in moves) '(;$m'].join('\n')}${')' * moves.length})';
      final root = parse(sgf);
      expect(mainLine(root).length, 301);
      expect(root.nodesInTree.length, 301);
    });
  });

  group('points', () {
    test('compressed point lists cover the rectangle from the upper left to the lower right corner', () {
      final root = parse('(;SZ[9]AB[aa:cc][ee]AW[hg:ii];AE[bb:cb])');
      expect(gtpSet(root.placements.where((m) => m.player == 'B').toList()), {
        'A9', 'B9', 'C9', 'A8', 'B8', 'C8', 'A7', 'B7', 'C7', 'E5', //
      });
      expect(gtpSet(root.placements.where((m) => m.player == 'W').toList()), {'H3', 'J3', 'H2', 'J2', 'H1', 'J1'});
      expect(gtpSet(root.children[0].clearPlacements), {'B8', 'C8'});
    });

    test('empty moves are passes, and tt is a pass on boards up to 19x19', () {
      final root = parse('(;SZ[19];B[];W[tt];B[aa])');
      final nodes = mainLine(root);
      expect(nodes[1].isPass, isTrue);
      expect(nodes[2].isPass, isTrue);
      expect(nodes[3].isPass, isFalse);
      expect(parse('(;SZ[9];B[tt])').children[0].isPass, isTrue);
      expect(parse('(;SZ[21];B[tt])').children[0].move!.gtp(), 'U2');
    });

    test('non-square boards', () {
      final root = parse('(;SZ[19:9];B[aa];W[si];B[ri])');
      expect(root.boardSize, (19, 9));
      expect(mainLineMoves(root), ['B:A9', 'W:T1', 'B:S1']);
      expect(parse('(;SZ[9:13];B[ia])').children[0].move!.gtp(), 'J13');
    });

    test('large boards use capital letters past z', () {
      final root = parse('(;SZ[30];B[aD];W[Aa])');
      expect(root.boardSize, (30, 30));
      expect(mainLineMoves(root), ['B:A1', 'W:AB30']);
      expect(root.children[0].move!.sgf((30, 30)), 'aD');
    });
  });

  group('players', () {
    test('the first player comes from PL, the first move, or the setup stones', () {
      expect(parse('(;SZ[9]PL[W])').initialPlayer, 'W');
      expect(parse('(;SZ[9]PL[b])').initialPlayer, 'B');
      expect(parse('(;SZ[9];W[ee])').initialPlayer, 'W');
      expect(parse('(;SZ[9]HA[2]AB[cc][gg])').initialPlayer, 'W');
      expect(parse('(;SZ[9]AB[cc]AW[gg])').initialPlayer, 'B');
      expect(parse('(;SZ[9])').initialPlayer, 'B');
    });

    test('players alternate after each move', () {
      final root = parse('(;SZ[9];B[ee];W[];B[cc])');
      final nodes = mainLine(root);
      expect([for (final n in nodes) n.nextPlayer], ['B', 'W', 'B', 'W']);
      expect([for (final n in nodes.skip(1)) n.player], ['B', 'W', 'B']);
    });

    test('a node without a move keeps the player to move', () {
      final root = parse('(;SZ[9];B[ee];C[a comment];W[cc])');
      final nodes = mainLine(root);
      expect(nodes[2].move, isNull);
      expect(nodes[2].nextPlayer, 'W');
    });
  });

  group('writing', () {
    test('a tree built with play', () {
      final root = GoNode(properties: {'GM': 1, 'SZ': 9, 'KM': 6.5});
      final b = root.play(const Move(coords: (4, 4), player: 'B'));
      b.play(const Move(coords: (2, 2), player: 'W'));
      b.play(const Move(player: 'W'));
      expect(root.sgf(), '(;GM[1]SZ[9]KM[6.5];B[ee](;W[cg])(;W[]))');
    });

    test('playing a move that is already a child returns that child', () {
      final root = GoNode(properties: {'SZ': 9});
      final first = root.play(Move.fromGtp('E5'));
      expect(root.play(Move.fromGtp('E5')), same(first));
      expect(root.play(Move.fromGtp('E5', player: 'W')), isNot(same(first)));
      expect(root.children.length, 2);
    });

    test('properties without values are left out', () {
      final root = GoNode(properties: {'SZ': 9, 'C': <String>[]});
      expect(root.sgf(), '(;SZ[9])');
    });

    test('a record reads back to the same tree', () {
      final sgf = '(;GM[1]SZ[13]AB[aa:cc]C[x \\] y];B[dd](;W[ee]LB[ff:A][gg:B];B[])(;W[hh];AE[aa]B[ii]))';
      final root = parse(sgf);
      final again = parse(root.sgf());
      expect(again.sgf(), root.sgf());
      expect(again.nodesInTree.length, root.nodesInTree.length);
      expect(again.getListProperty('AB'), ['aa:cc']);
      expect(again.children[0].children[0].getListProperty('LB'), ['ff:A', 'gg:B']);
    });
  });

  group('errors', () {
    test('input without a game', () {
      expect(() => parse('SZ[19]'), throwsA(isA<ParseError>()));
      expect(() => parse(''), throwsA(isA<ParseError>()));
    });

    test('an unclosed game', () {
      expect(() => parse('(;SZ[19];B[pd]'), throwsA(isA<ParseError>()));
    });

    test('unexpected characters', () {
      expect(() => parse('(;SZ[19]%%;B[pd])'), throwsA(isA<ParseError>()));
    });

    test('an unknown file type', () {
      expect(() => goParser.parse('(;SZ[19])', ext: 'xyz'), throwsA(isA<ParseError>()));
    });
  });

  group('Fox', () {
    // Fox writes KM[0] (or a komi in its own units); the komi follows from the handicap and the rules
    test('komi is corrected from the handicap and rules', () {
      expect(parse('(;SZ[19]KM[0]HA[0]RU[Japanese]AP[foxwq];B[pd])').komi, 6.5);
      expect(parse('(;SZ[19]KM[375]HA[0]RU[Chinese]AP[foxwq];B[pd])').komi, 7.5);
      expect(parse('(;SZ[19]KM[0]HA[2]RU[Chinese]AP[foxwq];B[pd])').komi, 0.5);
      expect(parse('(;SZ[19]KM[0]HA[0]RU[Japanese];B[pd])').komi, 0);
    });

    test('a Fox record', () {
      final root = readData('fox.sgf');
      expect(root.getProperty('PB'), 'whatiskale');
      expect(root.getProperty('PW'), '注号用名');
      expect(root.getProperty('BR'), '15级');
      expect(root.getProperty('RE'), 'B+R');
      expect(root.komi, 6.5);
      final moves = mainLineMoves(root);
      expect(moves.length, 92);
      expect(moves.take(2), ['B:Q16', 'W:D4']);
    });
  });

  group('real records', () {
    test('an IGS game with handicap stones, comments, times and territory', () {
      final root = readData('igs_handicap.sgf');
      expect(root.handicap, 2);
      expect(gtpSet(root.placements), {'Q16', 'D4'});
      expect(root.komi, 0.5);
      expect(root.getProperty('PW'), 'player1');
      expect(root.getProperty('BR'), '12k ');
      expect(root.getProperty('RE'), 'W+34.5');
      expect(root.getProperty('CP'), contains('Copyright (c) PANDANET Inc. 2020'));
      expect(root.getProperty('C'), contains('player1 11k+: Hi!'));
      expect(root.initialPlayer, 'W');
      final line = mainLine(root);
      final moves = mainLineMoves(root);
      expect(moves.length, 204);
      expect(moves.first, 'W:Q4');
      expect(line[1].getProperty('WL'), '45');
      expect(line.last.getListProperty('TW')!.length, 94);
      expect(line.last.getListProperty('TB')!.length, 61);
      expect(parse(root.sgf()).sgf(), root.sgf());
    });
  });

  group('NGF', () {
    test('a WBaduk handicap game', () {
      final root = readData('wbaduk_handicap.ngf');
      expect(root.boardSize, (19, 19));
      expect(root.getProperty('PW'), 'ace550');
      expect(root.getProperty('PB'), 'p81587');
      expect(root.getProperty('DT'), '2017-03-16');
      expect(root.getProperty('RE'), 'W+');
      expect(root.handicap, 2);
      expect(gtpSet(root.placements), {'D4', 'Q16'});
      final moves = mainLineMoves(root);
      expect(moves.length, 189);
      expect(moves.take(2), ['W:Q3', 'B:D16']);
    });

    String ngf({String komi = '6', String handicap = '0', List<String> moves = const ['PMABBFFFF']}) => [
      'Rated game', '9', 'Whitey 3D', 'Blacky 2D', 'www.cyberoro.com', handicap, '0', komi, '20200102 [10:00]', //
      '5', 'Black wins by 3.5!', '${moves.length}', ...moves,
    ].join('\r\n');

    test('a small even game: a whole-number komi gets half a point, AA is a pass', () {
      final root = goParser.parseBytes(
        utf8.encode(ngf(moves: ['PMABBFFFF', 'PMACWAAAA', 'PMADBCCCC'])),
        fileName: 'g.ngf',
      );
      expect(root.boardSize, (9, 9));
      expect(root.komi, 6.5);
      expect(root.handicap, 0);
      expect(root.getProperty('PB'), 'Blacky');
      expect(root.getProperty('RE'), 'B+');
      expect(root.getProperty('DT'), '2020-01-02');
      expect(mainLineMoves(root), ['B:E5', 'W:pass', 'B:B8']);
    });

    test('broken records', () {
      expect(() => goParser.parseNgf(ngf(moves: [])), throwsA(isA<ParseError>()));
      expect(() => goParser.parseNgf(ngf(handicap: '12')), throwsA(isA<ParseError>()));
    });
  });

  group('GIB', () {
    test('a Tygem game', () {
      final root = readData('tygem.gib');
      expect(root.getProperty('PB'), 'kim');
      expect(root.getProperty('BR'), '2D');
      expect(root.getProperty('PW'), 'wildsim1');
      expect(root.getProperty('WR'), '2D');
      expect(root.getProperty('RE'), 'W+T');
      expect(root.komi, 6.5);
      expect(root.getProperty('DT'), '2020-06-14');
      expect(root.handicap, 0);
      final moves = mainLineMoves(root);
      expect(moves.length, 232);
      expect(moves.take(3), ['B:Q16', 'W:D4', 'B:R4']);
    });

    String gib({String ini = 'INI 0 1 0 &4', String result = 'GRLT:0,ZIPSU:35,', List<String> moves = const []}) => [
      r'\HS',
      r'\[GAMEBLACKNAME=Black Player (5K)\]',
      r'\[GAMEWHITENAME=White\]',
      '\\[GAMEINFOMAIN=GBKIND:3,${result}GONGJE:0,TCNT:2\\]',
      r'\HE',
      r'\GS',
      ini,
      ...moves,
      r'\GE',
    ].join('\r\n');

    test('handicap stones, result by points, names with and without rank', () {
      final root = goParser.parseBytes(
        utf8.encode(gib(ini: 'INI 0 1 3 &4', moves: ['STO 0 2 2 15 15 ', 'STO 0 3 1 9 9 '])),
        fileName: 'GAME.GIB',
      );
      expect(root.getProperty('PB'), 'Black Player');
      expect(root.getProperty('BR'), '5K');
      expect(root.getProperty('PW'), 'White');
      expect(root.getProperty('WR'), isNull);
      expect(root.getProperty('RE'), 'B+3.5');
      expect(root.handicap, 3);
      expect(gtpSet(root.placements), {'Q16', 'D4', 'D16'});
      expect(mainLineMoves(root), ['W:Q4', 'B:K10']);
    });

    test('resignation results', () {
      final moves = ['STO 0 2 1 3 3 '];
      expect(goParser.parseGib(gib(result: 'GRLT:3,ZIPSU:0,', moves: moves)).getProperty('RE'), 'B+R');
      expect(goParser.parseGib(gib(result: 'GRLT:4,ZIPSU:0,', moves: moves)).getProperty('RE'), 'W+R');
    });

    test('broken records', () {
      expect(() => goParser.parseGib(gib()), throwsA(isA<ParseError>()));
      expect(() => goParser.parseGib(gib(moves: ['STO 0 2 1 19 3 '])), throwsA(isA<ParseError>()));
      expect(() => goParser.parseGib(gib(ini: 'INI 0 1 12 &4', moves: ['STO 0 2 1 3 3 '])), throwsA(isA<ParseError>()));
    });
  });

  group('Move', () {
    test('GTP round trip', () {
      for (final gtp in ['A1', 'T19', 'J9', 'Z25', 'AA26', 'pass']) {
        expect(Move.fromGtp(gtp).gtp(), gtp);
      }
      expect(Move.fromGtp('PASS').isPass, isTrue);
      expect(() => Move.fromGtp('I5'), throwsFormatException);
      expect(() => Move.fromGtp('5'), throwsFormatException);
    });

    test('SGF coordinates', () {
      expect(Move.fromSgf('dd', (19, 19)).gtp(), 'D16');
      expect(Move.fromSgf('tt', (19, 19)).isPass, isTrue);
      expect(Move.fromSgf('tt', (21, 21)).isPass, isFalse);
      expect(Move(coords: (3, 15)).sgf((19, 19)), 'dd');
      expect(const Move(player: 'W').sgf((19, 19)), '');
    });

    test('equality is by player and point', () {
      expect(Move.fromGtp('D4'), Move.fromGtp('D4'));
      expect(Move.fromGtp('D4'), isNot(Move.fromGtp('D4', player: 'W')));
      expect(Move.fromGtp('D4').opponent, 'W');
    });
  });
}
