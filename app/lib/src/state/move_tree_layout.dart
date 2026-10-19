// Where the move tree draws each node.

import 'dart:math' as math;

import 'package:katrain_core/katrain_core.dart';

/// The positions of the move tree's nodes: (column = depth along the drawn tree, row).
Map<GameNode, (int, int)> moveTreeLayout(GameNode root) {
  List<GameNode> childrenWithShortcuts(GameNode move) {
    final via = {for (final (m, v) in move.shortcutsTo) v: m}; // children that are shortcut
    return [for (final m in move.orderedChildren) via[m] ?? m];
  }

  final movePos = <GameNode, (int, int)>{root: (0, 0)};
  final stack = childrenWithShortcuts(root).reversed.toList();
  final nextYPos = <int, int>{};
  while (stack.isNotEmpty) {
    final move = stack.removeLast();
    final from = move.shortcutFrom;
    final parent = (from != null && movePos.containsKey(from)) ? from : move.parent; // ignore broken shortcuts
    final x = parent != null ? movePos[parent]!.$1 + 1 : 0;
    final y = math.max(nextYPos[x] ?? 0, movePos[parent]!.$2);
    nextYPos[x] = y + 1;
    nextYPos[x - 1] = math.max(nextYPos[x]!, nextYPos[x - 1] ?? 0);
    movePos[move] = (x, y);
    stack.addAll(childrenWithShortcuts(move).reversed); // stack, so push top child last to process first
  }
  return movePos;
}
