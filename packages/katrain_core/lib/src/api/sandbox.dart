// Background exploration cursors ("sandboxes") inside the user's own game tree.
//
// A sandbox is a cursor of the agent's, separate from the position the app shows. Moves the agent plays become
// ordinary variations in the user's game, and every analysis is stored in those nodes, so nothing computed in the
// background is thrown away: the user can browse the lines and their evaluations later without re-analysis.
// What a sandbox never does is move the user's board, draw over it, or outrank the app's own queries;
// `sandbox.show` is the explicit step that brings a line to the user's attention.

import '../game/game_node.dart';
import 'args.dart';
import 'commands.dart';
import 'model.dart';
import 'protocol.dart';

class Sandbox {
  final String id;
  final GameNode origin; // node of the user's game the exploration starts from
  GameNode cursor;
  Sandbox(this.id, this.origin) : cursor = origin;

  GameNode get root => origin.root;

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
          if (n.move case final m?) '${m.player}:${m.gtp()}',
      ],
      'nodes': [for (final n in nodes) nodeRef(n)],
      'at': nodeRef(cursor),
      'move_number': cursor.depth,
      'to_move': cursor.nextPlayer,
    };
  }

  Map<String, Object?> withBoard() => {...summary(), 'board': boardJson(cursor)['ascii']};
}

Sandbox _get(CommandHandler h, ApiArgs a) {
  final boxes = h.state.sandboxes;
  final id = a.text('id');
  final sb = boxes[id] ?? (throw ApiError('not_found', "no sandbox '$id'", {'available': boxes.keys.toList()..sort()}));
  if (!identical(h.game.root, sb.root)) {
    throw ApiError('game_changed', "the user's board shows a different game than this sandbox belongs to");
  }
  if (!sb.root.nodesInTree.any((n) => identical(n, sb.cursor))) {
    throw ApiError('not_found', 'the sandbox position was deleted from the game');
  }
  return sb;
}

Object? _new(CommandHandler h, ApiArgs a) {
  final id = a.text('name') ?? h.state.nextSandboxId();
  if (h.state.sandboxes.containsKey(id)) throw ApiError('exists', "sandbox '$id' already exists");
  return (h.state.sandboxes[id] = Sandbox(id, h.node(a, 'from'))).withBoard();
}

Object? _play(CommandHandler h, ApiArgs a) {
  final sb = _get(h, a);
  final (nodes, created) = h.addNodes(sb.cursor, h.moves(a, sb.cursor), analyze: 'none');
  sb.cursor = nodes.last;
  h.host.redrawMoveTree();
  return {...sb.withBoard(), 'created_nodes': created};
}

Object? _back(CommandHandler h, ApiArgs a) {
  final sb = _get(h, a);
  for (var i = a.integer('n', orElse: 1, min: 1)!; i > 0 && !identical(sb.cursor, sb.origin); i--) {
    sb.cursor = sb.cursor.parent!;
  }
  return sb.withBoard();
}

Future<Object?> _analyze(CommandHandler h, ApiArgs a) async {
  final timeout = a.integer('timeout', orElse: 300, min: 1)!;
  final sb = _get(h, a);
  final node = sb.cursor;
  final engine = h.engineFor(node);
  final visits = a.integer('visits', orElse: h.defaultVisits(engine), min: 1)!;
  final moves = h.candidates(node, a.words('moves'));
  final cached = moves.isEmpty && !a.flag('force') && node.analysisComplete && node.rootVisits >= 0.95 * visits;
  if (!cached && (moves.isEmpty || !node.analysisExists)) {
    await h.search(node, engine, visits, timeout: timeout, background: true);
  }
  for (final m in moves) {
    // one after the other: each comparison already fills the GPU
    await h.search(node, engine, visits, refineMove: m, timeout: timeout, background: true);
  }
  final result = analysisJson(
    node,
    top: moves.isEmpty ? a.integer('top', orElse: 10) : null,
    includePv: a.flag('pv', orElse: true),
    pvLimit: a.integer('pv_limit'),
    ownership: a.flag('ownership'),
    moves: moves.isEmpty ? null : [for (final m in moves) m.gtp()],
  );
  if (moves.isNotEmpty) sortByPointsLost(result['candidates'] as List<Map<String, Object?>>);
  return {'sandbox': sb.summary(), 'reused_existing': cached, 'requested_visits': visits, ...result};
}

Object? _show(CommandHandler h, ApiArgs a) {
  final sb = _get(h, a);
  final nodes = sb.line();
  if (nodes.isEmpty) throw ApiError('bad_argument', 'the sandbox has no moves yet');
  if (a.text('as') == 'goto') {
    h.goto(sb.cursor);
    return {'shown': 'goto', ...h.currentJson()};
  }
  final moves = [for (final n in nodes) ?n.move];
  return {'shown': 'pv', ...showPv(h, sb.origin, moves, a.integer('step', min: 1))};
}

Object? _list(CommandHandler h, ApiArgs a) => [
  for (final sb in h.state.sandboxes.values)
    if (identical(sb.root, h.game.root)) sb.summary(),
];

Object? _drop(CommandHandler h, ApiArgs a) {
  final boxes = h.state.sandboxes;
  final targets = a.text('id') == 'all' ? boxes.values.toList() : [_get(h, a)];
  var pruned = 0;
  if (a.flag('prune')) {
    final current = h.game.currentNode;
    for (final sb in targets.where((sb) => identical(sb.root, h.game.root))) {
      // the variation it added, as long as it holds only API-made nodes and nobody is looking at it
      final first = sb.line().where(h.state.created.contains).firstOrNull;
      if (first == null || first.parent == null) continue;
      final subtree = first.nodesInTree;
      if (subtree.every(h.state.created.contains) && !subtree.any((n) => identical(n, current))) {
        pruned += h.removeSubtree(first);
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
    _new,
    "Start a background cursor at a node of the user's game (default: the position the user is viewing).",
  ),
  'sandbox.play': const ApiCommand(
    _play,
    "Play moves at the sandbox cursor. They are kept as variations in the user's game; the board does not move.",
  ),
  'sandbox.back': const ApiCommand(_back, 'Move the sandbox cursor back n moves (not past where it started).'),
  'sandbox.board': ApiCommand((h, a) {
    final sb = _get(h, a);
    return {...sb.summary(), ...boardJson(sb.cursor)};
  }, 'Board at the sandbox cursor.'),
  'sandbox.analyze': const ApiCommand(
    _analyze,
    "Analyze the sandbox position at low priority; results are stored in the user's game. moves=[...] compares",
    waitsForEngine: true,
  ),
  'sandbox.show': const ApiCommand(
    _show,
    "Bring a sandbox line to the user's board: as=pv (numbered-stone overlay from the start, default) or as=goto",
  ),
  'sandbox.list': const ApiCommand(_list, 'All sandboxes of the current game.'),
  'sandbox.drop': const ApiCommand(
    _drop,
    'Forget a sandbox (id=all for every one). prune=true also deletes the variations it added, as long as they',
  ),
};
