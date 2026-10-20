// Drawing the board in three layers: the board itself (texture, lines, star points, coordinates); its contents
// (territory, stones with evaluation dots, last move and move numbers, policy); and what changes on hover (top moves,
// next moves, the ghost stone, variations, the region of interest, the pass circle, marks).

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:katrain_core/api.dart' show visibleMarks;
import 'package:katrain_core/katrain_core.dart';

import '../../state/app_controller.dart';
import '../../theme.dart';
import '../app_theme.dart' show fontFallback;
import 'board_geometry.dart';
import 'board_images.dart';

/// Draws [text] centred on [pos], bold, as all text on the board.
void drawText(
  Canvas canvas,
  Offset pos,
  String text, {
  required double fontSize,
  required Color color,
  String? font = KTheme.boardFont,
  List<String>? fallback,
}) {
  if (fontSize <= 0) return;
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: font,
        fontFamilyFallback: fallback,
        fontSize: fontSize,
        fontWeight: FontWeight.bold,
        color: color,
        height: 1.0,
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
  )..layout();
  painter.paint(canvas, pos - Offset(painter.width / 2, painter.height / 2));
}

void drawCircle(Canvas canvas, Offset pos, double r, Color color) {
  canvas.drawCircle(pos, r, Paint()..color = color);
}

/// A circle or an arc of one: angles in degrees clockwise from the top.
void drawArc(Canvas canvas, Offset pos, double r, Color color, double width, [double start = 0, double end = 360]) {
  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width;
  if (end - start >= 360) {
    canvas.drawCircle(pos, r, paint);
  } else {
    final rect = Rect.fromCircle(center: pos, radius: r);
    canvas.drawArc(rect, (start - 90) * math.pi / 180, (end - start) * math.pi / 180, false, paint);
  }
}

/// The trainer settings the board uses.
Map<String, dynamic> trainerConfig(AppController app) => (app.config('trainer') as Map).cast<String, dynamic>();

Color? evalColor(AppController app, double pointsLost, [List<bool>? showDotsForClass]) {
  final tc = trainerConfig(app);
  final i = evaluationClass(pointsLost, (tc['eval_thresholds'] as List).cast<num>());
  final colors = KTheme.evalColors[tc['theme']]!;
  if (showDotsForClass == null || showDotsForClass[i]) return colors[i];
  return null;
}

