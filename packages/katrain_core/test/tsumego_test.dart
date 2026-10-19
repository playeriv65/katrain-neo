// Behaviour of the tsumego frame: stones around a life-and-death problem so the engine reads only the problem.
// Points are (i, j) = (row, column) of the board as the frame sees it, which is (y, x) of the game's board.

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

typedef Point = (int, int);

/// A problem: its stones on a board of [size] x [size].
class Problem {
  final String name;
  final int size;
  final Set<Point> blacks;
  final Set<Point> whites;

  const Problem(this.name, this.size, this.blacks, this.whites);

  Set<Point> get stones => {...blacks, ...whites};

  List<List<String>> get board => [
    for (var i = 0; i < size; i++)
      [
        for (var j = 0; j < size; j++)
          blacks.contains((i, j))
              ? 'B'
              : whites.contains((i, j))
              ? 'W'
              : '-',
      ],
  ];

  Problem map(String suffix, Point Function(Point) f) =>
      Problem('$name $suffix', size, {for (final p in blacks) f(p)}, {for (final p in whites) f(p)});

  /// The same problem in each corner (or on each edge) of the board, and transposed.
  List<Problem> get orientations {
    final n = size - 1;
    return [
      this,
      map('flipped vertically', (p) => (n - p.$1, p.$2)),
      map('flipped horizontally', (p) => (p.$1, n - p.$2)),
      map('rotated', (p) => (n - p.$1, n - p.$2)),
      map('transposed', (p) => (p.$2, p.$1)),
      map('transposed and rotated', (p) => (n - p.$2, n - p.$1)),
    ];
  }

  Problem get colourSwapped => Problem('$name colours swapped', size, whites, blacks);

  /// Rows and columns spanned by the stones: `(imin, imax, jmin, jmax)`.
  (int, int, int, int) get extent {
    final rows = [for (final p in stones) p.$1], columns = [for (final p in stones) p.$2];
    int min(List<int> v) => v.reduce((a, b) => a < b ? a : b);
    int max(List<int> v) => v.reduce((a, b) => a > b ? a : b);
    return (min(rows), max(rows), min(columns), max(columns));
  }

  @override
  String toString() => '$name on $size x $size';
}

/// A white group in the corner of row 0 and column 0, surrounded by Black.
Problem cornerProblem(int size) =>
    Problem('corner', size, {(0, 4), (1, 4), (2, 3), (3, 2), (3, 1), (3, 0)}, {(0, 3), (1, 3), (2, 2), (2, 1), (2, 0)});

/// A white group on the edge of row 0, surrounded by Black.
Problem edgeProblem(int size) {
  final c = size ~/ 2;
  return Problem(
    'edge',
    size,
    {(0, c - 2), (1, c - 2), (2, c - 1), (2, c), (2, c + 1), (1, c + 2), (0, c + 2)},
    {(0, c - 1), (1, c - 1), (1, c), (1, c + 1), (0, c + 1)},
  );
}

/// A white group in the middle of the board, surrounded by Black.
Problem centreProblem(int size) {
  final c = size ~/ 2;
  return Problem(
    'centre',
    size,
    {(c - 1, c), (c - 1, c + 1), (c, c - 1), (c + 1, c - 1), (c + 2, c), (c, c + 2)},
    {(c, c), (c, c + 1), (c + 1, c)},
  );
}

final problems = [
  for (final p in [
    cornerProblem(9),
    cornerProblem(13),
    edgeProblem(13),
    cornerProblem(19),
    edgeProblem(19),
    centreProblem(19),
  ])
    ...p.orientations,
];

typedef Frame = ({Set<Point> blacks, Set<Point> whites, ((int, int), (int, int))? region});

Frame frame(Problem p, {double komi = 6.5, bool blackToPlay = true, bool ko = false, int margin = 4}) {
  final (blacks, whites, region) = tsumegoFrame(p.board, komi, blackToPlay, ko, margin);
  expect(blacks.length, blacks.toSet().length, reason: 'no point twice');
  expect(whites.length, whites.toSet().length, reason: 'no point twice');
  return (blacks: blacks.toSet(), whites: whites.toSet(), region: region);
}

/// How far [k] is from the nearer edge of a board of [size] lines.
int edgeDistance(int k, int size) => k < size - 1 - k ? k : size - 1 - k;

/// The board edge within two lines of [k] counts as the edge of the problem.
int snapLow(int k) => k <= 2 ? 0 : k;
int snapHigh(int k, int size) => size - 1 - k <= 2 ? size - 1 : k;

