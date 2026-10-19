// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/api/model.py: node
// addressing, coordinate parsing and JSON serialization for the API. Pure functions, no GUI access.

import '../game/game_node.dart';
import '../rules/base_game.dart';
import '../sgf/move.dart';
import '../utils/py_format.dart';
import 'protocol.dart';

// -- node identity

final _nodeIds = Expando<int>('api id');
var _nextNodeId = 1;

/// Stable (per app session) integer id, assigned lazily.
int nodeId(GameNode node) => _nodeIds[node] ??= _nextNodeId++;

String nodeRef(GameNode node) => 'n${nodeId(node)}';

GameNode? findNodeById(GameNode root, int nid) {
  for (final node in root.nodesInTree) {
    if (nodeId(node) == nid) return node;
  }
  return null;
}

/// Root -> node, then onward along the first child to the end of the line.
List<GameNode> lineNodes(GameNode node) {
  final nodes = node.nodesFromRoot;
  while (nodes.last.children.isNotEmpty) {
    nodes.add(nodes.last.orderedChildren[0]);
  }
  return nodes;
}

List<GameNode> mainLine(GameNode root) => lineNodes(root);

bool onMainLine(GameNode node) =>
    node.nodesFromRoot.every((n) => n.parent == null || identical(n.parent!.orderedChildren[0], n));

GameNode _nodeAtMoveNumber(List<GameNode> nodes, int number, String what) {
  if (number == 0) return nodes[0];
  for (final n in nodes) {
    if (n.move != null && n.depth == number) return n;
  }
  final last = nodes.isEmpty ? 0 : nodes.map((n) => n.depth).reduce((a, b) => a > b ? a : b);
  throw ApiError('node_not_found', 'move $number not on the $what (it has $last moves)');
}

/// Turns a node reference into a node: `current | root | end | <N> | main:<N> | n<ID> | #<ID>` (`<N>` is move N on
/// the current line).
GameNode resolveNode(BaseGame<GameNode> game, Object? ref) {
  if (ref == null || ref == '' || ref == 'current') return game.currentNode;
  final text = pyStr(ref).trim();
  if (text == 'root') return game.root;
  if (text == 'end') return lineNodes(game.currentNode).last;
  var m = RegExp(r'^(?:n|#)(\d+)$').firstMatch(text);
  if (m != null) {
    final node = findNodeById(game.root, int.parse(m[1]!));
    if (node == null) throw ApiError('node_not_found', 'no node with id $text in the current game');
    return node;
  }
  m = RegExp(r'^main:(\d+)$').firstMatch(text);
  if (m != null) return _nodeAtMoveNumber(mainLine(game.root), int.parse(m[1]!), 'main line');
  if (RegExp(r'^\d+$').hasMatch(text)) {
    return _nodeAtMoveNumber(lineNodes(game.currentNode), int.parse(text), 'current line');
  }
  throw ApiError('bad_node_ref', "cannot parse node reference '$text'", {
    'hint': 'use current|root|end|<N>|main:<N>|n<ID>',
  });
}

// -- coordinates

const colorAliases = {'B': 'B', 'BLACK': 'B', 'X': 'B', 'W': 'W', 'WHITE': 'W', 'O': 'W'};

String? parseColor(Object? text) {
  if (text == null) return null;
  final color = colorAliases[pyStr(text).trim().toUpperCase()];
  if (color == null) throw ApiError('bad_color', "unknown color '${pyStr(text)}', use B or W");
  return color;
}

/// GTP coordinate (D4, Q16, pass) -> (x, y), or null for pass.
(int, int)? parseCoords(Object? text, (int, int) boardSize) {
  final t = pyStr(text).trim().toUpperCase();
  if (t == 'PASS') return null;
  final m = RegExp(r'^([A-HJ-Z]{1,2})(\d{1,2})$').firstMatch(t);
  if (m == null || !Move.gtpCoord.contains(m[1])) {
    throw ApiError('bad_coordinate', "cannot parse coordinate '${pyStr(text)}' (use GTP style like D4, Q16 or pass)");
  }
  final x = Move.gtpCoord.indexOf(m[1]!), y = int.parse(m[2]!) - 1;
  if (!(0 <= x && x < boardSize.$1 && 0 <= y && y < boardSize.$2)) {
    throw ApiError('bad_coordinate', "'${pyStr(text)}' is outside the ${boardSize.$1}x${boardSize.$2} board");
  }
  return (x, y);
}

