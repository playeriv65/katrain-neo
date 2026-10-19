// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/gui/badukpan.py: draw_board's layout
// (grid size, margins and the pixel positions of the lines, rounded as KaTrain rounds them) and rotation.
//
// KaTrain works in Kivy coordinates (y up) and rotates by permuting its table of grid positions. Here a board point
// is first rotated into display rows and columns, which gives the same picture.

import 'dart:math' as math;
import 'dart:ui';

import '../../theme.dart';

double _round4(double v) => (v * 10000).roundToDouble() / 10000;

class BoardGeometry {
  final double width;
  final double height;
  final int sizeX;
  final int sizeY;

  /// Clockwise, 0, 90, 180 or 270.
  final int rotation;
  final bool coordinates;

  /// Columns and rows as displayed (swapped by a quarter turn).
  late final int displayX = rotation % 180 == 0 ? sizeX : sizeY;
  late final int displayY = rotation % 180 == 0 ? sizeY : sizeX;
  late final List<double> marginX = coordinates ? const [1.5, 0.75] : const [0.75, 0.75]; // left, right
  late final List<double> marginY = coordinates ? const [1.5, 0.75] : const [0.75, 0.75]; // bottom, top
  late final double xGridSpaces = displayX - 1 + marginX[0] + marginX[1];
  late final double yGridSpaces = displayY - 1 + marginY[0] + marginY[1];

  /// Rounded to an integer to avoid rounding errors that produce tiny gaps between shaded grid squares.
  late final double gridSize = (math.min(width / xGridSpaces, height / yGridSpaces) + 0.1).floorToDouble();
  late final double stoneSize = gridSize * KTheme.stoneSize;
  late final double _extraX = _round4((width - xGridSpaces * gridSize) / 2);
  late final double _extraY = _round4((height - yGridSpaces * gridSize) / 2);

  /// Pixel positions of the displayed columns, left to right.
  late final List<double> columnsX = [
    for (var i = 0; i < displayX; i++) _round4(_extraX + ((marginX[0] + i) * gridSize + 0.5).floorToDouble()),
  ];

  /// Pixel positions of the displayed rows, bottom to top, measured up from the bottom (as Kivy does).
  late final List<double> _rowsUp = [
    for (var i = 0; i < displayY; i++) _round4(_extraY + ((marginY[0] + i) * gridSize + 0.5).floorToDouble()),
  ];

  /// Pixel positions of the displayed rows, bottom to top, in screen coordinates (y down).
  late final List<double> rowsY = [for (final y in _rowsUp) height - y];

  BoardGeometry({
    required this.width,
    required this.height,
    required this.sizeX,
    required this.sizeY,
    this.rotation = 0,
    this.coordinates = true,
  });

  bool get valid => gridSize > 0 && width > 0 && height > 0;

  /// The displayed column and row of board point (x, y), (0, 0) being the bottom left.
  (int, int) toDisplay(int x, int y) {
    var (dx, dy, w) = (x, y, sizeX);
    for (var r = 0; r < rotation; r += 90) {
      // a quarter turn clockwise: the bottom left corner goes to the top left
      (dx, dy) = (dy, w - 1 - dx);
      w = w == sizeX ? sizeY : sizeX;
    }
    return (dx, dy);
  }

  /// The board point shown at a displayed column and row.
  (int, int) fromDisplay(int dx, int dy) {
    for (var x = 0; x < sizeX; x++) {
      for (var y = 0; y < sizeY; y++) {
        if (toDisplay(x, y) == (dx, dy)) return (x, y);
      }
    }
    throw RangeError('($dx, $dy) is not on the board');
  }

  /// Screen position of board point (x, y).
  Offset pos(int x, int y) {
    final (dx, dy) = toDisplay(x, y);
    return Offset(columnsX[dx], rowsY[dy]);
  }

  /// The rectangle the board texture covers: the grid and its margins.
  Rect get boardRect => Rect.fromLTWH(
    columnsX[0] - gridSize * marginX[0],
    height - (_rowsUp[0] - gridSize * marginY[0]) - gridSize * yGridSpaces,
    gridSize * xGridSpaces,
    gridSize * yGridSpaces,
  );

  /// KaTrain's `_find_closest`: the nearest point and its distance from [p] along each axis.
  ({int x, int y, double dx, double dy}) closest(Offset p) {
    var bestCol = 0;
    var bestRow = 0;
    var xd = (columnsX[0] - p.dx).abs();
    var yd = (rowsY[0] - p.dy).abs();
    for (var r = 0; r < displayY; r++) {
      for (var c = 0; c < displayX; c++) {
        final cx = (columnsX[c] - p.dx).abs();
        final cy = (rowsY[r] - p.dy).abs();
        if (cx <= xd && cy <= yd) {
          xd = cx;
          yd = cy;
          bestCol = c;
          bestRow = r;
        }
      }
    }
    final (x, y) = fromDisplay(bestCol, bestRow);
    return (x: x, y: y, dx: xd, dy: yd);
  }

  /// Coordinate labels: the text under displayed column [i] and beside displayed row [i] (badukpan.py).
  String xLabel(int i, List<String> gtpCoord) => switch (rotation) {
    90 => '${i + 1}',
    180 => gtpCoord[displayX - i - 1],
    270 => '${displayX - i}',
    _ => gtpCoord[i],
  };

  String yLabel(int i, List<String> gtpCoord) => switch (rotation) {
    90 => gtpCoord[displayY - i - 1],
    180 => '${displayY - i}',
    270 => gtpCoord[i],
    _ => '${i + 1}',
  };
}