void main() {
  const settings = [
    (komi: 6.5, blackToPlay: true, ko: false, margin: 4),
    (komi: 0.5, blackToPlay: false, ko: true, margin: 2),
    (komi: -7.5, blackToPlay: true, ko: true, margin: 1),
  ];

  void forAllFrames(void Function(Problem p, Frame f, int margin) check) {
    for (final p in problems) {
      for (final s in settings) {
        check(p, frame(p, komi: s.komi, blackToPlay: s.blackToPlay, ko: s.ko, margin: s.margin), s.margin);
      }
    }
  }

  test("the frame leaves the problem's stones alone and keeps the margin free around them", () {
    forAllFrames((p, f, margin) {
      final reason = '$p margin $margin';
      expect(f.blacks.intersection(f.whites), isEmpty, reason: reason);
      expect({...f.blacks, ...f.whites}.intersection(p.stones), isEmpty, reason: reason);
      final (imin, imax, jmin, jmax) = p.extent;
      for (final (i, j) in {...f.blacks, ...f.whites}) {
        final clear = i <= imin - margin || i >= imax + margin || j <= jmin - margin || j >= jmax + margin;
        expect(clear, isTrue, reason: '$reason: frame stone at ($i, $j)');
      }
      expect({...f.blacks, ...f.whites}, isNotEmpty, reason: reason);
    });
  });

  test('the frame is a legal position: placing it captures nothing', () {
    forAllFrames((p, f, margin) {
      final root = GameNode(properties: {'SZ': p.size});
      final game = BaseGame<GameNode>(root);
      final placed = {...p.stones, ...f.blacks, ...f.whites};
      final node = GameNode(
        parent: root,
        properties: {
          'AB': [
            for (final (i, j) in {...p.blacks, ...f.blacks}) Move(coords: (j, i)).sgf((p.size, p.size)),
          ],
          'AW': [
            for (final (i, j) in {...p.whites, ...f.whites}) Move(coords: (j, i)).sgf((p.size, p.size)),
          ],
        },
      );
      game.setCurrentNode(node);
      expect(game.stones, hasLength(placed.length), reason: '$p margin $margin');
    });
  });

  test('the analysis region is the problem and its margin, out to the edges it is near', () {
    forAllFrames((p, f, margin) {
      final (imin, imax, jmin, jmax) = p.extent;
      int clip(int k) => k < 0 ? 0 : (k >= p.size ? p.size - 1 : k);
      final expected = (
        (clip(snapLow(imin) - margin), clip(snapHigh(imax, p.size) + margin)),
        (clip(snapLow(jmin) - margin), clip(snapHigh(jmax, p.size) + margin)),
      );
      expect(f.region, expected, reason: '$p margin $margin');
    });
  });

  test('the analysis region of some problems', () {
    // corner: rows 0-3 and columns 0-4, snapped to the corner, plus 4
    expect(frame(cornerProblem(19)).region, ((0, 7), (0, 8)));
    // edge: rows 0-2 (the edge) and columns 7-11, plus 2
    expect(frame(edgeProblem(19), margin: 2).region, ((0, 4), (5, 13)));
    // centre: rows and columns 8-11, plus 1
    expect(frame(centreProblem(19), margin: 1).region, ((7, 12), (7, 12)));
    // on a small board the margin reaches the far edges
    expect(frame(cornerProblem(9)).region, ((0, 7), (0, 8)));
  });

  test('the attacker, the side on the outside of the problem, surrounds it', () {
    forAllFrames((p, f, margin) {
      final ((i0, i1), (j0, j1)) = f.region!;
      bool inRegion(Point q) => i0 <= q.$1 && q.$1 <= i1 && j0 <= q.$2 && q.$2 <= j1;
      expect(f.blacks.where(inRegion), isNotEmpty, reason: '$p margin $margin');
      expect(f.whites.where(inRegion), isEmpty, reason: '$p margin $margin');

      final swapped = frame(p.colourSwapped, margin: margin);
      expect(swapped.whites.where(inRegion), isNotEmpty, reason: '$p margin $margin, colours swapped');
      expect(swapped.blacks.where(inRegion), isEmpty, reason: '$p margin $margin, colours swapped');
    });
  });

  test('swapping the colours of the problem, the komi and the player to move swaps the colours of the frame', () {
    for (final p in problems) {
      for (final s in settings) {
        final f = frame(p, komi: s.komi, blackToPlay: s.blackToPlay, ko: s.ko, margin: s.margin);
        final g = frame(p.colourSwapped, komi: -s.komi, blackToPlay: !s.blackToPlay, ko: s.ko, margin: s.margin);
        expect(g.blacks, f.whites, reason: '$p $s');
        expect(g.whites, f.blacks, reason: '$p $s');
        expect(g.region, f.region, reason: '$p $s');
      }
    }
  });

  test("more komi for the attacker leaves less of the outside to the defender", () {
    for (final p in problems.where((p) => p.size == 19)) {
      // Black attacks: White's share shrinks as Black gives more komi
      final shares = [
        for (final komi in [-20.0, 0.0, 20.0]) areaOf(p, frame(p, komi: komi), 'W'),
      ];
      expect(shares[0], greaterThan(shares[1]), reason: '$p');
      expect(shares[1], greaterThan(shares[2]), reason: '$p');
    }
  });

  test('the ko option changes only the ko threats along the edges near a corner', () {
    for (final p in problems) {
      for (final blackToPlay in [true, false]) {
        final without = frame(p, blackToPlay: blackToPlay, margin: 2);
        final with_ = frame(p, blackToPlay: blackToPlay, ko: true, margin: 2);
        final changed = <Point>{
          ...without.blacks.difference(with_.blacks),
          ...with_.blacks.difference(without.blacks),
          ...without.whites.difference(with_.whites),
          ...with_.whites.difference(without.whites),
        };
        final reason = '$p black to play $blackToPlay';
        expect(changed, isNotEmpty, reason: reason);
        for (final (i, j) in changed) {
          final di = edgeDistance(i, p.size), dj = edgeDistance(j, p.size);
          expect((di < 2 && dj < 9) || (di < 9 && dj < 2), isTrue, reason: '$reason: ($i, $j) changed');
        }
        expect(with_.region, without.region, reason: reason);
      }
    }
  });

  test('an empty board gets no frame', () {
    final empty = [for (var i = 0; i < 19; i++) List.filled(19, '-')];
    final (blacks, whites, region) = tsumegoFrame(empty, 6.5, true, false, 4);
    expect(blacks, isEmpty);
    expect(whites, isEmpty);
    expect(region, isNull);
  });

  test('a problem spanning the board gets no frame and no region', () {
    final p = Problem('spanning', 9, {(0, 0), (8, 8)}, {(0, 8), (8, 0)});
    final f = frame(p);
    expect(f.blacks, isEmpty);
    expect(f.whites, isEmpty);
    expect(f.region, isNull);
  });

  group('on a game', () {
    test('adds the frame as a node after the current one, with the region in board coordinates', () {
      final p = cornerProblem(19);
      final root = gameParser.parseSgf(
        '(;SZ[19]AB${[for (final (i, j) in p.blacks) '[${Move(coords: (j, i)).sgf((19, 19))}]'].join()}'
        'AW${[for (final (i, j) in p.whites) '[${Move(coords: (j, i)).sgf((19, 19))}]'].join()}'
        ';W[${Move(coords: (1, 1)).sgf((19, 19))}])',
      );
      final game = BaseGame<GameNode>(root);
      game.setCurrentNode(root.children[0]);
      final current = game.currentNode;
      final problemStones = {for (final m in game.stones) m};

      final (node, region) = tsumegoFrameFromKatrainGame(game, 6.5, false, false, 4);
      expect(node.parent, same(current));
      expect(game.currentNode, same(current), reason: 'the caller shows the frame');

      // the frame is computed on the position at the current node, including the move played there
      final board = [
        for (final line in game.board) [for (final c in line) c >= 0 ? game.chains[c][0].player : '-'],
      ];
      final (blacks, whites, ijRegion) = tsumegoFrame(board, 6.5, false, false, 4);
      expect(node.getListProperty('AB'), [for (final (i, j) in blacks) Move(coords: (j, i)).sgf((19, 19))]);
      expect(node.getListProperty('AW'), [for (final (i, j) in whites) Move(coords: (j, i)).sgf((19, 19))]);
      expect(region, (ijRegion!.$2, ijRegion.$1), reason: '((xmin, xmax), (ymin, ymax))');

      game.setCurrentNode(node);
      expect(game.stones.toSet(), containsAll(problemStones));
      expect(game.stones, hasLength(problemStones.length + blacks.length + whites.length));
    });

    test('an empty board gets an empty frame node and no region', () {
      final root = GameNode(properties: {'SZ': 9});
      final game = BaseGame<GameNode>(root);
      final (node, region) = tsumegoFrameFromKatrainGame(game, 6.5, true, false, 4);
      expect(node.parent, same(root));
      expect(node.getListProperty('AB'), isEmpty);
      expect(node.getListProperty('AW'), isEmpty);
      expect(region, isNull);
    });
  });
}

/// The points of [colour] outside the analysis region: its frame stones, and empty points next to its stones only.
int areaOf(Problem p, Frame f, String colour) {
  final ((i0, i1), (j0, j1)) = f.region!;
  String at(int i, int j) => f.blacks.contains((i, j))
      ? 'B'
      : f.whites.contains((i, j))
      ? 'W'
      : '-';
  var area = 0;
  for (var i = 0; i < p.size; i++) {
    for (var j = 0; j < p.size; j++) {
      if (i0 <= i && i <= i1 && j0 <= j && j <= j1) continue;
      final here = at(i, j);
      if (here == colour) {
        area += 1;
      } else if (here == '-') {
        final neighbours = {
          for (final (di, dj) in const [(-1, 0), (1, 0), (0, -1), (0, 1)])
            if (0 <= i + di && i + di < p.size && 0 <= j + dj && j + dj < p.size) at(i + di, j + dj),
        };
        if (neighbours.length == 1 && neighbours.first == colour) area += 1;
      }
    }
  }
  return area;
}