/// The board itself: texture, lines, star points and coordinates.
class BoardBackgroundPainter extends CustomPainter {
  final AppController app;
  final BoardImages images;
  final BoardGeometry geo;
  BoardBackgroundPainter(this.app, this.images, this.geo, Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final game = app.game;
    if (game == null || !geo.valid) return;
    final tint = game.insertMode ? KTheme.insertBoardColorTint : KTheme.boardColorTint; // dreamy in insert mode
    drawTexture(canvas, images[KTheme.boardTexture], geo.boardRect, tint);
    final line = Paint()
      ..color = KTheme.lineColor
      ..strokeWidth = 1;
    final xs = geo.columnsX;
    final ys = geo.rowsY;
    // zoomed: real board edges are edges, cut sides let the lines run on a little
    final zoom = geo.zoom;
    final runOn = KTheme.zoomLineRunOn * geo.gridSize;
    final left = xs.first - (zoom == null || zoom[0] == 0 ? 0 : runOn);
    final right = xs.last + (zoom == null || zoom[1] == geo.sizeX - 1 ? 0 : runOn);
    final bottom = ys.first + (zoom == null || zoom[2] == 0 ? 0 : runOn);
    final top = ys.last - (zoom == null || zoom[3] == geo.sizeY - 1 ? 0 : runOn);
    for (final x in xs) {
      canvas.drawLine(Offset(x, bottom), Offset(x, top), line);
    }
    for (final y in ys) {
      canvas.drawLine(Offset(left, y), Offset(right, y), line);
    }
    List<int> starPointCoords(int size) {
      final starPointPos = size <= 11 ? 3 : 4;
      if (size < 7) return [];
      return [starPointPos - 1, size - starPointPos, if (size % 2 == 1 && size > 7) size ~/ 2];
    }

    final starptSize = geo.gridSize * KTheme.starpointSize;
    for (final x in starPointCoords(geo.sizeX)) {
      for (final y in starPointCoords(geo.sizeY)) {
        if (geo.isVisible(x, y)) drawCircle(canvas, geo.pos(x, y), starptSize, KTheme.lineColor);
      }
    }
    if (geo.coordinates) {
      // centred between an edge stone's rim and the board's edge, so stones on the first line never cover them
      final coordOffset = geo.gridSize * (KTheme.stoneSize + geo.marginX[0]) / 2;
      final color = kc([0.25, 0.25, 0.25, 1]);
      for (var i = 0; i < geo.displayX; i++) {
        drawText(
          canvas,
          Offset(xs[i], ys[0] + coordOffset),
          geo.xLabel(i, Move.gtpCoord),
          fontSize: geo.gridSize / 1.5,
          color: color,
        );
      }
      for (var i = 0; i < geo.displayY; i++) {
        drawText(
          canvas,
          Offset(xs[0] - coordOffset, ys[i]),
          geo.yLabel(i, Move.gtpCoord),
          fontSize: geo.gridSize / 1.5,
          color: color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(BoardBackgroundPainter old) => old.geo != geo;
}

/// Territory, stones and policy.
class BoardContentsPainter extends CustomPainter {
  final AppController app;
  final BoardImages images;
  final BoardGeometry geo;
  BoardContentsPainter(this.app, this.images, this.geo, Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final game = app.game;
    if (game == null || !geo.valid) return;
    final tc = trainerConfig(app);
    final (sizeX, sizeY) = game.boardSize;
    final showNEval = (tc['eval_on_show_last'] ?? 3) as int;
    if (geo.viewClip != null) canvas.clipRect(geo.viewClip!);
    final hidden = app.board.hiddenCoords;
    List<List<double>>? ownershipGrid;
    List<List<double>>? lossGrid;
    final currentNode = game.currentNode;

    // ownership - allow one move out of date for smooth animation,
    // drawn first so the board is shaded underneath all other elements.
    final ownership = currentNode.ownership ?? currentNode.parent?.ownership;
    if (app.analysisControls['ownership']! && ownership != null && ownership.isNotEmpty) {
      final lastChild = currentNode.children.isNotEmpty ? currentNode.children.last : null;
      if (lastChild != null &&
          app.statusState.$2 == statusTeaching &&
          lastChild.autoUndo == true &&
          lastChild.ownership != null) {
        // loss
        final childOwnership = lastChild.ownership!;
        final sign = lastChild.move!.player == 'B' ? -1 : 1;
        lossGrid = varToGrid(
          [
            for (var i = 0; i < math.min(childOwnership.length, ownership.length); i++)
              math.max(0.0, sign * (childOwnership[i] - ownership[i])),
          ],
          (sizeX, sizeY),
        );
        _drawTerritory(canvas, lossGrid, KTheme.evalColors[tc['theme']]![1]);
      } else {
        ownershipGrid = varToGrid(ownership, (sizeX, sizeY));
        _drawTerritory(canvas, ownershipGrid);
      }
    }

    // stones
    final allDotsOff = !app.analysisControls['eval']!;
    final hasStone = {for (final m in game.stones) m.coords!: m.player};
    final drawnStone = <(int, int)>{};
    final showDotsFor = {
      for (final p in const ['B', 'W']) p: (tc['eval_show_ai'] ?? true) == true || app.playersInfo[p]!.human,
    };
    final showDotsForClass = (tc['show_dots'] as List).cast<bool>();
    final nodes = currentNode.nodesFromRoot;
    double? realizedPointsLost;
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[nodes.length - 1 - i]; // reverse order!
      final pointsLost = node.pointsLost;
      var evalscale = 1.0;
      if (pointsLost != null && pointsLost != 0 && realizedPointsLost != null && realizedPointsLost != 0) {
        if (pointsLost <= 0.5 && realizedPointsLost <= 1.5) {
          evalscale = 0;
        } else {
          evalscale = math.min(1, math.max(0, realizedPointsLost / pointsLost));
        }
      }
      final placements = node.placements;
      for (final m in [...node.moves, ...placements]) {
        final c = m.coords;
        if (c == null || hidden.contains(c)) continue;
        final newMove = currentNode.move != null && c == currentNode.move!.coords && currentNode.ownership == null;
        if (hasStone[c] != null && !drawnStone.contains(c)) {
          // skip captures, last only for
          final moveEvalOn = !allDotsOff && showDotsFor[m.player]! && i < showNEval;
          final evalcol = moveEvalOn && pointsLost != null ? evalColor(app, pointsLost, showDotsForClass) : null;
          final inner = i == 0 && !placements.contains(m) ? KTheme.stoneColors[m.opponent] : null;
          drawnStone.add(c);
          drawStone(
            canvas,
            c.$1,
            c.$2,
            m.player,
            innercol: inner,
            evalcol: evalcol,
            evalscale: evalscale,
            ownership: ownershipGrid != null && lossGrid == null && !newMove ? ownershipGrid[c.$2][c.$1] : null,
            loss: lossGrid?[c.$2][c.$1],
            depth: app.showMoveNum ? node.depth : null,
          );
        }
      }
      realizedPointsLost = node.parentRealizedPointsLost;
    }

    if (currentNode.isRoot && app.debugLevel >= 3) {
      // secret ;)
      for (var y = 0; y < sizeY; y++) {
        final evalcol = evalColor(app, 16 * y / sizeY);
        drawStone(canvas, 0, y, 'B', evalcol: evalcol, evalscale: y / (sizeY - 1));
        drawStone(canvas, 1, y, 'B', innercol: KTheme.stoneColors['W'], evalcol: evalcol);
        drawStone(canvas, 2, y, 'W', evalcol: evalcol, evalscale: y / (sizeY - 1));
        drawStone(canvas, 3, y, 'W', innercol: KTheme.stoneColors['B'], evalcol: evalcol);
      }
    }

    final policy = boardPolicy(app);
    if (app.analysisControls['policy']! && policy != null) {
      final policyGrid = varToGrid(policy, (sizeX, sizeY));
      final bestMovePolicy = policy.reduce(math.max);
      final colors = KTheme.evalColors[tc['theme']]!;
      const textLb = 0.01 * 0.01;
      for (var y = sizeY - 1; y >= 0; y--) {
        for (var x = 0; x < sizeX; x++) {
          final movePolicy = policyGrid[y][x];
          if (movePolicy < 0) continue;
          final polOrder = math.max(0, 5 + (math.log(math.max(1e-9, movePolicy - 1e-9)) / math.ln10).truncate());
          final pos = geo.pos(x, y);
          final double scale;
          if (movePolicy > textLb) {
            drawCircle(canvas, pos, geo.stoneSize * KTheme.hintScale * 0.98, KTheme.approxBoardColor);
            scale = 0.95;
          } else {
            scale = 0.5;
          }
          drawCircle(
            canvas,
            pos,
            KTheme.hintScale * geo.stoneSize * scale,
            withAlpha(colors[polOrder], KTheme.policyAlpha),
          );
          if (movePolicy > textLb) {
            final text = formatFixed(100 * movePolicy, 2);
            drawText(
              canvas,
              pos,
              '${text.substring(0, math.min(4, text.length))}%',
              fontSize: geo.gridSize / 4,
              color: KTheme.hintTextColor,
            );
          }
          if (movePolicy == bestMovePolicy) {
            drawArc(canvas, pos, geo.stoneSize - 1.2, withAlpha(KTheme.topMoveBorderColor, KTheme.policyAlpha), 2);
          }
        }
      }
    }
  }

  void drawStone(
    Canvas canvas,
    int x,
    int y,
    String player, {
    double alpha = 1,
    Color? innercol,
    Color? evalcol,
    double evalscale = 1.0,
    double scale = 1.0,
    double? ownership,
    double? loss,
    int? depth,
  }) {
    paintStone(
      canvas,
      images,
      geo,
      app,
      x,
      y,
      player,
      alpha: alpha,
      innercol: innercol,
      evalcol: evalcol,
      evalscale: evalscale,
      scale: scale,
      ownership: ownership,
      loss: loss,
      depth: depth,
    );
  }

  /// Blended territory: as a texture with one pixel per point (and a transparent border) stretched over the
  /// board with linear filtering. Drawn here as triangles with a colour at each point, which interpolates the same.
  void _drawTerritory(Canvas canvas, List<List<double>> grid, [Color? lossColor]) {
    if (KTheme.territoryDisplay == 'marks') {
      _drawTerritoryMarks(canvas, grid, lossColor);
      return;
    }
    final sizeY = grid.length;
    final sizeX = grid[0].length;
    Color pixel(int x, int y) {
      final xCoord = x - 1;
      final yCoord = y - 1;
      double alpha;
      if (xCoord < 0 || xCoord > sizeX - 1 || yCoord < 0 || yCoord > sizeY - 1) {
        alpha = 0; // the extra rows/columns outside the board
      } else {
        alpha = math.min(1, grid[yCoord][xCoord].abs());
        if (KTheme.territoryDisplay == 'blocks') alpha = alpha > KTheme.blocksThreshold ? 1 : 0;
      }
      alpha = math.pow(alpha, 1.0 / KTheme.ownershipGamma).toDouble();
      final cx = xCoord.clamp(0, sizeX - 1);
      final cy = yCoord.clamp(0, sizeY - 1);
      final owner = grid[cy][cx] > 0 ? 'B' : 'W';
      if (lossColor == null) {
        final c = KTheme.ownershipColors[owner]!;
        return c.withValues(alpha: c.a * alpha);
      }
      return lossColor.withValues(alpha: KTheme.hintsAlpha * alpha);
    }

    // texel centres: board point (x, y) sits on its grid position; the border texels one grid further out
    Offset at(int x, int y) {
      final xc = x - 1;
      final yc = y - 1;
      final inside = geo.pos(xc.clamp(0, sizeX - 1), yc.clamp(0, sizeY - 1));
      final (dx0, dy0) = geo.toDisplay(xc.clamp(0, sizeX - 1), yc.clamp(0, sizeY - 1));
      final (dx1, dy1) = geo.toDisplay(xc, yc);
      return inside + Offset((dx1 - dx0) * geo.gridSize, -(dy1 - dy0) * geo.gridSize);
    }

    final positions = <Offset>[];
    final colors = <Color>[];
    for (var y = 0; y < sizeY + 1; y++) {
      for (var x = 0; x < sizeX + 1; x++) {
        final quad = [(x, y), (x + 1, y), (x + 1, y + 1), (x, y + 1)];
        for (final tri in const [
          [0, 1, 2],
          [0, 2, 3],
        ]) {
          for (final k in tri) {
            final (qx, qy) = quad[k];
            positions.add(at(qx, qy));
            colors.add(pixel(qx, qy));
          }
        }
      }
    }
    // beyond the texel centres the texture keeps its edge colour, which is transparent: nothing to draw there
    canvas.drawVertices(ui.Vertices(ui.VertexMode.triangles, positions, colors: colors), BlendMode.dst, Paint());
  }

  void _drawTerritoryMarks(Canvas canvas, List<List<double>> grid, Color? lossColor) {
    for (var y = grid.length - 1; y >= 0; y--) {
      for (var x = 0; x < grid[y].length; x++) {
        final v = grid[y][x];
        if (v.abs() < 0.01) continue;
        final owner = v > 0 ? 'B' : 'W';
        final color = (lossColor ?? KTheme.stoneColors[owner]!).withValues(alpha: 1);
        final rectSize = KTheme.markSize * math.min(1.0, v.abs()) * geo.stoneSize * 2.0;
        canvas.drawRect(
          Rect.fromCenter(center: geo.pos(x, y), width: rectSize, height: rectSize),
          Paint()..color = color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(BoardContentsPainter old) => true;
}

/// The policy to show: the node's, or in AI self-play its parent's (one step out of date).
List<double>? boardPolicy(AppController app) {
  final cn = app.game!.currentNode;
  var policy = cn.policy;
  if ((policy == null || policy.isEmpty) &&
      cn.parent?.policy != null &&
      app.lastPlayerInfo.ai &&
      app.nextPlayerInfo.ai) {
    policy = cn.parent!.policy;
  }
  return (policy == null || policy.isEmpty) ? null : policy;
}

/// A stone: its texture, with ownership marks, an evaluation dot, the last move mark and the
/// move number.
void paintStone(
  Canvas canvas,
  BoardImages images,
  BoardGeometry geo,
  AppController app,
  int x,
  int y,
  String player, {
  double alpha = 1,
  Color? innercol,
  Color? evalcol,
  double evalscale = 1.0,
  double scale = 1.0,
  double? ownership,
  double? loss,
  int? depth,
}) {
  final stoneSize = geo.stoneSize * scale;
  final pos = geo.pos(x, y);
  String owner = 'B';
  String other = 'W';
  var a = alpha;
  if (ownership != null) {
    (owner, other) = ownership > 0 ? ('B', 'W') : ('W', 'B');
    if (KTheme.territoryDisplay != 'marks') {
      a = player == owner
          ? KTheme.stoneMinAlpha + (1.0 - KTheme.stoneMinAlpha) * ownership.abs()
          : KTheme.stoneMinAlpha;
    }
  }
  drawTexture(
    canvas,
    images.stone(player),
    Rect.fromCenter(center: pos, width: 2 * stoneSize, height: 2 * stoneSize),
    Color.fromRGBO(255, 255, 255, a),
  );
  // ownership marks on stones; the mark is a square with an outline
  if ((ownership != null || loss != null) &&
      (KTheme.stoneMarks == 'all' || (KTheme.stoneMarks == 'weak' && player != owner))) {
    final Color markColor;
    final Color outlineColor;
    if (ownership != null) {
      markColor = KTheme.stoneColors[owner]!.withValues(alpha: 1);
      final o = KTheme.stoneColors[other]!;
      outlineColor = Color.from(
        alpha: 1,
        red: (markColor.r + o.r) / 2,
        green: (markColor.g + o.g) / 2,
        blue: (markColor.b + o.b) / 2,
      );
    } else {
      markColor = KTheme.evalColors[trainerConfig(app)['theme']]![1].withValues(alpha: 1);
      outlineColor = markColor;
    }
    final markSize =
        KTheme.markSize *
        (ownership != null && ownership != 0 ? ownership.abs() : math.min(1.0, loss ?? 0)) *
        geo.stoneSize *
        2.0;
    final rect = Rect.fromCenter(center: pos, width: markSize, height: markSize);
    canvas.drawRect(rect, Paint()..color = markColor);
    canvas.drawRect(
      rect,
      Paint()
        ..color = outlineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }
  if (evalcol != null) {
    final evalRadius = math.sqrt(evalscale); // scale area by evalscale
    final evalsize =
        geo.stoneSize * (KTheme.evalDotMinSize + evalRadius * (KTheme.evalDotMaxSize - KTheme.evalDotMinSize));
    drawTexture(
      canvas,
      images[KTheme.evalDotTexture],
      Rect.fromCenter(center: pos, width: 2 * evalsize, height: 2 * evalsize),
      evalcol,
    );
  }
  if (innercol != null) {
    final innerSize = stoneSize * 0.8;
    drawTexture(
      canvas,
      images[KTheme.lastMoveTexture],
      Rect.fromCenter(center: pos, width: 2 * innerSize, height: 2 * innerSize),
      innercol,
    );
  }
  if (depth != null && depth != 0) {
    drawText(canvas, pos, '$depth', fontSize: geo.stoneSize * 0.9, color: KTheme.numberColor);
  }
}

/// A move with a variation that hovering shows: its point, the variation and the node it starts from.
typedef PvMove = ((int, int), List<String>, GameNode);

/// The top moves to show as hints.
List<Map<String, dynamic>> hintMoves(AppController app) {
  final game = app.game!;
  final cn = game.currentNode;
  if (app.analysisControls['hints']! && !app.analysisControls['policy']! && game.endResult == null) {
    return cn.candidateMoves;
  }
  if (app.statusState.$2 == statusTeaching) {
    // show score hint for teaching undo
    return [
      for (final m in cn.candidateMoves)
        for (final c in cn.children)
          if (c.move != null && c.autoUndo == true && c.move!.gtp() == m['move']) m,
    ];
  }
  return [];
}

/// The moves whose variations hovering shows: hints and the next moves.
List<PvMove> activePvMoves(AppController app) {
  final cn = app.game!.currentNode;
  final result = <PvMove>[];
  final lowVisits = (app.config('trainer/low_visits', 25) as num).toInt();
  final childMoves = {
    for (final c in cn.children)
      if (c.move != null) c.move!.gtp(),
  };
  for (final m in hintMoves(app)) {
    final move = Move.fromGtp(m['move'] as String);
    if (move.coords == null) continue;
    final engineBestMove = (m['order'] ?? 99) == 0;
    var scale = KTheme.hintScale;
    if ((m['visits'] as num) < lowVisits && !engineBestMove && !childMoves.contains(m['move'])) {
      scale = KTheme.uncertainHintScale;
    }
    if (scale <= 0) continue;
    if (m.containsKey('pv')) result.add((move.coords!, (m['pv'] as List).cast<String>(), cn));
  }
  if (app.analysisControls['show_children']!) {
    for (final child in cn.children) {
      final move = child.move;
      if (move != null && move.coords != null && child.analysisExists) {
        result.add((move.coords!, [move.gtp(), ...(child.candidateMoves[0]['pv'] as List).cast<String>()], cn));
      }
    }
  }
  return result;
}

String _formatLoss(Map<String, dynamic> tc, double x) {
  if (tc['extra_precision'] == true) {
    if (x.abs() < 0.005) return '0.0';
    if (0 < x && x <= 0.995) return '+${formatFixed(x, 2).substring(1)}';
    if (-0.995 <= x && x < 0) return '-${formatFixed(x, 2).substring(2)}';
  }
  return formatFixed(x, 1, plus: true);
}

/// Hints, next moves, the ghost stone, the principal variation, the region of interest and the pass circle.
class BoardHoverPainter extends CustomPainter {
  final AppController app;
  final BoardImages images;
  final BoardGeometry geo;

  /// Where the pass button is, for a pass in a variation (asked while painting, after layout).
  final Rect? Function()? passButton;
  BoardHoverPainter(this.app, this.images, this.geo, this.passButton, Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final game = app.game;
    if (game == null || !geo.valid) return;
    final tc = trainerConfig(app);
    final board = app.board;
    final gameEnded = game.endResult;
    final currentNode = game.currentNode;
    final nextPlayer = currentNode.nextPlayer;
    canvas.save();
    if (geo.viewClip != null) canvas.clipRect(geo.viewClip!);

    (int, int)? topMoveCoords;
    final childMoves = {
      for (final c in currentNode.children)
        if (c.move != null) c.move!.gtp(),
    };
    final hints = hintMoves(app);
    if (hints.isNotEmpty) {
      final lowVisitsThreshold = (app.config('trainer/low_visits', 25) as num).toInt();
      final topMovesShow = [
        for (final opt in [app.config('trainer/top_moves_show'), app.config('trainer/top_moves_show_secondary')])
          if (topMoveOptions.contains(opt) && opt != topMoveNothing) opt as String,
      ];
      for (final moveDict in hints) {
        final move = Move.fromGtp(moveDict['move'] as String);
        final c = move.coords;
        if (c == null) continue;
        final engineBestMove = (moveDict['order'] ?? 99) == 0;
        var scale = KTheme.hintScale;
        var textOn = true;
        var alpha = KTheme.hintsAlpha;
        if ((moveDict['visits'] as num) < lowVisitsThreshold &&
            !engineBestMove &&
            !childMoves.contains(moveDict['move'])) {
          scale = KTheme.uncertainHintScale;
          textOn = false;
          alpha = KTheme.hintsLoAlpha;
        }
        if (scale <= 0) continue; // if theme turns hints off, do not draw them
        final pos = geo.pos(c.$1, c.$2);
        final evalsize = geo.stoneSize * scale;
        final evalcol = evalColor(app, (moveDict['pointsLost'] as num).toDouble())!;
        if (textOn && topMovesShow.isNotEmpty) {
          // remove grid lines using a board colored circle
          drawCircle(canvas, pos, geo.stoneSize * scale * 0.98, KTheme.approxBoardColor);
        }
        drawTexture(
          canvas,
          images[KTheme.topMoveTexture],
          Rect.fromCenter(center: pos, width: 2 * evalsize, height: 2 * evalsize),
          withAlpha(evalcol, alpha),
        );
        if (textOn && topMovesShow.isNotEmpty) {
          final playerSign = GameNode.playerSign(nextPlayer);
          String value(String key) {
            switch (key) {
              case topMoveDeltaScore:
                return _formatLoss(tc, -(moveDict['pointsLost'] as num).toDouble());
              case topMoveScore:
                return formatFixed(playerSign * (moveDict['scoreLead'] as num).toDouble(), 1);
              case topMoveWinrate:
                final wr = (moveDict['winrate'] as num).toDouble();
                return formatFixed((playerSign == 1 ? wr : 1 - wr) * 100, 1);
              case topMoveDeltaWinrate:
                return formatPercent(-(moveDict['winrateLost'] as num).toDouble(), 1, plus: true);
              case topMoveVisits:
                return formatVisits((moveDict['visits'] as num).toInt());
            }
            return '';
          }

          _drawHintText(canvas, pos, [
            (value(topMovesShow[0]), (geo.gridSize / 3).roundToDouble()),
            if (topMovesShow.length > 1) (value(topMovesShow[1]), (geo.gridSize / 3.33).roundToDouble()),
          ]);
        }
        if (engineBestMove) {
          topMoveCoords = c;
          drawArc(canvas, pos, geo.stoneSize - 1.2, KTheme.topMoveBorderColor, 1.2);
        }
      }
    }

    // children of current moves in undo / review
    if (app.analysisControls['show_children']!) {
      for (final child in currentNode.children) {
        final move = child.move;
        final c = move?.coords;
        if (c == null) continue;
        final pos = geo.pos(c.$1, c.$2);
        final double dashedWidth;
        if (c != topMoveCoords) {
          // for contrast
          dashedWidth = 18;
          drawArc(canvas, pos, geo.stoneSize - 1.2, KTheme.nextMoveDashContrastColors[child.player]!, 1.2);
        } else {
          dashedWidth = 10;
        }
        for (var s = 0; s < 360; s += 30) {
          drawArc(
            canvas,
            pos,
            geo.stoneSize - 1.2,
            KTheme.stoneColors[child.player]!,
            1.2,
            s.toDouble(),
            s + dashedWidth,
          );
        }
      }
    }

    if (board.selectingRegionOfInterest && board.regionOfInterest.length == 4) {
      _drawRoiBox(canvas, board.regionOfInterest, 2);
    } else {
      // hover next move ghost stone
      final ghost = board.ghostStone;
      if (ghost != null) {
        paintStone(canvas, images, geo, app, ghost.$1, ghost.$2, nextPlayer, alpha: KTheme.ghostAlpha);
      }
      final animating = board.pv;
      if (animating != null) {
        final upTo = board.animatePvIndex(
          delay: ((app.config('general/anim_pv_time', 0.5) as num?) ?? 0.5).toDouble(),
          maxMoves: ((app.config('general/anim_pv_moves') as num?) ?? 100).toInt(),
        );
        _drawPv(canvas, animating.moves, animating.node, upTo);
      }
      final roi = game.regionOfInterest;
      if (roi != null && geo.zoom == null) _drawRoiBox(canvas, roi, 1.25);
    }

    // pass circle
    if (currentNode.isPass || gameEnded != null) {
      final text = gameEnded ?? i18n.tr('board-pass');
      final center = geo.zoom != null
          ? Offset((geo.columnsX.first + geo.columnsX.last) / 2, (geo.rowsY.first + geo.rowsY.last) / 2)
          : Offset(geo.columnsX[geo.displayX ~/ 2], geo.rowsY[geo.displayY ~/ 2]);
      final diameter = math.min(size.width, size.height) * 0.227;
      drawCircle(canvas, center, diameter / 2, KTheme.passCircleColor);
      drawText(
        canvas,
        center,
        text,
        fontSize: diameter * 0.25,
        color: KTheme.passCircleTextColor,
        font: null, // words, in the interface's font
        fallback: fontFallback(i18n.lang),
      );
    }
    _drawApiMarks(canvas, currentNode);
    canvas.restore();
  }

  /// Marks added through the API.
  void _drawApiMarks(Canvas canvas, GameNode currentNode) {
    final marks = visibleMarks(app.apiState.marks, currentNode);
    if (marks.isEmpty) return;
    final r = geo.stoneSize;
    const width = 2.0;
    Paint stroke(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    for (final mark in marks) {
      final rgb = mark.rgb;
      Color color(double alpha) => Color.from(alpha: alpha, red: rgb[0], green: rgb[1], blue: rgb[2]);
      final kind = mark.type;
      if (kind == 'area') {
        final [xmin, xmax, ymin, ymax] = mark.region!;
        final a = geo.pos(xmin, ymin), b = geo.pos(xmax, ymax);
        final rect = Rect.fromLTRB(
          math.min(a.dx, b.dx) - geo.gridSize / 2,
          math.min(a.dy, b.dy) - geo.gridSize / 2,
          math.max(a.dx, b.dx) + geo.gridSize / 2,
          math.max(a.dy, b.dy) + geo.gridSize / 2,
        );
        canvas.drawRect(rect, Paint()..color = color(0.18));
        canvas.drawRect(rect, stroke(color(0.9)));
        final text = mark.text;
        if (text != null && text.isNotEmpty) {
          drawText(
            canvas,
            Offset(rect.left + geo.gridSize / 2, rect.top - geo.gridSize / 3),
            text,
            fontSize: geo.gridSize / 2.2,
            color: color(1),
          );
        }
        continue;
      }
      final (x, y) = mark.point!;
      final c = geo.pos(x, y);
      switch (kind) {
        case 'circle':
          canvas.drawCircle(c, r * 0.62, stroke(color(1)));
        case 'square':
          canvas.drawRect(Rect.fromCenter(center: c, width: r * 1.1, height: r * 1.1), stroke(color(1)));
        case 'triangle':
          final s = r * 0.7;
          canvas.drawPath(
            Path()
              ..moveTo(c.dx, c.dy - s)
              ..lineTo(c.dx - s * 0.87, c.dy + s * 0.5)
              ..lineTo(c.dx + s * 0.87, c.dy + s * 0.5)
              ..close(),
            stroke(color(1)),
          );
        case 'cross':
          final s = r * 0.5;
          canvas.drawLine(c + Offset(-s, -s), c + Offset(s, s), stroke(color(1)));
          canvas.drawLine(c + Offset(-s, s), c + Offset(s, -s), stroke(color(1)));
        case 'dot':
          canvas.drawCircle(c, r * 0.9, Paint()..color = color(0.55));
        case 'label':
          canvas.drawCircle(c, r * 0.7, Paint()..color = color(0.9));
          final text = mark.text ?? '?';
          drawText(
            canvas,
            c,
            text.length > 3 ? text.substring(0, 3) : text,
            fontSize: geo.gridSize / 2.2,
            color: rgb[0] + rgb[1] + rgb[2] < 2.2 ? Colors.white : Colors.black,
          );
      }
    }
  }

  void _drawHintText(Canvas canvas, Offset pos, List<(String, double)> lines) {
    final painter = TextPainter(
      text: TextSpan(
        children: [
          for (var i = 0; i < lines.length; i++)
            TextSpan(
              text: i == 0 ? lines[i].$1 : '\n${lines[i].$1}',
              style: TextStyle(fontSize: lines[i].$2),
            ),
        ],
        style: TextStyle(
          fontFamily: KTheme.boardFont,
          fontWeight: FontWeight.bold,
          color: KTheme.hintTextColor,
          height: 0.85,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    painter.paint(canvas, pos - Offset(painter.width / 2, painter.height / 2));
  }

  void _drawRoiBox(Canvas canvas, List<int> region, double width) {
    final [x1, x2, y1, y2] = region;
    final start = geo.pos(x1, y1);
    final end = geo.pos(x2, y2);
    final rect = Rect.fromLTRB(
      math.min(start.dx, end.dx) - geo.gridSize / 3,
      math.min(start.dy, end.dy) - geo.gridSize / 3,
      math.max(start.dx, end.dx) + geo.gridSize / 3,
      math.max(start.dy, end.dy) + geo.gridSize / 3,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = KTheme.regionBorderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = width,
    );
  }

  void _drawPv(Canvas canvas, List<String> pv, GameNode node, double upToMove) {
    final nextLastPlayer = [node.nextPlayer, Move.opponentPlayer(node.nextPlayer)];
    final cn = app.game!.currentNode;
    if (!identical(node, cn) && !identical(node.parent, cn)) {
      GameNode? hideNode = cn;
      while (hideNode != null && hideNode.move != null && !identical(hideNode, node)) {
        final c = hideNode.move!.coords;
        if (c != null) drawCircle(canvas, geo.pos(c.$1, c.$2), geo.stoneSize, kc([0.85, 0.68, 0.40, 0.8]));
        hideNode = hideNode.parent;
      }
    }
    for (var i = 0; i < pv.length; i++) {
      if (i > upToMove) return;
      final movePlayer = nextLastPlayer[i % 2];
      final coords = Move.fromGtp(pv[i]).coords;
      final Offset at;
      double sizefac;
      if (coords == null) {
        // tee-hee
        final pass = passButton?.call();
        if (pass == null) continue;
        sizefac = pass.height / 2 / geo.stoneSize;
        at = Offset(pass.right + geo.stoneSize * sizefac, pass.center.dy);
      } else {
        at = geo.pos(coords.$1, coords.$2);
        sizefac = 1;
      }
      final stoneSize = geo.stoneSize * sizefac;
      drawTexture(
        canvas,
        images.stone(movePlayer),
        Rect.fromCenter(center: at, width: 2 * stoneSize + 1, height: 2 * stoneSize + 1),
      );
      drawText(
        canvas,
        at,
        '${i + 1}',
        fontSize: geo.gridSize * sizefac / 1.45,
        color: KTheme.pvTextColors[movePlayer]!,
      );
    }
  }

  @override
  bool shouldRepaint(BoardHoverPainter old) => true;
}
