// What the API keeps between commands: marks, saved states, the demo, registered variations, sandboxes and the
// tsumego problem; and the variation drawn over the board, which the app's board shares.

import '../game/game_node.dart';
import '../sgf/move.dart';
import 'model.dart' show nodeRef, gtp, regionJson;
import 'model.dart' as model;
import 'sandbox.dart';
import 'tsumego.dart';

/// A variation drawn over the board as numbered stones: [moves] played from [node], all of them animated one by
/// one, or the first `index + 1` when [index] is set. [pinned] for one the API shows, which hovering does not clear.
class PvOverlay {
  final List<String> moves;
  final GameNode node;
  int? index;
  bool pinned;

  /// When it started, for the animation, and where the mouse was (moving away clears a hover variation).
  final DateTime started;
  final (double, double) origin;

  PvOverlay(this.moves, this.node, {this.index, this.pinned = false, DateTime? started, this.origin = (0, 0)})
    : started = started ?? DateTime.now();

  PvOverlay copy() => PvOverlay(moves, node, index: index, pinned: pinned, started: started, origin: origin);
}

const markTypes = ['circle', 'square', 'triangle', 'cross', 'label', 'dot', 'area'];

/// A mark on a point, or (type `area`) a highlighted rectangle; on one node, or on every node when [nodeId] is null.
class Mark {
  final int id;
  final String type;
  final (int, int)? point;
  final List<int>? region;
  final List<double> rgb;
  final String color;
  final String? text;
  final int? nodeId;

  const Mark({
    required this.id,
    required this.type,
    this.point,
    this.region,
    required this.rgb,
    required this.color,
    this.text,
    this.nodeId,
  });

  bool visibleAt(GameNode node) => nodeId == null || nodeId == model.nodeId(node);

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'color': color,
    'text': text,
    if (point != null) 'point': gtp(point),
    if (region != null) 'region': regionJson(region),
    'node': nodeId == null ? null : 'n$nodeId',
  };
}

/// The marks shown at [current]: its own and the global ones.
List<Mark> visibleMarks(List<Mark> marks, GameNode current) => [
  for (final m in marks)
    if (m.visibleAt(current)) m,
];

/// A saved position with what was shown on it.
class Snapshot {
  final GameNode root;
  final GameNode node;
  final String mode;
  final List<int>? region;
  final List<Mark> marks;
  final PvOverlay? pv;
  final String message;
  final DateTime time = DateTime.now();

  Snapshot({
    required this.root,
    required this.node,
    required this.mode,
    required List<int>? region,
    required List<Mark> marks,
    required this.pv,
    required this.message,
  }) : region = region == null ? null : List.unmodifiable(region),
       marks = List.unmodifiable(marks);

  Map<String, Object?> toJson(String name) => {
    'name': name,
    'node': nodeRef(node),
    'move_number': node.depth,
    'mode': mode,
    'marks': marks.length,
    'pv': pv?.moves,
    'message': message.isEmpty ? null : message,
    'link': 'katrain://state/${Uri.encodeComponent(name)}',
    'saved': _isoSeconds(time),
  };

  static String _isoSeconds(DateTime t) => t.toIso8601String().substring(0, 19);
}

/// A demonstration in progress: everything added to the tree after it started goes again at its end.
class Demo {
  final Snapshot snapshot;
  final Set<GameNode> existing;
  final String? label;
  Demo(this.snapshot, Iterable<GameNode> nodes, this.label) : existing = Set.identity()..addAll(nodes);
}

/// A variation registered under a short id, to show later.
class RegisteredVariation {
  final GameNode from;
  final List<Move> moves;
  final String? label;
  RegisteredVariation(this.from, this.moves, this.label);

  GameNode get root => from.root;
}

class ApiState {
  List<Mark> marks = [];
  int _markId = 1;
  final Map<String, Snapshot> snapshots = {};
  Demo? demo;

  /// Nodes created through the API (only these may be deleted without force).
  final Set<GameNode> created = Set.identity();
  final Map<String, RegisteredVariation> variations = {};
  int _variationId = 1;
  TsumegoState? tsumego;
  final Map<String, Sandbox> sandboxes = {};
  int _sandboxId = 1;

  int nextMarkId() => _markId++;
  String nextVariationId() => 'v${_variationId++}';
  String nextSandboxId() => 's${_sandboxId++}';
}
