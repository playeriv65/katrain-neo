// The tsumego frame of LizGoban (https://github.com/kaorahi/lizgoban) by kaorahi.
//
// Fills the board around a life-and-death problem with stones, so the engine reads only the problem. Coordinates are
// (i, j) = (row, column), i.e. (y, x).

import 'package:collection/collection.dart';

import '../rules/base_game.dart';
import '../sgf/move.dart';
import 'game_node.dart';

const nearToEdge = 2;
const offenceToWin = 5;

/// A point of the board: empty, a problem stone, or a stone of the frame (maybe marking the analysis region).
class _Point {
  final bool stone;
  final bool? black;
  final bool tsumegoFrame;
  final bool regionMark;

  const _Point({this.stone = false, this.black, this.tsumegoFrame = false, this.regionMark = false});

  static const empty = _Point();
}

typedef _Stones = List<List<_Point>>;

/// Adds a node with the frame as placed stones after the current node, and returns it with the region to analyse,
/// `((xmin, xmax), (ymin, ymax))`, if there is one.
(GameNode, ((int, int), (int, int))?) tsumegoFrameForGame(
  BaseGame<GameNode> game,
  double komi,
  bool blackToPlayP,
  bool koP,
  int margin,
) {
  final currentNode = game.currentNode;
  final bwBoard = [
    for (final line in game.board) [for (final c in line) c >= 0 ? game.chains[c][0].player : '-'],
  ];
  final (isize, jsize) = (bwBoard.length, bwBoard[0].length);
  final (blacks, whites, analysisRegion) = tsumegoFrame(bwBoard, komi, blackToPlayP, koP, margin);
  final sgfBlacks = sgfFromIjs(blacks, isize, jsize, 'B');
  final sgfWhites = sgfFromIjs(whites, isize, jsize, 'W');
  final playedNode = GameNode(parent: currentNode, properties: {'AB': sgfBlacks, 'AW': sgfWhites}); // this inserts
  final region = analysisRegion == null ? null : (analysisRegion.$2, analysisRegion.$1);
  return (playedNode, region);
}

List<String> sgfFromIjs(List<(int, int)> ijs, int isize, int jsize, String player) => [
  for (final (i, j) in ijs) Move(coords: (j, i)).sgf((jsize, isize)),
];

/// The frame for a board of `B`, `W` and `-`: black stones, white stones, and the region to analyse as
/// `((imin, imax), (jmin, jmax))`.
(List<(int, int)>, List<(int, int)>, ((int, int), (int, int))?) tsumegoFrame(
  List<List<String>> bwBoard,
  double komi,
  bool blackToPlayP,
  bool koP,
  int margin,
) {
  final stones = _stonesFromBwBoard(bwBoard);
  final filledStones = _tsumegoFrameStones(stones, komi, blackToPlayP, koP, margin);
  final regionPos = _pickAll(filledStones, (p) => p.regionMark);
  final bw = _pickAll(filledStones, (p) => p.tsumegoFrame);
  final blacks = [
    for (final (i, j, black) in bw)
      if (black == true) (i, j),
  ];
  final whites = [
    for (final (i, j, black) in bw)
      if (black != true) (i, j),
  ];
  return (blacks, whites, _getAnalysisRegion(regionPos));
}

List<(int, int, bool?)> _pickAll(_Stones stones, bool Function(_Point) key) => [
  for (var i = 0; i < stones.length; i++)
    for (var j = 0; j < stones[i].length; j++)
      if (key(stones[i][j])) (i, j, stones[i][j].black),
];

((int, int), (int, int))? _getAnalysisRegion(List<(int, int, bool?)> regionPos) {
  if (regionPos.isEmpty) return null;
  final ai = [for (final p in regionPos) p.$1];
  final aj = [for (final p in regionPos) p.$2];
  final ri = (ai.reduce((a, b) => a < b ? a : b), ai.reduce((a, b) => a > b ? a : b));
  final rj = (aj.reduce((a, b) => a < b ? a : b), aj.reduce((a, b) => a > b ? a : b));
  return (ri.$1 < ri.$2 && rj.$1 < rj.$2) ? (ri, rj) : null;
}

typedef _Ij = ({int i, int j, bool? black});

