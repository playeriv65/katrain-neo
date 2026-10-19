// The nodes the score graph shows.

import 'package:katrain_core/katrain_core.dart';

/// The nodes the score graph shows: the current line, kept as the user navigates.
class GraphModel {
  List<GameNode?> nodes = [];
  int highlightedIndex = 0;

  void initializeFromGame(GameNode root) {
    nodes = [root];
    var node = root;
    while (node.children.isNotEmpty) {
      node = node.orderedChildren[0];
      nodes.add(node);
    }
    highlightedIndex = 0;
  }

  void updateValue(GameNode node) {
    final index = highlightedIndex = node.depth;
    while (nodes.length - 1 < index) {
      nodes.add(null);
    }
    nodes[index] = node;
    if (index > 1 && node.parent != null) {
      // sometimes there are gaps
      var backfill = index - 1;
      GameNode? bfnode = node.parent;
      while (bfnode != null && !identical(nodes[backfill], bfnode)) {
        nodes[backfill] = bfnode;
        backfill -= 1;
        bfnode = bfnode.parent;
      }
    }
    if (index + 1 < nodes.length && (node.children.isEmpty || !identical(nodes[index + 1], node.orderedChildren[0]))) {
      nodes = nodes.sublist(0, index + 1); // on branch switching, don't show history from other branch
    }
    if (index == nodes.length - 1) {
      // possibly just switched branch or the line above triggered
      var n = node;
      while (n.children.isNotEmpty) {
        n = n.orderedChildren[0];
        nodes.add(n);
      }
    }
  }
}