/// 'D4', 'B:D4', 'W Q16', 'pass' -> Move.
Move parseMove(Object? text, (int, int) boardSize, String defaultPlayer) {
  var t = pyStr(text).trim();
  final m = RegExp(r'^([BbWw])[:\s]\s*(\S+)$').firstMatch(t);
  var player = defaultPlayer;
  if (m != null) {
    player = m[1]!.toUpperCase();
    t = m[2]!;
  }
  return Move(coords: parseCoords(t, boardSize), player: player);
}

/// Splits `"a, b c"` like Python's `text.replace(",", " ").split()`.
List<String> splitWords(String text) =>
    text.replaceAll(',', ' ').split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();

/// Parses a move sequence; colours alternate from [startPlayer] unless given explicitly.
List<Move> parseMoves(Object? items, (int, int) boardSize, String startPlayer) {
  final list = items is String ? splitWords(items) : (items as List? ?? const []);
  final moves = <Move>[];
  var player = startPlayer;
  for (final item in list) {
    final move = parseMove(item, boardSize, player);
    moves.add(move);
    player = Move.opponentPlayer(move.player);
  }
  return moves;
}

/// 'C3:G7' or ['C3', 'G7'] -> [xmin, xmax, ymin, ymax].
List<int> parseRegion(Object? spec, (int, int) boardSize) {
  final parts = spec is String ? spec.replaceAll(',', ':').split(':') : List<Object?>.of(spec as List);
  if (parts.length != 2) {
    throw ApiError('bad_region', "region must be two corners like C3:G7, got '${pyStr(spec)}'");
  }
  final corners = [for (final p in parts) parseCoords(p, boardSize)];
  if (corners[0] == null || corners[1] == null) throw ApiError('bad_region', 'region corners cannot be pass');
  final (x1, y1) = corners[0]!;
  final (x2, y2) = corners[1]!;
  return [x1 < x2 ? x1 : x2, x1 > x2 ? x1 : x2, y1 < y2 ? y1 : y2, y1 > y2 ? y1 : y2];
}

Map<String, String>? regionJson(List<int>? region) {
  if (region == null || region.isEmpty) return null;
  final [xmin, xmax, ymin, ymax] = region;
  return {'from': gtp((xmin, ymin)), 'to': gtp((xmax, ymax))};
}

String gtp((int, int)? coords) => Move(coords: coords).gtp();

// -- board positions

/// A throwaway board holding the position at [node], without touching the live game.
BaseGame<GameNode> boardAt(GameNode node) => BaseGame<GameNode>.at(node);

/// Throws [ApiError] if the sequence cannot be played from [node].
void checkMovesLegal(GameNode node, List<Move> moves) {
  final g = boardAt(node);
  for (var i = 0; i < moves.length; i++) {
    final move = moves[i];
    try {
      g.validateMoveAndUpdateChains(move, false);
    } on IllegalMoveException catch (e) {
      throw ApiError('illegal_move', '${move.player} ${move.gtp()} is illegal: $e', {'index': i});
    }
  }
}

Map<String, Object?> boardJson(GameNode node, {bool asciiBoard = true}) {
  final g = boardAt(node);
  final (szx, szy) = node.boardSize;
  final grid = [
    for (var y = 0; y < szy; y++) [for (var x = 0; x < szx; x++) '.'],
  ];
  final stones = <String, List<String>>{'B': [], 'W': []};
  for (final m in g.stones) {
    grid[m.coords!.$2][m.coords!.$1] = m.player == 'B' ? 'X' : 'O';
    stones[m.player]!.add(m.gtp());
  }
  final captured = {
    for (final p in const ['B', 'W']) p: g.prisoners.where((m) => m.player == p).length,
  };
  final result = <String, Object?>{
    'node': nodeRef(node),
    'size': [szx, szy],
    'next_player': node.nextPlayer,
    'move_number': node.depth,
    'last_move': node.move?.gtp(),
    'black_stones': stones['B']!..sort(),
    'white_stones': stones['W']!..sort(),
    'captures': {'B': captured['W'], 'W': captured['B']}, // stones each player has taken
    'rows': [for (var y = szy - 1; y >= 0; y--) grid[y].join()], // top row first, X=black O=white
  };
  if (asciiBoard) {
    final cols = [for (var x = 0; x < szx; x++) Move.gtpCoord[x]];
    final lines = ['    ${cols.join(' ')}'];
    final last = node.move?.coords;
    for (var y = szy - 1; y >= 0; y--) {
      final cells = [for (var x = 0; x < szx; x++) last == (x, y) ? grid[y][x].toLowerCase() : grid[y][x]];
      lines.add('${'${y + 1}'.padLeft(3)} ${cells.join(' ')}');
    }
    result['ascii'] = lines.join('\n');
  }
  return result;
}