_Stones _tsumegoFrameStones(_Stones stones, double komi, bool blackToPlayP, bool koP, int margin) {
  final sizes = _ijSizes(stones);
  final (isize, jsize) = sizes;
  final ijs = <_Ij>[
    for (var i = 0; i < stones.length; i++)
      for (var j = 0; j < stones[i].length; j++)
        if (stones[i][j].stone) (i: i, j: j, black: stones[i][j].black),
  ];
  if (ijs.isEmpty) return [];
  // find range of problem
  final top = _minBy(ijs, (z) => z.i, 1);
  final left = _minBy(ijs, (z) => z.j, 1);
  final bottom = _minBy(ijs, (z) => z.i, -1);
  final right = _minBy(ijs, (z) => z.j, -1);
  final imin = _snap0(top.i);
  final jmin = _snap0(left.j);
  final imax = _snapS(bottom.i, isize);
  final jmax = _snapS(right.j, jsize);
  // flip/rotate for standard position
  // don't mix flip and swap (FF = SS = identity, but SFSF != identity)
  final flipSpec = imin < jmin
      ? [false, false, true]
      : [_needFlipP(imin, imax, isize), _needFlipP(jmin, jmax, jsize), false];
  if (flipSpec.contains(true)) {
    final flipped = _flipStones(stones, flipSpec);
    final filled = _tsumegoFrameStones(flipped, komi, blackToPlayP, koP, margin);
    return _flipStones(filled, flipSpec);
  }
  // put outside stones
  final frameRange = [imin - margin, imax + margin, jmin - margin, jmax + margin];
  final blackToAttackP = _guessBlackToAttack([top, bottom, left, right], sizes);
  _putBorder(stones, sizes, frameRange, blackToAttackP);
  _putOutside(stones, sizes, frameRange, blackToAttackP, blackToPlayP, komi);
  _putKoThreat(stones, sizes, frameRange, blackToAttackP, blackToPlayP, koP);
  return stones;
}

// detect corner/edge/center problems
// (avoid putting border stones on the first lines)
int _snap(int k, int to) => (k - to).abs() <= nearToEdge ? to : k;

int _snap0(int k) => _snap(k, 0);

int _snapS(int k, int size) => _snap(k, size - 1);

_Ij _minBy(List<_Ij> ary, int Function(_Ij) key, int sign) {
  final by = [for (final z in ary) sign * key(z)];
  final lowest = by.reduce((a, b) => a < b ? a : b);
  return ary[by.indexOf(lowest)];
}

bool _needFlipP(int kmin, int kmax, int size) => kmin < size - kmax - 1;

bool _guessBlackToAttack(List<_Ij> extrema, (int, int) sizes) =>
    ([for (final z in extrema) _signOfColor(z) * _height2(z, sizes)]).sum > 0;

int _signOfColor(_Ij z) => z.black == true ? 1 : -1;

double _height2(_Ij z, (int, int) sizes) => _height(z.i, sizes.$1) + _height(z.j, sizes.$2);

double _height(int k, int size) => size - (k - (size - 1) / 2).abs();

// -- sub

void _putBorder(_Stones stones, (int, int) sizes, List<int> frameRange, bool isBlack) {
  final [i0, i1, j0, j1] = frameRange;
  _putTwin(stones, sizes, i0, i1, j0, j1, isBlack, false);
  _putTwin(stones, sizes, j0, j1, i0, i1, isBlack, true);
}

void _putTwin(_Stones stones, (int, int) sizes, int beg, int end, int at0, int at1, bool isBlack, bool reverseP) {
  for (final at in [at0, at1]) {
    for (var k = beg; k <= end; k++) {
      final (i, j) = reverseP ? (at, k) : (k, at);
      _putStone(stones, sizes, i, j, isBlack, false, true);
    }
  }
}

void _putOutside(
  _Stones stones,
  (int, int) sizes,
  List<int> frameRange,
  bool blackToAttackP,
  bool blackToPlayP,
  double komi,
) {
  final (isize, jsize) = sizes;
  var count = 0;
  final offenseKomi = (blackToAttackP ? 1 : -1) * komi;
  final defenseArea = (isize * jsize - offenseKomi - offenceToWin) / 2;
  for (var i = 0; i < isize; i++) {
    for (var j = 0; j < jsize; j++) {
      if (_insideP(i, j, frameRange)) continue;
      count += 1;
      final blackP = _xor(blackToAttackP, count <= defenseArea);
      final emptyP = (i + j) % 2 == 0 && (count - defenseArea).abs() > isize;
      _putStone(stones, sizes, i, j, blackP, emptyP);
    }
  }
}

