// Ported from pysgf (https://github.com/sanderland/pysgf, MIT, (c) 2020 Sander Land), class BaseGoNode.

import 'dart:collection';
import 'dart:math' as math;

import 'move.dart';
import '../utils/format.dart';

/// A node of an SGF game tree: its properties, children and the Go-specific views on them (moves, placements,
/// players, board size).
///
/// [N] is the concrete node type, so that [play] and the parser create nodes of the same kind, as `type(self)` does in
/// pysgf. Property values are kept as strings; non-string values are converted the way Python's `str` would.
abstract class BaseGoNode<N extends BaseGoNode<N>> {
  final List<N> children = [];
  final LinkedHashMap<String, List<String>> properties = LinkedHashMap();
  N? _parent;
  N? _root;
  int? _depth;
  List<Move>? _movesCache;

  BaseGoNode({N? parent, Map<String, Object?>? properties, Move? move}) {
    if (properties != null) {
      properties.forEach(setProperty);
    }
    this.parent = parent;
    if (parent != null) {
      parent.children.add(this as N);
    }
    if (parent != null && move != null) {
      setProperty(move.player, move.sgf(boardSize));
    }
    _clearCache();
  }

  /// Creates a node of the same type, the equivalent of `type(self)(parent=..., move=...)`.
  N newNode({N? parent, Move? move});

  void _clearCache() {
    _movesCache = null;
  }

  /// Properties as written to SGF. Subclasses add their own (comments, analysis).
  Map<String, List<String>> sgfProperties([Object? options]) => {
    for (final entry in properties.entries) entry.key: List.of(entry.value),
  };

  /// Children in the order they are written and shown; subclasses may reorder.
  List<N> orderChildren(List<N> children) => children;

  List<N> get orderedChildren => orderChildren(children);

  static String escapeValue(String value) => value.replaceAllMapped(RegExp(r'([\]\\])'), (m) => '\\${m[1]}');

  static String unescapeValue(String value) => value.replaceAllMapped(RegExp(r'\\([\]\\])'), (m) => m[1]!);

  /// The tree below and including this node in SGF format.
  String sgf([Object? options]) {
    String nodeSgf(N node) {
      final buffer = StringBuffer(';');
      node.sgfProperties(options).forEach((prop, values) {
        if (values.isEmpty) return;
        buffer.write(prop);
        for (final v in values) {
          buffer.write('[${escapeValue(v)}]');
        }
      });
      return buffer.toString();
    }

    final stack = <Object>[')', this, '('];
    final out = StringBuffer();
    while (stack.isNotEmpty) {
      final item = stack.removeLast();
      if (item is String) {
        out.write(item);
      } else {
        final node = item as N;
        out.write(nodeSgf(node));
        if (node.children.length == 1) {
          stack.add(node.children[0]);
        } else if (node.children.isNotEmpty) {
          for (final child in node.orderedChildren.reversed) {
            stack.addAll([')', child, '(']);
          }
        }
      }
    }
    return out.toString();
  }

  static final RegExp _lowercase = RegExp('[a-z]');

  /// Adds values to a property; long FF[3] names like `AddBlack` are reduced to their capitals (`AB`).
  void addListProperty(String property, List<String> values) {
    final normalized = property.replaceAll(_lowercase, '');
    _clearCache();
    properties.putIfAbsent(normalized, () => []).addAll(values);
  }

  List<String>? getListProperty(String property) => properties[property];

  void setProperty(String property, Object? value) {
    final values = value is List ? [for (final v in value) '$v'] : ['$value'];
    _clearCache();
    properties[property] = values;
  }

  /// First value of a property, or [defaultValue] when it is missing.
  String? getProperty(String property, [String? defaultValue]) {
    final values = properties[property];
    if (values == null) return defaultValue;
    return values.isEmpty ? null : values[0];
  }

  List<String>? clearProperty(String property) => properties.remove(property);

  N? get parent => _parent;

  set parent(N? parentNode) {
    _parent = parentNode;
    _root = null;
    _depth = null;
  }

  N get root => _root ??= _parent?.root ?? this as N;

  /// Number of moves from the root (a node with two moves counts twice, as in pysgf).
  int get depth => _depth ??= isRoot ? 0 : _parent!.depth + moves.length;

  (int, int) get boardSize {
    final size = root.getProperty('SZ', '19')!;
    if (size.contains(':')) {
      final parts = size.split(':');
      return (int.parse((parts[0]).trim()), int.parse((parts[1]).trim()));
    }
    final x = int.parse((size).trim());
    return (x, x);
  }

  double get komi => double.tryParse(root.getProperty('KM', '6.5')!.trim()) ?? 6.5;

  int get handicap => int.tryParse(root.getProperty('HA', '0')!.trim()) ?? 0;

  String get ruleset => root.getProperty('RU', 'japanese')!;

  List<Move> get moves => _movesCache ??= [
    for (final player in Move.players.split(''))
      for (final move in getListProperty(player) ?? const <String>[]) Move.fromSgf(move, boardSize, player: player),
  ];