// -- nodes and trees

Map<String, String>? moveJson(GameNode node) {
  final move = node.move;
  return move == null ? null : {'player': move.player, 'move': move.gtp()};
}

/// Python's `round(v, digits)`: ints stay ints.
Object? pyRoundValue(Object? v, int digits) {
  if (v == null || v is int) return v;
  return pyRoundTo((v as num).toDouble(), digits);
}

/// Short evaluation summary of a node, all numbers from Black's perspective.
Map<String, Object?>? evalJson(GameNode node) {
  if (!node.analysisExists) return null;
  final root = node.analysis['root'] as Map<String, dynamic>;
  final out = <String, Object?>{
    'visits': root['visits'],
    'black_winrate': pyRoundValue(root['winrate'], 4),
    'black_score_lead': pyRoundValue(root['scoreLead'], 2),
    'complete': node.analysisComplete,
  };
  final lost = node.pointsLost;
  if (lost != null) out['points_lost'] = pyRoundValue(lost, 2);
  return out;
}

Map<String, Object?> nodeJson(GameNode node, {bool detail = false, bool withEval = true}) {
  final out = <String, Object?>{
    'id': nodeRef(node),
    'move_number': node.depth,
    'move': moveJson(node),
    'next_player': node.nextPlayer,
    'children': node.children.length,
  };
  final placements = node.placements;
  if (placements.isNotEmpty) {
    out['placements'] = {
      for (final p in const ['B', 'W'])
        p: [
          for (final m in placements)
            if (m.player == p) m.gtp(),
        ],
    };
  }
  if (withEval) out['eval'] = evalJson(node);
  if (detail) {
    out['is_root'] = node.isRoot;
    out['on_main_line'] = onMainLine(node);
    out['parent'] = node.parent == null ? null : nodeRef(node.parent!);
    out['child_ids'] = [for (final c in node.orderedChildren) nodeRef(c)];
    out['note'] = node.note.isEmpty ? null : node.note;
    final comments = node.properties['C'];
    out['sgf_comment'] = comments != null && comments.isNotEmpty ? comments.join('\n') : null;
    out['properties'] = {
      for (final MapEntry(:key, :value) in node.properties.entries)
        if (key != 'KT') key: List.of(value),
    };
  }
  return out;
}

/// A variation starting at [node]: its moves along first children.
Map<String, Object?> branchJson(GameNode node, [int? maxLen]) {
  final moves = <String>[];
  var n = node;
  while (true) {
    if (n.move != null) moves.add(n.move!.gtp());
    if (n.children.isEmpty || (maxLen != null && maxLen != 0 && moves.length >= maxLen)) break;
    n = n.orderedChildren[0];
  }
  return {'start': nodeRef(node), 'first_move': moveJson(node), 'length': moves.length, 'moves': moves};
}

/// Nested tree. Linear stretches are collapsed into a single entry with a move list.
Map<String, Object?> treeJson(GameNode node, [int? maxDepth, int depth = 0]) {
  final seq = <GameNode>[];
  var n = node;
  while (true) {
    seq.add(n);
    if (n.children.length != 1 || (maxDepth != null && depth + seq.length > maxDepth)) break;
    n = n.children[0];
  }
  final out = <String, Object?>{
    'start': nodeRef(seq.first),
    'end': nodeRef(seq.last),
    'first_move_number': seq.first.depth,
    'moves': [for (final s in seq) s.move != null ? '${s.move!.player}:${s.move!.gtp()}' : '-'],
  };
  if (seq.last.children.isNotEmpty) {
    if (maxDepth != null && depth + seq.length > maxDepth) {
      out['truncated'] = true;
    } else {
      out['variations'] = [for (final c in seq.last.orderedChildren) treeJson(c, maxDepth, depth + seq.length)];
    }
  }
  return out;
}

// -- analysis