// standard position:
// ? = problem, X = offense, O = defense
// OOOOOOOOOOOOO
// OOOOOOOOOOOOO
// OOOOOOOOOOOOO
// XXXXXXXXXXXXX
// XXXXXXXXXXXXX
// XXXX.........
// XXXX.XXXXXXXX
// XXXX.X???????
// XXXX.X???????

// (pattern, top_p, left_p)
const _offenseKoThreat = (['....OOOX.', '.....XXXX'], true, false);
const _defenseKoThreat = (['..', '..', 'X.', 'XO', 'OO', '.O'], false, true);

void _putKoThreat(
  _Stones stones,
  (int, int) sizes,
  List<int> frameRange,
  bool blackToAttackP,
  bool blackToPlayP,
  bool koP,
) {
  final (isize, jsize) = sizes;
  final forOffenseP = _xor(koP, _xor(blackToAttackP, blackToPlayP));
  final (pattern, topP, leftP) = forOffenseP ? _offenseKoThreat : _defenseKoThreat;
  final (height, width) = (pattern.length, pattern[0].length);
  for (var i = 0; i < pattern.length; i++) {
    for (var j = 0; j < pattern[i].length; j++) {
      final ch = pattern[i][j];
      final ai = i + (topP ? 0 : isize - height);
      final aj = j + (leftP ? 0 : jsize - width);
      if (_insideP(ai, aj, frameRange)) return;
      final black = _xor(blackToAttackP, ch == 'O');
      final empty = ch == '.';
      _putStone(stones, sizes, ai, aj, black, empty);
    }
  }
}

bool _xor(bool a, bool b) => a != b;

// -- util

_Stones _flipStones(_Stones stones, List<bool> flipSpec) {
  final swapP = flipSpec[2];
  final sizes = _ijSizes(stones);
  final (isize, jsize) = sizes;
  final (newIsize, newJsize) = swapP ? (jsize, isize) : (isize, jsize);
  final newStones = [for (var r = 0; r < newIsize; r++) List.filled(newJsize, _Point.empty)];
  for (var i = 0; i < stones.length; i++) {
    for (var j = 0; j < stones[i].length; j++) {
      final (newI, newJ) = _flipIj((i, j), sizes, flipSpec);
      newStones[newI][newJ] = stones[i][j];
    }
  }
  return newStones;
}

void _putStone(_Stones stones, (int, int) sizes, int i, int j, bool black, bool empty, [bool regionMark = false]) {
  final (isize, jsize) = sizes;
  if (i < 0 || isize <= i || j < 0 || jsize <= j) return;
  stones[i][j] = empty ? _Point.empty : _Point(stone: true, tsumegoFrame: true, black: black, regionMark: regionMark);
}

bool _insideP(int i, int j, List<int> region) {
  final [i0, i1, j0, j1] = region;
  return i0 <= i && i <= i1 && j0 <= j && j <= j1;
}

_Stones _stonesFromBwBoard(List<List<String>> bwBoard) => [
  for (final row in bwBoard) [for (final s in row) _stoneFromStr(s)],
];

_Point _stoneFromStr(String s) {
  final black = s == 'B';
  final white = s == 'W';
  return (black || white) ? _Point(stone: true, black: black) : _Point.empty;
}

(int, int) _ijSizes(_Stones stones) => (stones.length, stones[0].length);

(int, int) _flipIj((int, int) ij, (int, int) sizes, List<bool> flipSpec) {
  final (i, j) = ij;
  final (isize, jsize) = sizes;
  final [flipI, flipJ, swapIj] = flipSpec;
  final fi = _flip1(i, isize, flipI);
  final fj = _flip1(j, jsize, flipJ);
  return swapIj ? (fj, fi) : (fi, fj);
}

int _flip1(int k, int size, bool flag) => flag ? size - 1 - k : k;
