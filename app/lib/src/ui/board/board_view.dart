// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/gui/badukpan.py: BadukPanWidget's input
// handling (the ghost stone and playing, selecting a region, hovering over hints to animate their variation,
// clicking old moves for their comments, double clicking to go back there, middle clicking to add a variation).

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../../state/katrain_gui.dart';
import 'board_geometry.dart';
import 'board_images.dart';
import 'board_painters.dart';

class BoardView extends StatefulWidget {
  final KaTrainGui gui;
  final BoardImages images;

  /// Where the pass button is on screen, for passes in variations.
  final Rect? Function()? passButtonRect;

  const BoardView({super.key, required this.gui, required this.images, this.passButtonRect});

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<BoardView> {
  BoardGeometry? _geo;
  Timer? _animation;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastTapPos = Offset.zero;

  KaTrainGui get gui => widget.gui;

  @override
  void initState() {
    super.initState();
    // animate the variation (badukpan.py schedules animate_pv every 0.1 s)
    _animation = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (gui.board.pv != null) gui.board.notifyHover();
    });
  }

  @override
  void dispose() {
    _animation?.cancel();
    super.dispose();
  }

  BoardGeometry _geometry(Size size) {
    final game = gui.game!;
    final (sx, sy) = game.boardSize;
    final old = _geo;
    if (old != null &&
        old.width == size.width &&
        old.height == size.height &&
        old.sizeX == sx &&
        old.sizeY == sy &&
        old.rotation == gui.board.rotationDegree &&
        old.coordinates == gui.board.drawCoordsEnabled &&
        listEquals(old.zoom, gui.board.zoomRegion)) {
      return old;
    }
    return _geo = BoardGeometry(
      width: size.width,
      height: size.height,
      sizeX: sx,
      sizeY: sy,
      rotation: gui.board.rotationDegree,
      coordinates: gui.board.drawCoordsEnabled,
      zoom: gui.board.zoomRegion,
    );
  }

  bool get _animEnabled => ((gui.config('general/anim_pv_moves') ?? 0) as num) != 0;

  void _checkNextMoveGhost(Offset p) {
    final geo = _geo;
    if (geo == null) return;
    final c = geo.closest(p);
    final prev = gui.board.ghostStone;
    final stones = {for (final m in gui.game!.stones) m.coords};
    if ((c.dx > c.dy ? c.dx : c.dy) < geo.gridSize / 2 && !stones.contains((c.x, c.y))) {
      gui.board.ghostStone = (c.x, c.y);
    } else {
      gui.board.ghostStone = null;
    }
    if (prev != gui.board.ghostStone) gui.board.notifyHover();
  }

  void _updateBoxSelection(Offset p, {bool secondPoint = true}) {
    final geo = _geo;
    if (geo == null) return;
    final c = geo.closest(p);
    final roi = gui.board.regionOfInterest;
    if (secondPoint && roi.length == 4) {
      roi[1] = c.x;
      roi[3] = c.y;
    } else {
      gui.board.regionOfInterest = [c.x, c.x, c.y, c.y];
    }
    gui.board.notifyHover();
  }

  void _onPointerDown(PointerDownEvent e) {
    final animating = gui.board.pv;
    if (e.buttons & kPrimaryButton != 0) {
      if (gui.board.selectingRegionOfInterest) {
        _updateBoxSelection(e.localPosition, secondPoint: false);
      } else {
        _checkNextMoveGhost(e.localPosition);
      }
    } else if (e.buttons & kMiddleMouseButton != 0 && animating != null) {
      var node = animating.node;
      final upto = animating.index ?? 1 << 30;
      for (var i = 0; i < animating.moves.length; i++) {
        if (i <= upto) {
          // up to move when scrolling, or all
          node = node.play(Move.fromGtp(animating.moves[i], player: node.nextPlayer));
          node.analyze(gui.engine!, analyzeFast: true);
        }
      }
      gui.redrawMoveTree();
    }
    if (e.buttons & kMiddleMouseButton == 0) {
      gui.board.pv = null; // any click/touch kills the variation, also one the API showed
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.buttons & kPrimaryButton == 0) return;
    if (gui.board.selectingRegionOfInterest) {
      _updateBoxSelection(e.localPosition);
    } else {
      _checkNextMoveGhost(e.localPosition);
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final geo = _geo;
    if (geo == null) return;
    final board = gui.board;
    final game = gui.game!;
    final now = DateTime.now();
    final doubleTap =
        now.difference(_lastTap) < const Duration(milliseconds: 250) &&
        (e.localPosition - _lastTapPos).distance < geo.gridSize;
    _lastTap = now;
    _lastTapPos = e.localPosition;
    if (board.selectingRegionOfInterest) {
      if (board.regionOfInterest.length == 4) {
        game.setRegionOfInterest(board.regionOfInterest);
        board.regionOfInterest = [];
        board.selectingRegionOfInterest = false;
      }
    } else if (board.ghostStone != null) {
      final currentNode = game.currentNode;
      final minimalUse = (gui.config('timer/minimal_use', 0) as num).toDouble();
      if (currentNode.children.isEmpty &&
          !gui.nextPlayerInfo.ai &&
          !gui.timer.paused &&
          gui.playAnalyzeMode == modePlay &&
          (gui.config('timer/main_time', 0) as num) * 60 - game.mainTimeUsed <= 0 &&
          currentNode.timeUsed < minimalUse) {
        gui.setStatus(pyFormat(i18n.tr('move too fast'), {'num': gui.config('timer/minimal_use', 0)}), statusTeaching);
      } else {
        gui.act('play', [board.ghostStone]);
      }
    } else {
      final c = geo.closest(e.localPosition);
      final nodesHere = [
        for (final node in game.currentNode.nodesFromRoot)
          if (node.move != null && node.move!.coords == (c.x, c.y)) node,
      ];
      if (nodesHere.isNotEmpty && (c.dx > c.dy ? c.dx : c.dy) < geo.gridSize / 2) {
        // load old comment
        final node = nodesHere.last;
        if (doubleTap) {
          // navigate to move
          gui.setCurrentNode(node.parent!);
        } else {
          gui.infoText = node.comment(sgf: true);
          gui.activeCommentNode = node;
          if (node.parent!.analysisExists) {
            board.setHoverPv(
              (node.parent!.candidateMoves[0]['pv'] as List).cast<String>(),
              node.parent,
              enabled: _animEnabled,
            );
          }
          gui.refresh();
        }
      }
    }
    board.ghostStone = null;
    board.notifyHover(); // remove ghost
  }

  void _onHover(PointerHoverEvent e) {
    final geo = _geo;
    if (geo == null || gui.game == null) return;
    final board = gui.board;
    final p = e.localPosition;
    if (!board.selectingRegionOfInterest && !board.pvPinned) {
      final near = [
        for (final (move, pv, node) in activePvMoves(gui))
          if ((geo.pos(move.$1, move.$2) - p).dx.abs() < geo.gridSize / 2 &&
              (geo.pos(move.$1, move.$2) - p).dy.abs() < geo.gridSize / 2)
            (pv, node),
      ];
      if (near.isNotEmpty) {
        board.setHoverPv(near[0].$1, near[0].$2, enabled: _animEnabled);
      } else if (board.pv != null) {
        board.setHoverPv(null, null, enabled: _animEnabled);
      }
    }
    final animating = board.pv;
    if (animating != null && !animating.pinned) {
      // badukpan.py squares only the x distance; kept as it is
      final dSq = (p.dx - animating.origin.$1) * (p.dx - animating.origin.$1) + (p.dy - animating.origin.$2);
      if (dSq > 2 * geo.stoneSize * geo.stoneSize) board.setHoverPv(null, null, enabled: _animEnabled);
    }
    board.lastMousePos = (p.dx, p.dy);
  }

  void _onScroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final up = e.scrollDelta.dy < 0;
    final board = gui.board;
    if (board.pv != null) {
      board.adjustAnimatePvIndex(
        up ? 1 : -1,
        delay: ((gui.config('general/anim_pv_time', 0.5) as num?) ?? 0.5).toDouble(),
        maxMoves: ((gui.config('general/anim_pv_moves') as num?) ?? 100).toInt(),
      );
    } else {
      gui.act(up ? 'redo' : 'undo'); // scroll through moves
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (gui.game == null) return const SizedBox.expand();
        final size = constraints.biggest;
        final geo = _geometry(size);
        final board = gui.board;
        return Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerSignal: _onScroll,
          child: MouseRegion(
            onHover: _onHover,
            child: Stack(
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    size: size,
                    painter: BoardBackgroundPainter(gui, widget.images, geo, board.boardChanges),
                  ),
                ),
                RepaintBoundary(
                  child: CustomPaint(size: size, painter: BoardContentsPainter(gui, widget.images, geo, gui)),
                ),
                RepaintBoundary(
                  child: CustomPaint(
                    size: size,
                    painter: BoardHoverPainter(
                      gui,
                      widget.images,
                      geo,
                      widget.passButtonRect,
                      Listenable.merge([gui, board.hoverChanges]),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