Map<String, Object?> candidateJson(Map<String, dynamic> cand, String toMove, {bool includePv = true, int? pvLimit}) {
  final black = toMove == 'B';
  final blackWr = cand['winrate'] as num?;
  final out = <String, Object?>{
    'move': cand['move'],
    'order': cand['order'],
    'visits': cand['visits'],
    'winrate': pyRoundValue(black ? blackWr : (blackWr == null ? null : 1 - blackWr), 4),
    'score_lead': pyRoundValue(cand['scoreLead'] == null ? null : (black ? 1 : -1) * (cand['scoreLead'] as num), 2),
    'black_winrate': pyRoundValue(blackWr, 4),
    'black_score_lead': pyRoundValue(cand['scoreLead'], 2),
    'points_lost': pyRoundValue(cand['pointsLost'], 2),
    'winrate_lost': pyRoundValue(cand['winrateLost'], 4),
    'prior': pyRoundValue(cand['prior'], 4),
  };
  if (cand.containsKey('scoreStdev')) out['score_stdev'] = pyRoundValue(cand['scoreStdev'], 2);
  final pv = cand['pv'] as List?;
  if (includePv && pv != null && pv.isNotEmpty) {
    out['pv'] = List.of(pvLimit != null && pvLimit != 0 ? pv.take(pvLimit) : pv);
  }
  return out;
}

/// KataGo ownership arrays already start at the top row.
List<List<Object?>>? ownershipRows(List<double>? ownership, (int, int) boardSize) {
  if (ownership == null || ownership.isEmpty) return null;
  final (szx, szy) = boardSize;
  return [
    for (var r = 0; r < szy; r++) [for (final v in ownership.sublist(r * szx, (r + 1) * szx)) pyRoundValue(v, 2)],
  ];
}

double ownershipAt(List<double> ownership, (int, int) coords, (int, int) boardSize) {
  final (szx, szy) = boardSize;
  final (x, y) = coords;
  return ownership[(szy - 1 - y) * szx + x];
}

/// Everything KaTrain knows about a node's analysis (no new search).
Map<String, Object?> analysisJson(
  GameNode node, {
  int? top,
  bool includePv = true,
  int? pvLimit,
  bool ownership = false,
  bool policy = false,
  List<String>? moves,
}) {
  final toMove = node.nextPlayer;
  final out = <String, Object?>{
    'node': nodeRef(node),
    'move_number': node.depth,
    'to_move': toMove,
    'available': node.analysisExists,
    'complete': node.analysisComplete,
    'visits_requested': node.analysisVisitsRequested,
    'perspective': "winrate/score_lead are for the player to move; black_* fields are from Black's view",
  };
  if (!node.analysisExists) return out;
  final root = node.analysis['root'] as Map<String, dynamic>;
  final black = toMove == 'B';
  out['root'] = {
    'visits': root['visits'],
    'winrate': pyRoundValue(black ? root['winrate'] : 1 - (root['winrate'] as num), 4),
    'score_lead': pyRoundValue((black ? 1 : -1) * (root['scoreLead'] as num), 2),
    'black_winrate': pyRoundValue(root['winrate'], 4),
    'black_score_lead': pyRoundValue(root['scoreLead'], 2),
    'score_stdev': pyRoundValue(root['scoreStdev'], 2),
  };
  var cands = node.candidateMoves;
  if (moves != null && moves.isNotEmpty) {
    final wanted = {for (final m in moves) m.toUpperCase()};
    cands = [
      for (final c in cands)
        if (wanted.contains((c['move'] as String).toUpperCase())) c,
    ];
  } else if (top != null && top != 0) {
    cands = cands.take(top).toList();
  }
  out['candidates'] = [for (final c in cands) candidateJson(c, toMove, includePv: includePv, pvLimit: pvLimit)];
  final parent = node.parent;
  if (node.move != null && parent != null && parent.analysisExists) {
    out['played_move'] = {
      'move': node.move!.gtp(),
      'player': node.move!.player,
      'points_lost': pyRoundValue(node.pointsLost, 2),
    };
  }
  if (ownership) {
    out['ownership'] = ownershipRows(node.ownership, node.boardSize);
    out['ownership_note'] = 'rows top->bottom, +1 = Black owns, -1 = White owns';
  }
  if (policy && node.policy != null && node.policy!.isNotEmpty) {
    final ranking = node.policyRanking ?? const [];
    out['policy_top'] = [
      for (final (p, m) in ranking.take(10)) {'move': m.gtp(), 'prior': pyRoundValue(p, 4)},
    ];
  }
  return out;
}
