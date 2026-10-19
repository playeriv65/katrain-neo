// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/game.py: class BaseGame
// (board state and capture rules). Navigation, scoring, saving and analysis are in game/game.dart.

import '../sgf/go_node.dart';
import '../sgf/move.dart';
import 'rulesets.dart';

class IllegalMoveException implements Exception {
  final String message;
  IllegalMoveException(this.message);

  @override
  String toString() => message;
}

/// A game of Go on a tree of [N]: the current node and the board position there, with KaTrain's capture rules.
class BaseGame<N extends BaseGoNode<N>> {
  final N root;
  late N currentNode;

  /// Chain id for each point, `board[y][x]`, -1 when empty.
  late List<List<int>> board;

  /// The stones of each chain; captured chains become empty lists, ids are never reused.
  late List<List<Move>> chains;

  /// Every stone captured so far, in order.
  late List<Move> prisoners;

  /// The stones captured by the last move.
  late List<Move> lastCapture;

  /// [defaultRules] fills in a missing `RU` property, as KaTrain does from its game/rules setting.
  /// [loaded] is true for a tree read from a file, whose handicap stones may still need placing.
  BaseGame(this.root, {String defaultRules = 'japanese', bool loaded = true}) {
    if (loaded) _placeMissingHandicap();
    if ((root.getProperty('RU') ?? '').isEmpty) {
      root.setProperty('RU', defaultRules);
    }
    setCurrentNode(root);
  }

  /// The position at [node] on a throwaway board that leaves the tree as it is (no handicap placing, no default
  /// rules), like the playeriv65/katrain fork's `board_at`.
  BaseGame.at(N node) : root = node.root {
    setCurrentNode(node);
  }

  void _placeMissingHandicap() {
    final handicap = root.handicap;
    var numStartingMovesBlack = 0;
    var node = root;
    while (node.children.isNotEmpty) {
      node = node.children[0];
      if (node.player == 'B') {
        numStartingMovesBlack += 1;
      } else {
        break;
      }
    }
    if (handicap >= 2 &&
        root.placements.isEmpty &&
        numStartingMovesBlack != handicap &&
        !(root.children.isNotEmpty && root.children[0].placements.isNotEmpty)) {
      // not really according to sgf, kept from KaTrain; the last clause is for fox
      root.placeHandicapStones(handicap);
    }
  }

  (int, int) get boardSize => root.boardSize;

  double get komi => root.komi;

  Object get rules => getRules(root.ruleset);

  void _initState() {
    final (sizeX, sizeY) = boardSize;
    board = [for (var y = 0; y < sizeY; y++) List.filled(sizeX, -1)];
    chains = [];
    prisoners = [];
    lastCapture = [];
  }

  /// Replays the moves from the root to the current node.
  void calculateGroups() {
    _initState();
    try {
      for (final node in currentNode.nodesFromRoot) {
        for (final m in node.moveWithPlacements) {
          validateMoveAndUpdateChains(m, true); // ignore ko since we didn't know if it was forced
        }
        final clear = node.clearPlacements;
        if (clear.isNotEmpty) {
          // AE: play all remaining stones again on an empty board (this also resets the prisoners, as in KaTrain)
          final clearCoords = {for (final c in clear) c.coords};
          final stones = [
            for (final c in chains)
              for (final m in c)
                if (!clearCoords.contains(m.coords)) m,
          ];
          _initState();
          for (final m in stones) {
            validateMoveAndUpdateChains(m, true);
          }
        }
      }
    } on IllegalMoveException catch (e) {
      throw StateError('Unexpected illegal move ($e)');
    }
  }

  Set<int> _neighbours(List<Move> moves) {
    final (sizeX, sizeY) = boardSize;
    final result = <int>{};
    for (final m in moves) {
      final (x, y) = m.coords!;
      for (final (dy, dx) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
        if (0 <= x + dx && x + dx < sizeX && 0 <= y + dy && y + dy < sizeY) {
          result.add(board[y + dy][x + dx]);
        }
      }
    }
    return result;
  }

