// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/gui/badukpan.py: the state of
// BadukPanWidget that is not drawing (rotation, coordinates, the ghost stone, the animated principal variation and
// the region being selected).

import 'package:flutter/foundation.dart';
import 'package:katrain_core/api.dart' show PvOverlay;
import 'package:katrain_core/katrain_core.dart';

class BoardState extends ChangeNotifier {
  /// Clockwise, in steps of 90.
  int rotationDegree = 0;
  bool drawCoordsEnabled = true;

  (int, int)? ghostStone;
  bool selectingRegionOfInterest = false;

  /// The region being selected, `[x1, x2, y1, y2]`.
  List<int> regionOfInterest = [];
  PvOverlay? _pv;
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

  /// The variation drawn over the board: from hovering a hint or move, or shown through the API (pinned: hovering
  /// leaves it, a click clears it).
  PvOverlay? get pv => _pv;
  set pv(PvOverlay? value) {
    _pv = value;
    hoverChanges.value += 1;
  }

  bool get pvPinned => _pv?.pinned ?? false;

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

  /// Shows [moves] played from [node] while hovering, or stops showing one; [enabled] is the
  /// `general/anim_pv_moves` setting. Hovering the same variation again keeps its animation going.
  void setHoverPv(List<String>? moves, GameNode? node, {required bool enabled}) {
    if (!enabled || moves == null || node == null) {
      _pv = null;
    } else if (_pv == null || _pv!.pinned || !(listEquals(_pv!.moves, moves) && identical(_pv!.node, node))) {
      _pv = PvOverlay(moves, node, origin: lastMousePos);
    } else {
      _pv!.index = null;
    }
    notifyHover();
  }

  /// The last move of the variation to show: it grows by one every [delay] seconds, up to [maxMoves] moves, unless
  /// a step was chosen (scrolling, or the API).
  double animatePvIndex({required double delay, required int maxMoves}) {
    final pv = _pv;
    if (pv == null) return 0;
    if (pv.index != null) return pv.index!.toDouble();
    final elapsed = DateTime.now().difference(pv.started).inMicroseconds / 1e6;
    // drawn as an inclusive index, so one less to show max_moves moves
    return [
      pv.moves.length.toDouble(),
      (maxMoves - 1).toDouble(),
      elapsed / (delay < 0.1 ? 0.1 : delay),
    ].reduce((a, b) => a < b ? a : b);
  }

  void adjustAnimatePvIndex(int delta, {required double delay, required int maxMoves}) {
    final pv = _pv;
    if (pv == null) return;
    final current = animatePvIndex(delay: delay, maxMoves: maxMoves).floor();
    pv.index = current + delta < 0 ? 0 : current + delta;
    notifyHover();
  }

  @override
  void dispose() {
    boardChanges.dispose();
    hoverChanges.dispose();
    super.dispose();
  }
}
