// The board's input: the ghost stone and playing, selecting a region, hovering over hints to animate their
// variation, clicking old moves for their comments, double clicking to go back there, middle clicking to add a
// variation, scrolling through moves.

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../../state/app_controller.dart';
import 'board_geometry.dart';
import 'board_images.dart';
import 'board_painters.dart';

class BoardView extends StatefulWidget {
  final AppController app;
  final BoardImages images;

  /// Where the pass button is on screen, for passes in variations.
  final Rect? Function()? passButtonRect;

  const BoardView({super.key, required this.app, required this.images, this.passButtonRect});

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<BoardView> {
  BoardGeometry? _geo;
  Timer? _animation;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastTapPos = Offset.zero;

  /// The buttons of the press being released: only the left button (or a touch) plays and clicks old moves.
  int _pressedButtons = 0;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    // animate the variation
    _animation = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (app.board.pv != null) app.board.notifyHover();
    });
  }

  @override
  void dispose() {
    _animation?.cancel();
    super.dispose();
  }

  BoardGeometry _geometry(Size size) {
    final game = app.game!;
    final (sx, sy) = game.boardSize;
    final old = _geo;
    if (old != null &&
        old.width == size.width &&
        old.height == size.height &&
        old.sizeX == sx &&
        old.sizeY == sy &&
        old.rotation == app.board.rotationDegree &&
        old.coordinates == app.board.drawCoordsEnabled &&
        listEquals(old.zoom, app.board.zoomRegion)) {
      return old;
    }
    return _geo = BoardGeometry(
      width: size.width,
      height: size.height,
      sizeX: sx,
      sizeY: sy,
      rotation: app.board.rotationDegree,
      coordinates: app.board.drawCoordsEnabled,
      zoom: app.board.zoomRegion,
    );
  }

  void _checkNextMoveGhost(Offset p) {
    final geo = _geo;
    if (geo == null) return;
    final c = geo.closest(p);
    final prev = app.board.ghostStone;
    final stones = {for (final m in app.game!.stones) m.coords};
    if ((c.dx > c.dy ? c.dx : c.dy) < geo.gridSize / 2 && !stones.contains((c.x, c.y))) {
      app.board.ghostStone = (c.x, c.y);
    } else {
      app.board.ghostStone = null;
    }
    if (prev != app.board.ghostStone) app.board.notifyHover();
  }

  void _updateBoxSelection(Offset p, {bool secondPoint = true}) {
    final geo = _geo;
    if (geo == null) return;
    final c = geo.closest(p);
    final roi = app.board.regionOfInterest;
    if (secondPoint && roi.length == 4) {
      roi[1] = c.x;
      roi[3] = c.y;
    } else {
      app.board.regionOfInterest = [c.x, c.x, c.y, c.y];
    }
    app.board.notifyHover();
  }

  void _onPointerDown(PointerDownEvent e) {
    _pressedButtons = e.buttons;
    final animating = app.board.pv;
    if (e.buttons & kPrimaryButton != 0) {
      if (app.board.selectingRegionOfInterest) {
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
          node.analyze(app.engine!, analyzeFast: true);
        }
      }
      app.redrawMoveTree();
    }
    if (e.buttons & kMiddleMouseButton == 0) {
      app.board.pv = null; // any click/touch kills the variation, also one the API showed
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.buttons & kPrimaryButton == 0) return;
    if (app.board.selectingRegionOfInterest) {
      _updateBoxSelection(e.localPosition);
    } else {
      _checkNextMoveGhost(e.localPosition);
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    final geo = _geo;
    if (geo == null || _pressedButtons & kPrimaryButton == 0) return;
    final board = app.board;
    final game = app.game!;
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
      final minimalUse = (app.config('timer/minimal_use', 0) as num).toDouble();
      if (currentNode.children.isEmpty &&
          !app.nextPlayerInfo.ai &&
          !app.clock.paused &&
          app.mode == modePlay &&
          (app.config('timer/main_time', 0) as num) * 60 - game.mainTimeUsed <= 0 &&
          currentNode.timeUsed < minimalUse) {
        app.setStatus(
          fillTemplate(i18n.tr('move too fast'), {'num': app.config('timer/minimal_use', 0)}),
          statusTeaching,
        );
      } else {
        app.play(board.ghostStone);
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
          app.setCurrentNode(node.parent!);
        } else {
          app.infoParts = node.commentParts(sgf: true);
          app.activeCommentNode = node;
          if (node.parent!.analysisExists) {
            board.setHoverPv(
              (node.parent!.candidateMoves[0]['pv'] as List).cast<String>(),
              node.parent,
              enabled: app.showPvs,
            );
          }
          app.refresh();
        }
      }
    }
    board.ghostStone = null;
    board.notifyHover(); // remove ghost
  }

  void _onHover(PointerHoverEvent e) {
    final geo = _geo;
    if (geo == null || app.game == null) return;
    final board = app.board;
    final p = e.localPosition;
    if (!board.selectingRegionOfInterest && !board.pvPinned) {
      final near = [
        for (final (move, pv, node) in activePvMoves(app))
          if ((geo.pos(move.$1, move.$2) - p).dx.abs() < geo.gridSize / 2 &&
              (geo.pos(move.$1, move.$2) - p).dy.abs() < geo.gridSize / 2)
            (pv, node),
      ];
      if (near.isNotEmpty) {
        board.setHoverPv(near[0].$1, near[0].$2, enabled: app.showPvs);
      } else if (board.pv != null) {
        board.setHoverPv(null, null, enabled: app.showPvs);
      }
    }
    final animating = board.pv;
    if (animating != null && !animating.pinned) {
      final dSq = (p.dx - animating.origin.$1) * (p.dx - animating.origin.$1) + (p.dy - animating.origin.$2);
      if (dSq > 2 * geo.stoneSize * geo.stoneSize) board.setHoverPv(null, null, enabled: app.showPvs);
    }
    board.lastMousePos = (p.dx, p.dy);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (app.game == null) return const SizedBox.expand();
        final size = constraints.biggest;
        final geo = _geometry(size);
        final board = app.board;
        return Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          child: MouseRegion(
            onHover: _onHover,
            child: Stack(
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    size: size,
                    painter: BoardBackgroundPainter(app, widget.images, geo, board.boardChanges),
                  ),
                ),
                RepaintBoundary(
                  child: CustomPaint(size: size, painter: BoardContentsPainter(app, widget.images, geo, app)),
                ),
                RepaintBoundary(
                  child: CustomPaint(
                    size: size,
                    painter: BoardHoverPainter(
                      app,
                      widget.images,
                      geo,
                      widget.passButtonRect,
                      Listenable.merge([app, board.hoverChanges]),
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