  /// Puts [move] on the board, updating chains and captures; throws [IllegalMoveException] and leaves the board
  /// half-updated if it is not legal (callers recalculate).
  void validateMoveAndUpdateChains(Move move, bool ignoreKo) {
    final koOrSnapback = lastCapture.length == 1 && lastCapture[0] == move;
    lastCapture = [];

    if (move.isPass) return;
    final (mx, my) = move.coords!;
    if (board[my][mx] != -1) {
      throw IllegalMoveException('Space occupied');
    }

    // merge chains connected by this move, or create a new one
    final nbChains = [
      for (final c in _neighbours([move]))
        if (c >= 0 && chains[c][0].player == move.player) c,
    ];
    final int thisChain;
    if (nbChains.isNotEmpty) {
      thisChain = nbChains[0];
      final merged = nbChains.toSet();
      board = [
        for (final line in board) [for (final sq in line) merged.contains(sq) ? thisChain : sq],
      ];
      for (final oc in nbChains.skip(1)) {
        chains[thisChain].addAll(chains[oc]);
        chains[oc] = [];
      }
      chains[thisChain].add(move);
    } else {
      thisChain = chains.length;
      chains.add([move]);
    }
    board[my][mx] = thisChain;

    // check captures
    final oppNbChains = [
      for (final c in _neighbours([move]))
        if (c >= 0 && chains[c][0].player != move.player) c,
    ];
    for (final c in oppNbChains) {
      if (!_neighbours(chains[c]).contains(-1)) {
        // no liberties
        lastCapture.addAll(chains[c]);
        for (final om in chains[c]) {
          final (ox, oy) = om.coords!;
          board[oy][ox] = -1;
        }
        chains[c] = [];
      }
    }
    if (koOrSnapback && lastCapture.length == 1 && !ignoreKo) {
      throw IllegalMoveException('Ko');
    }
    prisoners.addAll(lastCapture);

    // suicide: check rules and throw exception if needed
    if (!_neighbours(chains[thisChain]).contains(-1)) {
      final r = rules;
      if (chains[thisChain].length == 1) {
        // even in new zealand rules, single stone suicide is not allowed
        throw IllegalMoveException('Single stone suicide');
      } else if ((r is String && (r == 'tromp-taylor' || r == 'new zealand')) || (r is Map && r['suicide'] == true)) {
        lastCapture.addAll(chains[thisChain]);
        for (final om in chains[thisChain]) {
          final (ox, oy) = om.coords!;
          board[oy][ox] = -1;
        }
        chains[thisChain] = [];
        prisoners.addAll(lastCapture);
      } else {
        // suicide not allowed by rules
        throw IllegalMoveException('Suicide');
      }
    }
  }

  /// Plays [move] from the current position; throws [IllegalMoveException] if it is not legal. Returns null without
  /// playing when [expectedNode] is given and is no longer the current node.
  N? play(Move move, {bool ignoreKo = false, N? expectedNode}) {
    final (sizeX, sizeY) = boardSize;
    final c = move.coords;
    if (c != null && !(0 <= c.$1 && c.$1 < sizeX && 0 <= c.$2 && c.$2 < sizeY)) {
      throw IllegalMoveException('Move $move outside of board coordinates');
    }
    if (expectedNode != null && !identical(currentNode, expectedNode)) return null;
    try {
      validateMoveAndUpdateChains(move, ignoreKo);
    } on IllegalMoveException {
      calculateGroups(); // roll the half-applied move back off the board
      rethrow;
    }
    final played = currentNode.play(move);
    currentNode = played;
    return played;
  }

  void setCurrentNode(N node) {
    currentNode = node;
    calculateGroups();
  }

  /// Stones on the board.
  List<Move> get stones => [for (final c in chains) ...c];

  /// Captured stones per colour: `B` is the number of black stones captured.
  Map<String, int> get prisonerCount => {
    for (final player in Move.players.split('')) player: prisoners.where((m) => m.player == player).length,
  };

  /// The board as rows of `B`, `W` and `-`, top row first (like KaTrain's `repr` of a game).
  String get boardString {
    final rows = [
      for (final line in board.reversed) [for (final c in line) c >= 0 ? chains[c][0].player : '-'].join(),
    ];
    return rows.join('\n');
  }
}
