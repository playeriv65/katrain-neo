// What the local API (katrain_core's api library, ported from the playeriv65/katrain fork) uses of the app: the
// game, the engine, the board display and the controls, by way of AppController.

import 'package:katrain_core/api.dart';
import 'package:katrain_core/katrain_core.dart';

import 'board_state.dart';
import 'app_controller.dart';

class AppApiHost implements ApiHost {
  final AppController app;
  AppApiHost(this.app);

  BoardState get _board => app.board;

  @override
  Game? get game => app.game;

  @override
  AnalysisEngine<GameNode>? get engine => app.engine;

  @override
  bool engineAlive(AnalysisEngine<GameNode> engine) => engine is! KataGoEngine || (engine.connection?.alive ?? false);

  @override
  bool engineIdle(AnalysisEngine<GameNode> engine) => engine is! KataGoEngine || engine.isIdle();

  @override
  int engineQueriesRemaining(AnalysisEngine<GameNode> engine) => engine is KataGoEngine ? engine.queriesRemaining() : 0;

  @override
  Map<String, Player> get playersInfo => app.playersInfo;

  @override
  Object? config(String setting, [Object? defaultValue]) => app.config(setting, defaultValue);

  @override
  void saveConfig([String? key]) => app.saveConfig(key);

  @override
  void updateState({bool redrawBoard = false}) => app.updateState(redrawBoard: redrawBoard);

  @override
  void redrawOverlay() => _board.notifyHover();

  @override
  void redrawMoveTree() => app.redrawMoveTree();

  @override
  bool get pondering => app.isPondering;

  @override
  void toggleContinuousAnalysis({bool quiet = false}) => app.toggleContinuousAnalysis(quiet: quiet);

  @override
  String get mode => app.mode;

  @override
  void selectMode(String mode) => app.selectMode(mode);

  @override
  String get statusMessage => app.statusText;

  @override
  void showStatus(String text) => app.setStatus(text, statusInfo, checkLevel: false);

  @override
  void newGame(GameNode moveTree, {bool analyzeFast = false, String? sgfFilename}) =>
      app.startGame(moveTree: moveTree, analyzeFast: analyzeFast, sgfFilename: sgfFilename);

  @override
  void tsumegoFrame(bool ko, int margin) => app.applyTsumegoFrame(ko, margin);

  @override
  PvOverlay? get pv => _board.pv;

  @override
  set pv(PvOverlay? value) => _board.pv = value;

  @override
  bool analysisControl(String key) => app.analysisControls[key] ?? false;

  @override
  void setAnalysisControl(String key, bool value) => app.setAnalysisControl(key, value);

  @override
  bool get showMoveNumbers => app.showMoveNum;

  @override
  set showMoveNumbers(bool value) => app.showMoveNum = value;

  @override
  List<int>? get zoomRegion => _board.zoomRegion;

  @override
  Set<(int, int)> get hiddenCoords => _board.hiddenCoords;

  @override
  void setZoom(List<int>? region, [Set<(int, int)> hidden = const {}]) => _board.setZoom(region, hidden);
}
