// The score graph: score, win rate and point loss lines with their scales, the dot at the current move, and pointing
// at a move to go there.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/app_controller.dart';
import '../state/graph_model.dart';
import 'app_theme.dart';

class ScoreGraph extends StatefulWidget {
  final AppController app;
  final bool showScore;
  final bool showWinrate;
  final bool showPointloss;
  const ScoreGraph({
    super.key,
    required this.app,
    required this.showScore,
    required this.showWinrate,
    required this.showPointloss,
  });

  @override
  State<ScoreGraph> createState() => _ScoreGraphState();
}

class _GraphData {
  final List<Offset> score;
  final List<Offset> winrate;
  final List<Offset> pointloss;
  final int scoreScale;
  final int winrateScale;
  final int pointlossScale;
  final Offset scoreDot;
  final Offset winrateDot;
  final Offset pointlossDot;
  _GraphData(
    this.score,
    this.winrate,
    this.pointloss,
    this.scoreScale,
    this.winrateScale,
    this.pointlossScale,
    this.scoreDot,
    this.winrateDot,
    this.pointlossDot,
  );
}

/// Room kept between the lines and the graph's edges, so the dot at the current move is whole even at an end.
const _plotInset = 5.0;

/// The lines and scales to draw, in widget coordinates (y down).
_GraphData _graphData(GraphModel model, Size size) {
  final nodes = model.nodes;
  final w = size.width - 2 * _plotInset;
  final h = size.height - 2 * _plotInset;
  final scoreValues = [for (final n in nodes) (n?.score != null && n!.score != 0) ? n.score! : double.nan];
  final scoreNn = [
    for (final n in nodes)
      if (n?.score != null && n!.score != 0) n.score!,
  ];
  final winrateValues = [
    for (final n in nodes) (n?.winrate != null && n!.winrate != 0) ? (n.winrate! - 0.5) * 100 : double.nan,
  ];
  final winrateNn = [
    for (final n in nodes)
      if (n?.winrate != null && n!.winrate != 0) (n.winrate! - 0.5) * 100,
  ];
  // point loss: both players' losses go upward from zero
  final pointlossValues = [
    for (final n in nodes)
      (n != null && n.move != null && n.pointsLost != null) ? math.max(0.0, n.pointsLost!) : double.nan,
  ];
  final pointlossNn = [
    for (final n in nodes)
      if (n != null && n.move != null && n.pointsLost != null) math.max(0.0, n.pointsLost!),
  ];
  double minOr0(List<double> v) => v.isEmpty ? 0 : v.reduce(math.min);
  double maxOr0(List<double> v) => v.isEmpty ? 0 : v.reduce(math.max);
  const scoreGranularity = 5;
  const winrateGranularity = 10;
  const pointlossGranularity = 5;
  final scoreScale =
      math.max((math.max(-minOr0(scoreNn), maxOr0(scoreNn)) / scoreGranularity).ceil(), 1) * scoreGranularity;
  final winrateScale =
      math.max((math.max(-minOr0(winrateNn), maxOr0(winrateNn)) / winrateGranularity).ceil(), 1) * winrateGranularity;
  final pointlossScale = math.max((maxOr0(pointlossNn) / pointlossGranularity).ceil(), 1) * pointlossGranularity;
  final xscale = w / math.max(scoreValues.length - 1, 15);
  double up(double y) => _plotInset + h - y;
  final score = [
    for (var i = 0; i < scoreValues.length; i++)
      Offset(_plotInset + i * xscale, up(h / 2 + h / 2 * (scoreValues[i] / scoreScale))),
  ];
  final winrate = [
    for (var i = 0; i < winrateValues.length; i++)
      Offset(_plotInset + i * xscale, up(h / 2 + h / 2 * (winrateValues[i] / winrateScale))),
  ];
  final pointloss = [
    for (var i = 0; i < pointlossValues.length; i++)
      Offset(_plotInset + i * xscale, up(h * (pointlossValues[i] / pointlossScale))),
  ];
  final hi = math.min(model.highlightedIndex, math.max(0, scoreValues.length - 1));
  Offset dot(List<Offset> line, double fallback) {
    if (line.isEmpty) return Offset.zero;
    final p = line[hi];
    return p.dy.isNaN ? Offset(p.dx, fallback) : p;
  }

  return _GraphData(
    score,
    winrate,
    pointloss,
    scoreScale,
    winrateScale,
    pointlossScale,
    dot(score, up(h / 2 + h / 2 * ((scoreNn.isEmpty ? 0 : scoreNn.last) / scoreScale))),
    dot(winrate, up(h / 2 + h / 2 * ((winrateNn.isEmpty ? 0 : winrateNn.last) / winrateScale))),
    dot(pointloss, up(h * ((pointlossNn.isEmpty ? 0 : pointlossNn.last) / pointlossScale))),
  );
}

class _ScoreGraphState extends State<ScoreGraph> {
  int? _navigateIndex;

