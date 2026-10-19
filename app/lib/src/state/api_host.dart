// What the local API (katrain_core's api library, ported from the playeriv65/katrain fork) uses of the app: the
// game, the engine, the board display and the controls, by way of KaTrainGui.

import 'package:katrain_core/api.dart';
import 'package:katrain_core/katrain_core.dart';

import 'board_state.dart';
import 'katrain_gui.dart';

/// The variation on the board as the API sees it; its step and pinning are the board's.
class _BoardPv extends ApiPv {
  final BoardState board;
  _BoardPv(this.board, AnimatingPv pv) : super(pv.pv, pv.node);

  @override
  int? get index => board.animatingPvIndex;
  @override
  set index(int? value) => board.animatingPvIndex = value;

  @override
  bool get pinned => board.pvPinned;
  @override
  set pinned(bool value) => board.pvPinned = value;
}

class GuiApiHost implements ApiHost {
  final KaTrainGui gui;
  GuiApiHost(this.gui);

  BoardState get _board => gui.board;

  @override
  Game? get game => gui.game;

  @override
  AnalysisEngine<GameNode>? get engine => gui.engine;

  @override
  bool engineAlive(AnalysisEngine<GameNode> engine) => engine is! KataGoEngine || (engine.connection?.alive ?? false);

  @override
  bool engineIdle(AnalysisEngine<GameNode> engine) => engine is! KataGoEngine || engine.isIdle();

  @override
  int engineQueriesRemaining(AnalysisEngine<GameNode> engine) => engine is KataGoEngine ? engine.queriesRemaining() : 0;

  @override
  Map<String, Player> get playersInfo => gui.playersInfo;

  @override
  Object? config(String setting, [Object? defaultValue]) => gui.config(setting, defaultValue);

  @override
  void saveConfig([String? key]) => gui.saveConfig(key);

  @override
  void updateState({bool redrawBoard = false}) => gui.updateState(redrawBoard: redrawBoard);

  @override
  void redrawOverlay() => _board.notifyHover();

  @override
  void redrawMoveTree() => gui.redrawMoveTree();

  @override
  bool get pondering => gui.isPondering;

  @override
  void toggleContinuousAnalysis({bool quiet = false}) => gui.toggleContinuousAnalysis(quiet: quiet);

  @override
  String get mode => gui.mode;

  @override
  void selectMode(String mode) => gui.selectMode(mode);

  @override
  String get statusMessage => gui.statusText;

  @override
  void showStatus(String text) => gui.setStatus(text, statusInfo, checkLevel: false);

  @override
  void newGame(GameNode moveTree, {bool analyzeFast = false, String? sgfFilename}) =>
      gui.doNewGame(moveTree: moveTree, analyzeFast: analyzeFast, sgfFilename: sgfFilename);

  @override
  void tsumegoFrame(bool ko, int margin) => gui.doTsumegoFrame(ko, margin);

  @override
  ApiPv? get pv {
    final p = _board.animatingPv;
    return p == null ? null : _BoardPv(_board, p);
  }

  @override
  set pv(ApiPv? value) {
    if (value == null) {
      _board.animatingPv = null;
      _board.pvPinned = false;
      return;
    }
    _board.animatingPv = AnimatingPv(value.moves, value.node, DateTime.now(), _board.lastMousePos);
    _board.animatingPvIndex = value.index;
    _board.pvPinned = value.pinned;
  }

  @override
  bool analysisControl(String key) => gui.analysisControls[key] ?? false;

  @override
  void setAnalysisControl(String key, bool value) => gui.setAnalysisControl(key, value);

  @override
  bool get showMoveNumbers => gui.showMoveNum;

  @override
  set showMoveNumbers(bool value) => gui.showMoveNum = value;

  @override
  List<int>? get zoomRegion => _board.zoomRegion;

  @override
  Set<(int, int)> get hiddenCoords => _board.hiddenCoords;

  @override
  void setZoom(List<int>? region, [Set<(int, int)> hidden = const {}]) => _board.setZoom(region, hidden);
}
