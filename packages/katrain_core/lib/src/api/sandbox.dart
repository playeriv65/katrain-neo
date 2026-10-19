// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/api/sandbox.py:
// background exploration cursors ("sandboxes") inside the user's own game tree.
//
// A sandbox is a cursor of the agent's, separate from the position the app shows. Moves the agent plays become
// ordinary variations in the user's game, and every analysis is stored in those nodes, so nothing computed in the
// background is thrown away: the user can browse the lines and their evaluations later without re-analysis.
// What the sandbox never does is move the user's board, draw overlays, or outrank the app's own queries.
// `sandbox.show` is the explicit step that brings a line to the user's attention.

import '../game/game_node.dart';
import '../sgf/move.dart';
import '../utils/py_format.dart';
import 'commands.dart';
import 'model.dart';
import 'protocol.dart';

var _nextSandboxId = 1;

class Sandbox {
  final String id;
  final GameNode origin; // node of the user's game the exploration starts from
  final GameNode root;
  GameNode cursor;
  Sandbox(this.id, this.origin) : root = origin.root, cursor = origin;

  /// Nodes after the origin up to the cursor.
  List<GameNode> line() => cursor.nodesFromRoot.sublist(origin.nodesFromRoot.length);

  Map<String, Object?> summary() {
    final nodes = line();
    return {
      'id': id,
      'from': nodeRef(origin),
      'from_move_number': origin.depth,
      'moves': [
        for (final n in nodes)
          if (n.move != null) '${n.move!.player}:${n.move!.gtp()}',
      ],
      'nodes': [for (final n in nodes) nodeRef(n)],
      'at': nodeRef(cursor),
      'move_number': cursor.depth,
      'to_move': cursor.nextPlayer,
    };
  }
}

Sandbox _get(CommandHandler h, ApiArgs a) {
  final boxes = h.state.sandboxes;
  final sb = boxes[pyStr(truthy(a['id']) ? a['id'] : '')];
  if (sb == null) {
    throw ApiError('not_found', "no sandbox '${pyStr(a['id'])}'", {'available': boxes.keys.toList()..sort()});
  }
  if (!identical(h.game.root, sb.root)) {
    throw ApiError('game_changed', "the user's board shows a different game than this sandbox belongs to");
  }
  if (!sb.root.nodesInTree.any((n) => identical(n, sb.cursor))) {
    throw ApiError('not_found', 'the sandbox position was deleted from the game');
  }
  return sb;
}

String _ascii(GameNode node) => boardJson(node)['ascii'] as String;

Object? _cmdSandboxNew(CommandHandler h, ApiArgs a) {
  final origin = h.node(a, 'from');
  final sid = truthy(a['name']) ? pyStr(a['name']) : 's${_nextSandboxId++}';
  if (h.state.sandboxes.containsKey(sid)) throw ApiError('exists', "sandbox '$sid' already exists");
  final sb = Sandbox(sid, origin);
  h.state.sandboxes[sid] = sb;
  return {...sb.summary(), 'board': _ascii(sb.cursor)};
}

Object? _cmdSandboxPlay(CommandHandler h, ApiArgs a) {
  final sb = _get(h, a);
  final cur = sb.cursor;
  final startPlayer = parseColor(a['color']) ?? cur.nextPlayer;
  final moves = parseMoves(a['moves'] ?? const [], cur.boardSize, startPlayer);
  if (moves.isEmpty) throw ApiError('bad_argument', 'no moves given');
  final (nodes, created) = h.addNodes(cur, moves, analyze: 'none'); // validates legality first
  sb.cursor = nodes.last;
  h.host.redrawMoveTree();
  return {...sb.summary(), 'created_nodes': created, 'board': _ascii(sb.cursor)};
}

Object? _cmdSandboxBack(CommandHandler h, ApiArgs a) {
  final sb = _get(h, a);
  for (var i = 0; i < apiInt(a, 'n', defaultValue: 1, minimum: 1)!; i++) {
    if (identical(sb.cursor, sb.origin)) break;
    sb.cursor = sb.cursor.parent!;
  }
  return {...sb.summary(), 'board': _ascii(sb.cursor)};
}

Object? _cmdSandboxBoard(CommandHandler h, ApiArgs a) {
  final sb = _get(h, a);
  return {...sb.summary(), ...boardJson(sb.cursor)};
}