  List<Move> _expandedPlacements(String? player) {
    final placements = getListProperty('A${player ?? 'E'}') ?? const <String>[];
    if (placements.isEmpty) return [];
    // AE points have no player (None in pysgf); '' compares and behaves the same way here
    final pl = player ?? '';
    final size = boardSize;
    final toBeExpanded = placements.where((p) => p.contains(':')).toList();
    if (toBeExpanded.isEmpty) {
      return [for (final c in placements) Move.fromSgf(c, size, player: pl)];
    }
    // pysgf uses an unordered set here; insertion order keeps the result deterministic
    final coords = <Move>{
      for (final c in placements)
        if (!c.contains(':')) Move.fromSgf(c, size, player: pl),
    };
    for (final placement in toBeExpanded) {
      final ends = placement.split(':');
      final from = Move.fromSgf(ends[0], size);
      final to = Move.fromSgf(ends[1], size);
      for (var x = from.coords!.$1; x <= to.coords!.$1; x++) {
        for (var y = to.coords!.$2; y <= from.coords!.$2; y++) {
          if (0 <= x && x < size.$1 && 0 <= y && y < size.$2) {
            coords.add(Move(coords: (x, y), player: pl));
          }
        }
      }
    }
    return coords.toList();
  }

  /// Setup stones (AB, AW), black first.
  List<Move> get placements => [for (final p in Move.players.split('')) ..._expandedPlacements(p)];

  /// Cleared points (AE).
  List<Move> get clearPlacements => _expandedPlacements(null);

  List<Move> get moveWithPlacements => [...placements, ...moves];

  /// The move of this node, if it has exactly one.
  Move? get move {
    final m = moves;
    return m.length == 1 ? m[0] : null;
  }

  bool get isRoot => _parent == null;

  bool get isPass => placements.isEmpty && (move?.isPass ?? false);

  bool get empty => children.isEmpty && properties.isEmpty;

  /// All nodes of the subtree, breadth first.
  List<N> get nodesInTree {
    final queue = Queue<N>.of([this as N]);
    final nodes = <N>[];
    while (queue.isNotEmpty) {
      final item = queue.removeFirst();
      nodes.add(item);
      queue.addAll(item.children);
    }
    return nodes;
  }

  /// Nodes from the root down to this one.
  List<N> get nodesFromRoot {
    final nodes = <N>[this as N];
    var node = this as N;
    while (!node.isRoot) {
      node = node.parent!;
      nodes.add(node);
    }
    return nodes.reversed.toList();
  }

  /// The child with this move, created if there is none.
  N play(Move move) {
    for (final child in children) {
      if (child.move != null && child.move == move) return child;
    }
    return newNode(parent: this as N, move: move);
  }

  String get initialPlayer {
    final r = root;
    if (r.properties.containsKey('PL')) {
      return r.getProperty('PL')!.toUpperCase().trim() == 'B' ? 'B' : 'W';
    }
    for (final child in r.children) {
      for (final color in ['B', 'W']) {
        if (child.properties.containsKey(color)) return color;
      }
    }
    // pysgf checks this node's properties here, not the root's
    if (properties.containsKey('AB') && !properties.containsKey('AW')) return 'W';
    return 'B';
  }

  String get nextPlayer {
    if (isRoot) return initialPlayer;
    if (properties.containsKey('B')) return 'W';
    if (properties.containsKey('W')) return 'B';
    return _parent!.nextPlayer;
  }

  String get player {
    if (properties.containsKey('B') || (properties.containsKey('AB') && !properties.containsKey('W'))) return 'B';
    return 'W';
  }

  void placeHandicapStones(int nHandicaps, {bool tygem = false}) {
    final (sizeX, sizeY) = boardSize;
    if (math.min(sizeX, sizeY) < 3) return;
    var nearX = sizeX >= 13 ? 3 : math.min(2, sizeX - 1);
    final nearY = sizeY >= 13 ? 3 : math.min(2, sizeY - 1);
    var farX = sizeX - 1 - nearX;
    final farY = sizeY - 1 - nearY;
    final middleX = sizeX ~/ 2;
    final middleY = sizeY ~/ 2;
    List<(int, int)> stones;
    if (nHandicaps > 9 && sizeX == sizeY) {
      final stonesPerRow = math.sqrt(nHandicaps).ceil();
      var spacing = (farX - nearX) / (stonesPerRow - 1);
      if (spacing < nearX) {
        farX += 1;
        nearX -= 1;
        spacing = (farX - nearX) / (stonesPerRow - 1);
      }
      // pysgf takes these from a Python set; with more than 9 stones, which of several equally distant points are
      // chosen can differ from CPython's set order
      final coords = <int>{for (var i = 0; i < stonesPerRow; i++) (0.5 + nearX + i * spacing).floor()}.toList();
      stones = [
        for (final x in coords)
          for (final y in coords) (x, y),
      ];
      num distance((int, int) xy) => -(math.pow(xy.$1 - (sizeX - 1) / 2, 2) + math.pow(xy.$2 - (sizeY - 1) / 2, 2));
      stableSortBy(stones, distance);
    } else {
      stones = [(farX, farY), (nearX, nearY), (farX, nearY), (nearX, farY)];
      if (nHandicaps % 2 == 1) stones.add((middleX, middleY));
      stones.addAll([(nearX, middleY), (farX, middleY), (middleX, nearY), (middleX, farY)]);
    }
    if (tygem) {
      final tmp = stones[2];
      stones[2] = stones[3];
      stones[3] = tmp;
    }
    setProperty(
      'AB',
      <String>{for (final stone in stones.take(nHandicaps)) Move(coords: stone).sgf((sizeX, sizeY))}.toList(),
    );
  }
}

/// A plain SGF node, like pysgf's GoNode.
class GoNode extends BaseGoNode<GoNode> {
  GoNode({super.parent, super.properties, super.move});

  @override
  GoNode newNode({GoNode? parent, Move? move}) => GoNode(parent: parent, move: move);
}