  void _point(Offset p, Size size) {
    final data = _graphData(widget.app.graph, size);
    if (data.score.isEmpty) return;
    var best = 0;
    for (var i = 1; i < data.score.length; i++) {
      if ((data.score[i].dx - p.dx).abs() < (data.score[best].dx - p.dx).abs()) best = i;
    }
    setState(() => _navigateIndex = best);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final size = c.biggest;
        final data = _graphData(widget.app.graph, size);
        final markerSize = (0.1 * size.height).clamp(10.0, 13.0);
        final colors = EvalColors.of(context);
        final scheme = Theme.of(context).colorScheme;
        // the scale's labels sit on a backing, so the lines and the current move's dot do not run through them
        Widget marker((String, Color) label) => DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainer.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Text(
              label.$1,
              style: TextStyle(fontSize: markerSize, color: label.$2, height: 1.15),
            ),
          ),
        );
        // labels at the same place are stacked, away from the edges
        Widget corner(Alignment alignment, List<(String, Color)> labels) => Align(
          alignment: alignment,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: alignment.x < 0 ? CrossAxisAlignment.start : CrossAxisAlignment.end,
              spacing: 2,
              children: [for (final l in labels) marker(l)],
            ),
          ),
        );
        final winrate = widget.showWinrate, points = widget.showPointloss, score = widget.showScore;
        return GestureDetector(
          onPanDown: (d) => _point(d.localPosition, size),
          onPanUpdate: (d) => _point(d.localPosition, size),
          onPanEnd: (_) {
            final i = _navigateIndex;
            final nodes = widget.app.graph.nodes;
            if (i != null && i < nodes.length && nodes[i] != null) widget.app.setCurrentNode(nodes[i]!);
            setState(() => _navigateIndex = null);
          },
          onPanCancel: () => setState(() => _navigateIndex = null),
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _GraphPainter(
                    data,
                    widget.showScore,
                    widget.showWinrate,
                    widget.showPointloss,
                    _navigateIndex,
                    colors,
                    scheme.outlineVariant,
                    scheme.outline,
                    Theme.of(context).cardTheme.color ?? scheme.surfaceContainerLow,
                  ),
                ),
              ),
              if (score) ...[
                corner(Alignment.topRight, [('${i18n.tr('short color B')}+${data.scoreScale}', colors.score)]),
                corner(Alignment.centerRight, [(i18n.tr('Jigo'), colors.score)]),
                corner(Alignment.bottomRight, [('${i18n.tr('short color W')}+${data.scoreScale}', colors.score)]),
              ],
              if (winrate || points) ...[
                corner(Alignment.topLeft, [
                  if (winrate) ('${50 + data.winrateScale}%', colors.winrate),
                  if (points) ('-${data.pointlossScale}', colors.pointloss),
                ]),
                corner(Alignment.bottomLeft, [
                  if (points) ('0', colors.pointloss),
                  if (winrate) ('${50 - data.winrateScale}%', colors.winrate),
                ]),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _GraphPainter extends CustomPainter {
  final _GraphData data;
  final bool showScore;
  final bool showWinrate;
  final bool showPointloss;
  final int? navigateIndex;

  final EvalColors colors;

  /// The colour of the reference lines: even at half height, half the scale at a quarter and three quarters.
  final Color grid;

  /// The colour of the line at the move being pointed at.
  final Color pointer;

  /// The card's colour, ringing the dots at the current move.
  final Color ring;
  _GraphPainter(
    this.data,
    this.showScore,
    this.showWinrate,
    this.showPointloss,
    this.navigateIndex,
    this.colors,
    this.grid,
    this.pointer,
    this.ring,
  );

  void _dashed(Canvas canvas, double y, double width, {required double dash, required double gap}) {
    final paint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var x = 0.0; x < width; x += dash + gap) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + dash, width), y), paint);
    }
  }

  void _line(Canvas canvas, List<Offset> points, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.1
      ..style = PaintingStyle.stroke;
    final path = Path();
    var pen = false;
    for (final p in points) {
      if (p.dy.isNaN) {
        pen = false; // gaps where values are missing
        continue;
      }
      if (pen) {
        path.lineTo(p.dx, p.dy);
      } else {
        path.moveTo(p.dx, p.dy);
        pen = true;
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // the card behind is the background
    double at(double fraction) => _plotInset + (size.height - 2 * _plotInset) * fraction;
    _dashed(canvas, at(1 / 2), size.width, dash: 6, gap: 4);
    _dashed(canvas, at(1 / 4), size.width, dash: 2, gap: 3);
    _dashed(canvas, at(3 / 4), size.width, dash: 2, gap: 3);
    if (showScore) _line(canvas, data.score, colors.score);
    if (showWinrate) _line(canvas, data.winrate, colors.winrate);
    if (showPointloss) _line(canvas, data.pointloss, colors.pointloss);
    final nav = navigateIndex;
    if (nav != null && nav < data.score.length) {
      final x = data.score[nav].dx;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), Paint()..color = pointer);
    }
    // each line's dot in its own colour, ringed by the card's so it stands out where lines cross
    const radius = 3.5;
    final ringPaint = Paint()..color = ring;
    void dot(bool show, List<Offset> line, Offset fallback, Color color) {
      if (!show || line.isEmpty) return;
      final p = nav != null && nav < line.length ? line[nav] : fallback;
      if (p.dy.isNaN) return;
      canvas.drawCircle(p, radius + 1.5, ringPaint);
      canvas.drawCircle(p, radius, Paint()..color = color);
    }

    dot(showScore, data.score, data.scoreDot, colors.score);
    dot(showWinrate, data.winrate, data.winrateDot, colors.winrate);
    dot(showPointloss, data.pointloss, data.pointlossDot, colors.pointloss);
  }

  @override
  bool shouldRepaint(_GraphPainter old) => true;
}
