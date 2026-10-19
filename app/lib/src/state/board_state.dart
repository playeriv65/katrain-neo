// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/gui/badukpan.py: the state of
// BadukPanWidget that is not drawing (rotation, coordinates, the ghost stone, the animated principal variation and
// the region being selected).

import 'package:flutter/foundation.dart';
import 'package:katrain_core/katrain_core.dart';

/// A principal variation being shown: its moves from [node], when it started and where the mouse was then.
class AnimatingPv {
  final List<String> pv;
  final GameNode node;
  final DateTime startTime;
  final (double, double) mousePos;
  AnimatingPv(this.pv, this.node, this.startTime, this.mousePos);
}

class BoardState extends ChangeNotifier {
  /// Clockwise, in steps of 90.
  int rotationDegree = 0;
  bool drawCoordsEnabled = true;

  (int, int)? ghostStone;
  bool selectingRegionOfInterest = false;

  /// The region being selected, `[x1, x2, y1, y2]`.
  List<int> regionOfInterest = [];
  AnimatingPv? _animatingPv;
  int? animatingPvIndex;

  /// A variation shown through the API: survives mouse hovers, cleared by clicks.
  bool pvPinned = false;
  (double, double) lastMousePos = (0, 0);

  /// `[xmin, xmax, ymin, ymax]` to show only part of the board, like a book diagram (from the playeriv65/katrain
  /// fork's zoomed tsumego view); drawn unrotated.
  List<int>? zoomRegion;

  /// Stones kept in the game but not drawn (e.g. a tsumego frame).
  Set<(int, int)> hiddenCoords = {};

  /// Changes when the board itself (size, rotation, coordinates, insert mode) must be drawn again.
  final ValueNotifier<int> boardChanges = ValueNotifier(0);

  /// Changes when the hover layer (ghost stone, variation, selection) must be drawn again.
  final ValueNotifier<int> hoverChanges = ValueNotifier(0);

  AnimatingPv? get animatingPv => _animatingPv;
  set animatingPv(AnimatingPv? value) {
    _animatingPv = value;
    hoverChanges.value += 1;
  }

  void notifyBoardChanged() => boardChanges.value += 1;

  /// Sets (or with null clears) the zoomed view and the stones to hide.
  void setZoom(List<int>? region, [Set<(int, int)> hidden = const {}]) {
    if (region != null && region.isNotEmpty) resetRotation();
    zoomRegion = region == null || region.isEmpty ? null : List.of(region);
    hiddenCoords = Set.of(hidden);
    notifyBoardChanged();
    notifyHover();
  }

  void notifyHover() => hoverChanges.value += 1;

  void resetRotation() {
    if (rotationDegree != 0) {
      rotationDegree = 0;
      notifyBoardChanged();
    }
  }

  void rotate() {
    rotationDegree = (rotationDegree + 90) % 360;
    notifyBoardChanged();
  }

  bool toggleCoordinates() {
    drawCoordsEnabled = !drawCoordsEnabled;
    notifyBoardChanged();
    return drawCoordsEnabled;
  }

  /// Shows [pv] played from [node], or stops showing one; [enabled] is the `general/anim_pv_moves` setting.
  void setAnimatingPv(List<String>? pv, GameNode? node, {required bool enabled}) {
    animatingPvIndex = null;
    pvPinned = false;
    if (!enabled || pv == null) {
      _animatingPv = null;
    } else if (node != null &&
        (_animatingPv == null || !(listEquals(_animatingPv!.pv, pv) && identical(_animatingPv!.node, node)))) {
      _animatingPv = AnimatingPv(pv, node, DateTime.now(), lastMousePos);
    }
    notifyHover();
  }

  /// The last move of the variation to show: it grows by one every [delay] seconds, up to [maxMoves] moves, unless
  /// the user scrolled through it.
  double animatePvIndex({required double delay, required int maxMoves}) {
    if (animatingPvIndex != null) return animatingPvIndex!.toDouble();
    final pv = _animatingPv;
    if (pv == null) return 0;
    final elapsed = DateTime.now().difference(pv.startTime).inMicroseconds / 1e6;
    // drawn as an inclusive index, so one less to show max_moves moves
    return [
      pv.pv.length.toDouble(),
      (maxMoves - 1).toDouble(),
      elapsed / (delay < 0.1 ? 0.1 : delay),
    ].reduce((a, b) => a < b ? a : b);
  }

  void adjustAnimatePvIndex(int delta, {required double delay, required int maxMoves}) {
    final current = animatePvIndex(delay: delay, maxMoves: maxMoves).floor();
    animatingPvIndex = current + delta < 0 ? 0 : current + delta;
    notifyHover();
  }

  @override
  void dispose() {
    boardChanges.dispose();
    hoverChanges.dispose();
    super.dispose();
  }
}