Future<Object?> _cmdSandboxAnalyze(CommandHandler h, ApiArgs a) async {
  final timeout = apiInt(a, 'timeout', defaultValue: 300, minimum: 1)!;
  final sb = _get(h, a);
  final node = sb.cursor;
  final engine = h.engineFor(node);
  final visits = apiInt(a, 'visits', defaultValue: engine.config['max_visits'] as int, minimum: 1)!;
  final raw = a['moves'] ?? const [];
  final names = raw is String ? splitWords(raw) : List<Object?>.of(raw as List);
  final moves = [for (final m in names) Move(coords: parseCoords(m, node.boardSize), player: node.nextPlayer)];
  for (final m in moves) {
    checkMovesLegal(node, [m]);
  }
  final cached = moves.isEmpty && node.analysisComplete && node.rootVisits >= 0.95 * visits && !apiBool(a['force']);
  if (!cached || (moves.isNotEmpty && !node.analysisExists)) {
    await h.search(node, engine, visits, timeout: timeout, background: true);
  }
  for (final m in moves) {
    // sequential: each comparison already fills the GPU
    await h.search(node, engine, visits, refineMove: m, timeout: timeout, background: true);
  }
  final result = analysisJson(
    node,
    top: moves.isNotEmpty ? null : apiInt(a, 'top', defaultValue: 10),
    includePv: apiBool(a['pv'], true),
    pvLimit: apiInt(a, 'pv_limit'),
    ownership: apiBool(a['ownership']),
    moves: moves.isEmpty ? null : [for (final m in moves) m.gtp()],
  );
  if (moves.isNotEmpty) {
    mergeSortBy(result['candidates'] as List<Map<String, Object?>>, (c) => (c['points_lost'] as num?) ?? 1e9);
  }
  return {'sandbox': sb.summary(), 'reused_existing': cached && moves.isEmpty, 'requested_visits': visits, ...result};
}

Object? _cmdSandboxShow(CommandHandler h, ApiArgs a) {
  final sb = _get(h, a);
  final nodes = sb.line();
  if (nodes.isEmpty) throw ApiError('bad_argument', 'the sandbox has no moves yet');
  if ((a['as'] ?? 'pv') == 'goto') {
    h.goto(sb.cursor);
    return {'shown': 'goto', ...h.currentJson()};
  }
  final moves = [
    for (final n in nodes)
      if (n.move != null) n.move!,
  ];
  return {'shown': 'pv', ...showPv(h, sb.origin, moves, apiInt(a, 'step', minimum: 1))};
}

Object? _cmdSandboxList(CommandHandler h, ApiArgs a) {
  final root = h.game.root;
  return [
    for (final sb in h.state.sandboxes.values)
      if (identical(sb.root, root)) sb.summary(),
  ];
}

Object? _cmdSandboxDrop(CommandHandler h, ApiArgs a) {
  final boxes = h.state.sandboxes;
  final targets = a['id'] == 'all' ? boxes.values.toList() : [_get(h, a)];
  var pruned = 0;
  if (apiBool(a['prune'])) {
    final current = h.game.currentNode;
    for (final sb in targets) {
      if (!identical(sb.root, h.game.root)) continue;
      GameNode? firstAdded;
      for (final n in sb.line()) {
        if (h.state.created.contains(n)) {
          firstAdded = n;
          break;
        }
      }
      if (firstAdded == null || firstAdded.parent == null) continue;
      final subtree = firstAdded.nodesInTree;
      if (subtree.every(h.state.created.contains) && !subtree.any((n) => identical(n, current))) {
        final added = firstAdded;
        added.parent!.children.removeWhere((c) => identical(c, added));
        pruned += subtree.length;
      }
    }
    h.host.redrawMoveTree();
  }
  for (final sb in targets) {
    boxes.remove(sb.id);
  }
  return {'dropped': targets.length, 'pruned_nodes': pruned};
}

final Map<String, ApiCommand> sandboxCommands = {
  'sandbox.new': const ApiCommand(
    _cmdSandboxNew,
    "Start a background cursor at a node of the user's game (default: the position the user is viewing).",
  ),
  'sandbox.play': const ApiCommand(
    _cmdSandboxPlay,
    "Play moves at the sandbox cursor. They are kept as variations in the user's game; the board does not move.",
  ),
  'sandbox.back': const ApiCommand(
    _cmdSandboxBack,
    'Move the sandbox cursor back n moves (not past where it started).',
  ),
  'sandbox.board': const ApiCommand(_cmdSandboxBoard, 'Board at the sandbox cursor.'),
  'sandbox.analyze': const ApiCommand(
    _cmdSandboxAnalyze,
    "Analyze the sandbox position at low priority; results are stored in the user's game. moves=[...] compares",
    waitsForEngine: true,
  ),
  'sandbox.show': const ApiCommand(
    _cmdSandboxShow,
    "Bring a sandbox line to the user's board: as=pv (numbered-stone overlay from the start, default) or as=goto",
  ),
  'sandbox.list': const ApiCommand(_cmdSandboxList, 'All sandboxes of the current game.'),
  'sandbox.drop': const ApiCommand(
    _cmdSandboxDrop,
    'Forget a sandbox (id=all for every one). prune=true also deletes the variations it added, as long as they',
  ),
};
