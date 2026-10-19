// The move tree: stones numbered by move, the current and selected nodes, the insertion path, collapsed branches;
// scrolling to the current node, clicking to go to a node, and the right click menu.

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/app_controller.dart';
import '../state/move_tree_layout.dart';
import '../theme.dart';
import 'board/board_painters.dart';

const _spacing = 5.0;
const _movesVert = 3;

class MoveTree extends StatefulWidget {
  final AppController app;

  /// The height the tree has in play mode, which sizes its nodes (`min_height`).
  final double minHeight;
  const MoveTree({super.key, required this.app, required this.minHeight});

  @override
  State<MoveTree> createState() => _MoveTreeState();
}

class _MoveTreeState extends State<MoveTree> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();

  double get moveSize => (widget.minHeight - (_movesVert + 1) * _spacing) / _movesVert;

  double _coordPos(double coord) => (coord + 0.5) * (_spacing + moveSize) + _spacing / 2;

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  void _scrollTo(Offset p, Size viewport) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final (controller, target, extent) in [
        (_horizontal, p.dx - viewport.width / 2, viewport.width),
        (_vertical, p.dy - viewport.height / 2, viewport.height),
      ]) {
        if (!controller.hasClients || extent <= 0) continue;
        final max = controller.position.maxScrollExtent;
        controller.jumpTo(target.clamp(0, max));
      }
    });
  }

  Future<void> _contextMenu(Offset globalPosition, GameNode node) async {
    final app = widget.app;
    app.moveTreeSelectedNode = node;
    app.refresh();
    final items = <(String, IconData, String, VoidCallback)>[
      ('Delete Node', Icons.delete_outline, 'Ctr+Del', app.deleteSelectedNode),
      ('Make Main Branch', Icons.call_split, 'PgUp', app.makeSelectedNodeMainBranch),
      ('Toggle Collapse Branch', Icons.unfold_less, 'c', app.toggleSelectedNodeCollapse),
      ('Prune Branch', Icons.content_cut, '', app.pruneBranch),
    ];
    final choice = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(globalPosition.dx, globalPosition.dy, globalPosition.dx, globalPosition.dy),
      items: [
        for (final (i, (label, icon, shortcut, _)) in items.indexed)
          PopupMenuItem(
            value: i,
            height: 45,
            child: Row(
              children: [
                Icon(icon),
                const SizedBox(width: 12),
                Expanded(child: Text(i18n.tr(label))),
                const SizedBox(width: 16),
                Text(shortcut, style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
          ),
      ],
    );
    if (choice != null) {
      items[choice].$4();
    } else {
      app.moveTreeSelectedNode = null;
      app.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final game = app.game;
    if (game == null) return const SizedBox.expand();
    final positions = moveTreeLayout(game.root);
    final width = _coordPos(positions.values.map((p) => p.$1 + 0.5).reduce((a, b) => a > b ? a : b));
    final height = _coordPos(positions.values.map((p) => p.$2 + 0.5).reduce((a, b) => a > b ? a : b));
    final xy = {
      for (final e in positions.entries)
        e.key: Offset(_coordPos(e.value.$1.toDouble()), _coordPos(e.value.$2.toDouble())),
    };

    GameNode? nodeAt(Offset p) {
      GameNode? best;
      var bestD = double.infinity;
      for (final e in xy.entries) {
        final d = (e.value.dx - p.dx).abs() + (e.value.dy - p.dy).abs();
        if (d < bestD) {
          bestD = d;
          best = e.key;
        }
      }
      if (best == null) return null;
      final q = xy[best]!;
      return ((q.dx - p.dx).abs() <= moveSize / 2 && (q.dy - p.dy).abs() <= moveSize / 2) ? best : null;
    }

    return LayoutBuilder(
      builder: (context, c) {
        final current = xy[game.currentNode];
        if (current != null) _scrollTo(current, c.biggest);
        return SizedBox.expand(
          child: ScrollConfiguration(
            behavior: const ScrollBehavior().copyWith(scrollbars: false),
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                controller: _vertical,
                child: GestureDetector(
                  onTapUp: (d) {
                    final node = nodeAt(d.localPosition);
                    app.moveTreeSelectedNode = null;
                    if (node != null) app.setCurrentNode(node);
                  },
                  onSecondaryTapUp: (d) {
                    final node = nodeAt(d.localPosition);
                    if (node != null && !node.isRoot) _contextMenu(d.globalPosition, node);
                  },
                  child: CustomPaint(
                    size: Size(width, height),
                    painter: _MoveTreePainter(app, positions, xy, moveSize),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MoveTreePainter extends CustomPainter {
  final AppController app;
  final Map<GameNode, (int, int)> positions;
  final Map<GameNode, Offset> xy;
  final double moveSize;
  _MoveTreePainter(this.app, this.positions, this.xy, this.moveSize);

  List<GameNode> _children(GameNode move) {
    final via = {for (final (m, v) in move.shortcutsTo) v: m}; // children that are shortcut
    return [for (final m in move.orderedChildren) via[m] ?? m];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final game = app.game!;
    final currentNode = game.currentNode;
    final special = <GameNode, Color>{currentNode: KTheme.moveTreeCurrent};
    final selected = app.moveTreeSelectedNode;
    if (selected != null) special[selected] = KTheme.moveTreeSelected;
    final insertNode = app.insertNodeValue;
    if (insertNode != null && insertNode.parent != null) {
      special[insertNode.parent!] = KTheme.moveTreeInsertNodeParent;
      GameNode insertPath = currentNode;
      while (!identical(insertPath, insertNode.parent) && insertPath.parent != null) {
        special[insertPath] = identical(insertPath, currentNode)
            ? KTheme.moveTreeInsertCurrent
            : KTheme.moveTreeInsertOther;
        insertPath = insertPath.parent!;
      }
    }
    final line = Paint()
      ..color = KTheme.moveTreeLine
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final e in xy.entries) {
      final p = e.value;
      for (final c in _children(e.key)) {
        final q = xy[c];
        if (q == null) continue;
        canvas.drawPath(
          Path()
            ..moveTo(p.dx, p.dy)
            ..lineTo(p.dx, q.dy)
            ..lineTo(q.dx, q.dy),
          line,
        );
      }
    }
    for (final e in xy.entries) {
      final node = e.key;
      final pos = e.value;
      final mark = special[node];
      if (mark != null) {
        canvas.drawRect(
          Rect.fromCenter(center: pos, width: moveSize + _spacing, height: moveSize + _spacing),
          Paint()..color = mark,
        );
      }
      final placements = [...node.placements, ...node.clearPlacements];
      final collapsed = node.shortcutFrom != null || placements.isNotEmpty ? KTheme.moveTreeCollapsed : null;
      final player = node.player;
      drawCircle(canvas, pos, moveSize / 2 - 0.5, collapsed ?? KTheme.stoneColors[player]!);
      canvas.drawCircle(
        pos,
        moveSize / 2,
        Paint()
          ..color = KTheme.moveTreeStoneOutlineColors[player]!
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      final text = placements.isNotEmpty ? '+' : '${node.depth}';
      drawText(
        canvas,
        pos,
        text,
        fontSize: moveSize * 1.75 / (1 + text.length),
        color: KTheme.stoneColors[player == 'B' && node.shortcutFrom == null ? 'W' : 'B']!,
      );
    }
  }

  @override
  bool shouldRepaint(_MoveTreePainter old) => true;
}
