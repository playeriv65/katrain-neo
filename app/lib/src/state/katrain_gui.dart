// Ported from KaTrain (https://github.com/sanderland/katrain, MIT): katrain/__main__.py (KaTrainGui: the message
// loop, update_state with AI moves, teaching undo and pondering, game actions and loading/saving), and the state
// kept by its widgets: katrain/gui/controlspanel.py (status line, evaluation, timer, the saved state of each mode),
// katrain/gui/widgets/graph.py (the nodes of the score graph) and katrain/gui/badukpan.py (rotation, coordinates).
//
// KaTrain runs game actions on a thread that takes messages from a queue, so they happen in order and slow ones
// (AI moves wait for analysis) do not block the GUI. Here the queue is a chain of futures; an action posted for a
// game that has been replaced since is skipped, as in KaTrain.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';

import 'board_state.dart';
import 'sounds.dart';

/// A collapsable panel of the right column: open or closed, and which of its tabs are on.
class PanelState {
  String state;
  final Map<String, bool> options;
  PanelState(this.state, this.options);

  bool get open => state == 'open';

  List<Object> toJson() => [state, Map.of(options)];
}

/// The nodes the score graph shows: the current line, kept as the user navigates (graph.py `Graph`).
class GraphModel {
  List<GameNode?> nodes = [];
  int highlightedIndex = 0;

  void initializeFromGame(GameNode root) {
    nodes = [root];
    var node = root;
    while (node.children.isNotEmpty) {
      node = node.orderedChildren[0];
      nodes.add(node);
    }
    highlightedIndex = 0;
  }

  void updateValue(GameNode node) {
    final index = highlightedIndex = node.depth;
    while (nodes.length - 1 < index) {
      nodes.add(null);
    }
    nodes[index] = node;
    if (index > 1 && node.parent != null) {
      // sometimes there are gaps
      var backfill = index - 1;
      GameNode? bfnode = node.parent;
      while (bfnode != null && !identical(nodes[backfill], bfnode)) {
        nodes[backfill] = bfnode;
        backfill -= 1;
        bfnode = bfnode.parent;
      }
    }
    if (index + 1 < nodes.length && (node.children.isEmpty || !identical(nodes[index + 1], node.orderedChildren[0]))) {
      nodes = nodes.sublist(0, index + 1); // on branch switching, don't show history from other branch
    }
    if (index == nodes.length - 1) {
      // possibly just switched branch or the line above triggered
      var n = node;
      while (n.children.isNotEmpty) {
        n = n.orderedChildren[0];
        nodes.add(n);
      }
    }
  }
}

/// The clock: [mainTimeRemaining] while there is main time, else the byo-yomi period and the periods left.
class TimerState {
  bool paused = true;
  double timeRemaining = 30;
  int? periodsRemaining;
  bool ai = false;

  bool get timeout => periodsRemaining != null && periodsRemaining! <= 0;
}

/// What the program shows and does around the game: KaTrain's KaTrainGui and the state of its widgets.
class KaTrainGui extends KaTrainBase with ChangeNotifier {
  /// Folder with KaTrain's resources, for `katrain/...` paths in the engine settings.
  final String resourceDir;
  final Sounds sounds;

  KataGoEngine? engine;
  Object? _engineIo;
  late final _EngineHost _engineHost = _EngineHost(this);

  /// What the engine reports to; for an engine made outside, e.g. in tests.
  EngineHost get engineHost => _engineHost;

  bool _pondering = false;
  bool get isPondering => _pondering;
  @override
  set pondering(bool value) => _pondering = value;

  late bool showMoveNum = (config('trainer/show_move_numbers') ?? false) as bool;

  /// 0: everything shown, 1: no control bars, 2: board only (KaTrain's zen mode).
  int zen = 0;
  String mode = modePlay;
  bool navDrawerOpen = false;

  /// Set by the app while a popup is shown; KaTrain does not move for the AI then.
  bool popupOpen = false;

  /// Opens a popup by its KaTrain message name (e.g. `new-game-popup`); set by the app.
  void Function(String name, List<Object?> args)? presentPopup;

  /// Opens or closes the menu; set by the app.
  VoidCallback? toggleNavDrawer;

  final Map<String, bool> analysisControls = {
    'show_children': true,
    'eval': false,
    'hints': false,
    'policy': false,
    'ownership': false,
  };
  final Map<String, PanelState> panels = {
    'graph_panel': PanelState('open', {'score': true, 'winrate': false, 'points': false}),
    'stats_panel': PanelState('open', {'score': true, 'winrate': true, 'points': true}),
    'notes_panel': PanelState('open', {'info': true, 'info-details': false, 'notes': false}),
  };

  // status line: (message, type, node it was set at)
  (String?, num, GameNode?) statusState = (null, -1e9, null);
  String statusText = '';
  bool statusIsError = false;

  // evaluation shown in the panels
  GameNode? activeCommentNode;
  String infoText = '';
  String noteText = '';
  String statsScore = '';
  String statsWinrate = '';
  double? statsPointsLost;
  String statsPlayer = '';

  final GraphModel graph = GraphModel();
  final TimerState timer = TimerState();
  final BoardState board = BoardState();
  GameNode? moveTreeSelectedNode;

  Future<void> _queue = Future.value();
  Timer? _clock;
  ({GameNode? node, DateTime time, bool beeping}) _lastTimerUpdate = (node: null, time: DateTime.now(), beeping: false);
  static const _beepStart = 5.2;
  static const _timerInterval = 0.07;

  KaTrainGui(super.configStore, {required this.resourceDir, Sounds? sounds, super.debugLevel})
    : sounds = sounds ?? const Sounds.silent();

  String get playAnalyzeMode => mode;

  @override
  void log(String message, [num level = outputInfo]) {
    super.log(message, level);
    if (level == outputKatagoStderr && !statusText.contains('ERROR')) {
      final lower = message.toLowerCase();
      if (lower.contains('starting')) {
        setStatus('KataGo engine starting...', statusInfo);
      } else if (message.startsWith('Tuning')) {
        setStatus('KataGo is tuning settings for first startup, please wait.$message', statusInfo);
        return;
      } else if (lower.contains('ready')) {
        setStatus('KataGo engine ready.', statusInfo);
      }
    }
    if (level == outputError ||
        (level == outputKatagoStderr &&
            message.toLowerCase().contains('error') &&
            !message.toLowerCase().contains('tuning'))) {
      setStatus('ERROR: $message', statusError);
    }
  }

  // -- startup

  /// Starts the engine and a new game, or loads [sgfFile] (KaTrain loads an SGF given on the command line). Tests
  /// pass an [engineWithoutIo] instead of running KataGo.
  Future<void> start({String? sgfFile, KataGoEngine? engineWithoutIo}) async {
    if (engine != null) return;
    if (engineWithoutIo != null) {
      engine = engineWithoutIo;
    } else {
      final (newEngine, io) = await makeEngine(_engineHost, _engineConfig, resourceDir: resourceDir);
      engine = newEngine;
      _engineIo = io;
    }
    if (sgfFile != null) {
      loadSgfFile(sgfFile, fast: true, rewind: true);
    } else {
      doNewGame();
    }
    loadUiState();
    _clock = Timer.periodic(Duration(milliseconds: (_timerInterval * 1000).round()), (_) => updateTimer());
  }

  Map<String, dynamic> get _engineConfig => (config('engine') as Map).cast<String, dynamic>();

  /// Shuts the engine down (on closing the window).
  Future<void> shutdown() async {
    _clock?.cancel();
    _clock = null;
    await _stopEngine();
  }

  Future<void> _stopEngine() async {
    final io = _engineIo;
    if (io is LocalKataGo) await io.shutdown(finish: false);
    if (io is RemoteKataGo) await io.shutdown();
  }

  /// Rebuilds the analysis engine from the current settings and analyses again (settings saved, or Retry).
  Future<void> restartEngine() async {
    log('Restarting engine', outputInfo);
    setStatus(i18n.tr('restarting engine'), statusInfo);
    await _stopEngine();
    final (newEngine, io) = await makeEngine(_engineHost, _engineConfig, resourceDir: resourceDir);
    engine = newEngine;
    _engineIo = io;
    game!.engines
      ..['B'] = newEngine
      ..['W'] = newEngine;
    game!.analyzeAllNodes(analyzeFast: true); // old engine was possibly broken, so redo any failures
    updateState();
    _clock ??= Timer.periodic(Duration(milliseconds: (_timerInterval * 1000).round()), (_) => updateTimer());
  }

  // -- messages

  /// KaTrain's `katrain(message, *args)`: popups open right away, game actions go through the queue in order.
  void act(String message, [List<Object?> args = const [], Map<String, Object?> kwargs = const {}]) {
    final g = game;
    if (g == null) return;
    if (message.endsWith('popup')) {
      timer.paused = message != 'engine-recovery-popup' ? true : timer.paused;
      presentPopup?.call(message, args);
      return;
    }
    final gameId = g.gameId;
    final gameAtPost = g;
    _queue = _queue.then((_) async {
      log('Message Loop Received $message: $args for Game $gameId', outputExtraDebug);
      if (!identical(game, gameAtPost)) {
        log('Message skipped as it is outdated (current game is ${game?.gameId}', outputExtraDebug);
        return;
      }
      try {
        await _do(message.replaceAll('-', '_'), args, kwargs);
        if (message != 'update-state') await _doUpdateState();
      } catch (e, st) {
        log('Exception in processing message $message $args: $e', outputError);
        debugPrintStack(stackTrace: st);
      }
    });
  }

  Future<void> _do(String msg, List<Object?> args, Map<String, Object?> kwargs) async {
    Object? arg(int i) => i < args.length ? args[i] : null;
    switch (msg) {
      case 'update_state':
        await _doUpdateState(redrawBoard: (kwargs['redraw_board'] ?? false) as bool);
      case 'new_game':
        doNewGame(moveTree: arg(0) as GameNode?, analyzeFast: (kwargs['analyze_fast'] ?? false) as bool);
      case 'insert_mode':
        _doInsertMode(arg(0) ?? 'toggle');
      case 'ai_move':
        await _doAiMove(arg(0) as GameNode?);
      case 'undo':
        _doUndo(arg(0) ?? 1);
      case 'reset_analysis':
        game!.resetCurrentAnalysis();
      case 'resign':
        game!.currentNode.endState = '${game!.currentNode.player}+R';
      case 'redo':
        board.animatingPv = null;
        game!.redo((arg(0) ?? 1) as int);
      case 'rotate':
        board.rotate();
      case 'find_mistake':
        board.animatingPv = null;
        final threshold = _evalThresholds[_evalThresholds.length - 4].toDouble();
        if ((arg(0) ?? 'redo') == 'undo') {
          game!.undo(9999, threshold);
        } else {
          game!.redo(9999, threshold);
        }
      case 'switch_branch':
        board.animatingPv = null;
        switchBranch(arg(0) as int);
      case 'play':
        _doPlay(arg(0) as (int, int)?);
      case 'analyze_extra':
        game!.analyzeExtra(
          arg(0) as String,
          mistakesOnly: (kwargs['mistakes_only'] ?? false) as bool,
          moveRange: kwargs['move_range'] as List<int>?,
          visits: kwargs['visits'] as int?,
        );
      case 'selfplay_setup':
        final until = arg(0);
        game!.selfplay(until is double ? until.toInt() : until!, targetBAdvantage: (arg(1) as num?)?.toDouble());
      case 'select_box':
        setStatus(i18n.tr('analysis:region:start'), statusInfo);
        board.selectingRegionOfInterest = true;
      case 'save_game':
        await _doSaveGame(arg(0) as String?);
      case 'tsumego_frame':
        _doTsumegoFrame(arg(0) as bool, arg(1) as int);
      default:
        throw ArgumentError('unknown message $msg');
    }
  }

  List<num> get _evalThresholds => (config('trainer/eval_thresholds') as List).cast<num>();

  @override
  void updateState({bool redrawBoard = false}) => act('update-state', const [], {'redraw_board': redrawBoard});

  /// Called after every message and on receiving analyses and config changes: AI and teaching moves, pondering.
  Future<void> _doUpdateState({bool redrawBoard = false}) async {
    final g = game;
    if (g == null) return;
    final cn = g.currentNode;
    final lastPlayer = playersInfo[cn.player]!;
    final nextPlayer = playersInfo[cn.nextPlayer]!;
    if (mode == modePlay && !navDrawerOpen && !popupOpen) {
      final pointsLost = cn.pointsLost;
      if (lastPlayer.human &&
          cn.analysisComplete &&
          pointsLost != null &&
          pointsLost > _evalThresholds[_evalThresholds.length - 4]) {
        playMistakeSound(cn);
      }
      final teachingUndo = lastPlayer.beingTaught && cn.parent != null;
      if (teachingUndo &&
          cn.analysisComplete &&
          cn.parent!.analysisComplete &&
          cn.children.isEmpty &&
          g.endResult == null) {
        g.analyzeUndo(cn); // not via message loop
      }
      if (cn.analysisComplete &&
          nextPlayer.ai &&
          cn.children.isEmpty &&
          g.endResult == null &&
          !(teachingUndo && cn.autoUndo == null)) {
        // cn mismatch stops this if undo fired. avoid message loop here or fires repeatedly.
        await _doAiMove(cn);
        Timer(const Duration(milliseconds: 250), _playStoneSound);
      }
    }
    if (engine != null) {
      if (_pondering) {
        g.analyzeExtra('ponder');
      } else {
        engine!.stopPondering();
      }
    }
    _updateGui(cn, redrawBoard: redrawBoard);
  }

  void _updateGui(GameNode cn, {bool redrawBoard = false}) {
    if (redrawBoard) board.notifyBoardChanged();
    updateEvaluation();
    updateTimer();
    notifyListeners();
  }

  @override
  void updatePlayer(String bw, {String playerType = playerHuman, String playerSubtype = playingNormal}) {
    super.updatePlayer(bw, playerType: playerType, playerSubtype: playerSubtype);
    final g = game;
    if (g != null) {
      final sgfName = g.root.getProperty('P$bw');
      playersInfo[bw]!.name = (sgfName == null || sgfName.contains(sgfInternalCommentsMarker)) ? '' : sgfName;
      updateState();
    }
  }

  void setNote(String note) {
    game!.currentNode.note = note;
    noteText = note;
  }

  void toggleContinuousAnalysis({bool quiet = false}) {
    if (_pondering) {
      setStatus('', statusInfo);
    } else if (!quiet) {
      analysisControls['hints'] = true;
    }
    _pondering = !_pondering;
    updateState();
  }

  void toggleMoveNum() {
    showMoveNum = !showMoveNum;
    updateState();
  }

  // -- game actions

  void doNewGame({GameNode? moveTree, bool analyzeFast = false, String? sgfFilename}) {
    _pondering = false;
    if ((moveTree != null && mode == modePlay) || (moveTree == null && mode == modeAnalyze)) {
      switchUiMode(); // for new game, go to play, for loaded, analyze
    }
    board.animatingPv = null;
    board.resetRotation();
    engine!.onNewGame(); // clear queries
    game = Game(
      this,
      engine!,
      moveTree: moveTree,
      analyzeFast: analyzeFast || moveTree == null,
      sgfFilename: sgfFilename,
    );
    for (final MapEntry(key: bw, value: info) in playersInfo.entries) {
      info.sgfRank = game!.root.getProperty('${bw}R');
      info.calculatedRank = null;
      if (sgfFilename != null) {
        // load game->no ai player
        info.playerType = playerHuman;
        info.playerSubtype = playingNormal;
      }
      updatePlayer(bw, playerType: info.playerType, playerSubtype: info.playerSubtype);
    }
    graph.initializeFromGame(game!.root);
    updateState(redrawBoard: true);
  }

  /// A new game from the new game popup, or a loaded one.
  void newGame({GameNode? moveTree, bool analyzeFast = false}) =>
      act('new-game', [moveTree], {'analyze_fast': analyzeFast});

  void _doInsertMode(Object insertMode) {
    game!.setInsertMode(insertMode);
    if (mode != modeAnalyze) switchUiMode();
  }

  Future<void> _doAiMove([GameNode? node]) async {
    if (node == null || identical(game!.currentNode, node)) {
      final strategy = nextPlayerInfo.strategy;
      final settings = config('ai/$strategy');
      if (settings != null) {
        await generateAiMove(game!, strategy, (settings as Map).cast<String, dynamic>());
      } else {
        log('AI Mode $strategy not found!', outputError);
      }
    }
  }

  void _doUndo(Object nTimes) {
    var n = nTimes;
    if (n == 'smart') {
      n = 1;
      if (mode == modePlay && lastPlayerInfo.ai && nextPlayerInfo.human) n = 2;
    }
    board.animatingPv = null;
    game!.undo(n);
  }

  void _playStoneSound() => sounds.play(KThemeSounds.randomStone());

  void _doPlay((int, int)? coords) {
    board.animatingPv = null;
    final g = game!;
    try {
      final oldPrisonerCount = g.prisonerCount['W']! + g.prisonerCount['B']!;
      g.play(Move(coords: coords, player: nextPlayerInfo.player));
      if (oldPrisonerCount < g.prisonerCount['W']! + g.prisonerCount['B']!) {
        sounds.play(KThemeSounds.capturing);
      } else if (!g.currentNode.isPass) {
        _playStoneSound();
      }
    } on IllegalMoveException catch (e) {
      setStatus('Illegal Move: $e', statusError);
    }
  }

  void _doTsumegoFrame(bool ko, int margin) {
    final g = game!;
    if (g.stones.isEmpty) return;
    final blackToPlayP = nextPlayerInfo.player == 'B';
    final (node, analysisRegion) = tsumegoFrameFromKatrainGame(g, g.komi, blackToPlayP, ko, margin);
    g.setCurrentNode(node);
    if (mode == modePlay) switchUiMode(); // go to analysis mode
    if (analysisRegion != null) {
      g.setRegionOfInterest([analysisRegion.$1.$2, analysisRegion.$1.$1, analysisRegion.$2.$2, analysisRegion.$2.$1]);
    }
    node.analyze(g.engines[node.nextPlayer]!);
    updateState(redrawBoard: true);
  }

  void playMistakeSound(GameNode node) {
    if ((config('timer/sound') ?? false) == true &&
        node.playedMistakeSound == null &&
        sounds.mistakeSounds.isNotEmpty) {
      node.playedMistakeSound = true;
      sounds.play(sounds.mistakeSounds[math.Random().nextInt(sounds.mistakeSounds.length)]);
    }
  }

  /// Reads an SGF, NGF or GIB file and starts reviewing it; KaTrain logs files it cannot read.
  void loadSgfFile(String file, {bool fast = false, bool rewind = true}) {
    final GameNode moveTree;
    try {
      moveTree = gameParser.parseBytes(File(file).readAsBytesSync(), fileName: file);
    } on Object catch (e) {
      log(pyFormat(i18n.tr('Failed to load SGF'), {'error': e}), outputError);
      return;
    }
    doNewGame(moveTree: moveTree, analyzeFast: fast, sgfFilename: File(file).absolute.path);
    if (!rewind) game!.redo(999);
  }

  /// Reads a game from text, e.g. pasted from the clipboard; false when it is not a game record.
  bool loadSgfText(String text) {
    final GameNode moveTree;
    try {
      moveTree = gameParser.parseSgf(text);
    } on Object catch (e) {
      setStatus(
        pyFormat(i18n.tr('Failed to import from clipboard'), {
          'error': e,
          'contents': text.substring(0, math.min(50, text.length)),
        }),
        statusInfo,
      );
      return false;
    }
    moveTree.nodesInTree.last.analyze(engine!); // speed up result for looking at end of game
    doNewGame(moveTree: moveTree, analyzeFast: true);
    act('redo', [9999]);
    log('Imported game from clipboard.', outputInfo);
    return true;
  }

  Future<void> _doSaveGame(String? filename) async {
    final file = filename ?? game!.sgfFilename;
    if (file == null) {
      act('save-game-as-popup');
      return;
    }
    try {
      final msg = writeSgf(game!, file);
      log(msg, outputInfo);
      setStatus(msg, statusInfo, checkLevel: false);
    } on Object catch (e) {
      log('Failed to save SGF to $file: $e', outputError);
    }
  }

  // -- modes and saved ui state (controlspanel.py PlayAnalyzeSelect)

  void saveUiState() {
    final uiState = (config('ui_state') as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    uiState[mode] = {
      'analysis_controls': Map.of(analysisControls),
      'panels': {for (final e in panels.entries) e.key: e.value.toJson()},
    };
    configStore.data['ui_state'] = uiState;
    saveConfig('ui_state');
  }

  void loadUiState() {
    final state = (config('ui_state/$mode', <String, dynamic>{}) as Map).cast<String, dynamic>();
    for (final MapEntry(:key, :value) in ((state['analysis_controls'] ?? {}) as Map).cast<String, dynamic>().entries) {
      if (analysisControls.containsKey(key)) analysisControls[key] = value == true;
    }
    for (final MapEntry(:key, :value) in ((state['panels'] ?? {}) as Map).cast<String, dynamic>().entries) {
      final panel = panels[key];
      if (panel == null) continue;
      final [panelState, buttonState] = value as List;
      for (final e in (buttonState as Map).cast<String, dynamic>().entries) {
        if (panel.options.containsKey(e.key)) panel.options[e.key] = e.value == true;
      }
      panel.state = panelState as String;
    }
    notifyListeners();
  }

  void selectMode(String newMode) {
    if (mode == newMode) return;
    saveUiState();
    mode = newMode;
    loadUiState();
    updateState(); // for lock ai even if nothing changed
  }

  void switchUiMode() => selectMode(mode == modePlay ? modeAnalyze : modePlay);

  void setAnalysisControl(String key, bool value) {
    analysisControls[key] = value;
    updateState();
  }

  void setPanelState(String key, {String? state, Map<String, bool>? options}) {
    final panel = panels[key]!;
    if (state != null) panel.state = state;
    if (options != null) panel.options.addAll(options);
    if (key == 'notes_panel') updateState();
    notifyListeners();
  }

  // -- status line and evaluation (controlspanel.py ControlsPanel)

  @override
  void setStatus(String message, num statusType, {GameNode? atNode, bool checkLevel = true}) {
    final node = atNode ?? game?.currentNode;
    if (!identical(node, statusState.$3) ||
        !checkLevel ||
        statusType.toInt() >= statusState.$2.toInt() ||
        message.isEmpty) {
      final changed = statusState != (message, statusType, node);
      statusState = (message, statusType, node);
      statusText = message;
      statusIsError = statusType == statusError;
      if (changed) {
        scheduleMicrotask(() {
          updateEvaluation();
          notifyListeners();
        });
      }
    }
  }

  /// Shows the completed analysis and comments of the node, and the score graph.
  void updateEvaluation() {
    final g = game;
    if (g == null) return;
    final currentNode = g.currentNode;
    final move = currentNode.move;
    if ((!identical(currentNode, statusState.$3) && !(statusState.$2 == statusError && statusState.$3 == null)) ||
        ((engine?.isIdle() ?? false) && statusState.$2 == statusAnalysis)) {
      // clear status if node changes, except startup errors on root. also clear analysis message when no queries
      statusText = '';
      statusState = (null, -1e9, null);
    }
    final lastPlayerWasAiPlayingHuman = lastPlayerInfo.ai && nextPlayerInfo.human;
    final bothPlayersAreRobots = lastPlayerInfo.ai && nextPlayerInfo.ai;
    var commentNode = currentNode;
    if (mode == modePlay && lastPlayerWasAiPlayingHuman) {
      if (nextPlayerInfo.beingTaught && currentNode.children.isNotEmpty && currentNode.children.last.autoUndo == true) {
        commentNode = currentNode.children.last;
      } else if (currentNode.parent != null) {
        commentNode = currentNode.parent!;
      }
    } else if (bothPlayersAreRobots && !currentNode.analysisExists && currentNode.parent != null) {
      commentNode = currentNode.parent!;
    }
    activeCommentNode = commentNode;
    final lockAi = (config('trainer/lock_ai') ?? false) == true && mode == modePlay;
    final details = panels['notes_panel']!.options['info-details']! && !lockAi;
    var info = '';
    if (move != null || currentNode.isRoot) {
      info += commentNode.comment(teach: playersInfo[commentNode.player]!.beingTaught, details: details);
    }
    if (commentNode.analysisExists) {
      statsScore = commentNode.formatScore() ?? '';
      statsWinrate = commentNode.formatWinrate() ?? '';
      statsPointsLost = commentNode.pointsLost;
      statsPlayer = commentNode.player;
    } else {
      statsScore = '';
      statsWinrate = '';
      statsPointsLost = null;
      statsPlayer = '';
    }
    graph.updateValue(currentNode);
    noteText = currentNode.note;
    infoText = info;
  }

  // -- timer (controlspanel.py update_timer)

  void updateTimer() {
    final g = game;
    if (g == null) return;
    final currentNode = g.currentNode;
    final (:node, :time, :beeping) = _lastTimerUpdate;
    var newBeeping = beeping;
    final now = DateTime.now();
    final mainTime = ((config('timer/main_time', 0) as num) * 60).toDouble();
    final byoLen = math.max(1, (config('timer/byo_length') as num).toDouble());
    final byoNum = math.max(1, (config('timer/byo_periods') as num).toInt());
    final soundsOn = (config('timer/sound') ?? false) == true;
    final player = nextPlayerInfo;
    final ai = player.ai;
    var usedPeriod = false;
    final minUse = (config('timer/minimal_use', 0) as num).toDouble();
    final boingAtRemaining = byoLen - minUse;
    final mainTimeRemaining = mainTime - g.mainTimeUsed;
    final elapsed = now.difference(time).inMicroseconds / 1e6;
    double timeRemaining;
    if (!timer.paused && !ai && mode == modePlay) {
      if (identical(node, currentNode) && currentNode.children.isEmpty) {
        if (mainTimeRemaining > 0) {
          g.mainTimeUsed += elapsed;
        } else {
          currentNode.timeUsed += elapsed;
        }
      } else {
        currentNode.timeUsed = 0;
        newBeeping = false;
      }
      timeRemaining = byoLen - currentNode.timeUsed;
      while (timeRemaining < 0 && player.periodsUsed < byoNum) {
        currentNode.timeUsed -= byoLen;
        timeRemaining += byoLen;
        player.periodsUsed += 1;
        usedPeriod = true;
      }
      if (_beepStart - 2 * _timerInterval < timeRemaining &&
          timeRemaining < _beepStart &&
          player.periodsUsed < byoNum) {
        newBeeping = true;
      } else if (timeRemaining > _beepStart) {
        newBeeping = false;
      }
      if (minUse != 0 &&
          !newBeeping &&
          boingAtRemaining - _timerInterval < timeRemaining &&
          timeRemaining < boingAtRemaining + _timerInterval &&
          player.periodsUsed < byoNum) {
        sounds.play(KThemeSounds.minimumTimePassed, volume: 0.1);
      }
    } else {
      newBeeping = false;
    }
    timeRemaining = player.periodsUsed == byoNum ? 0 : byoLen - currentNode.timeUsed;
    final periodsRem = byoNum - player.periodsUsed;
    if (soundsOn) {
      if (beeping && !newBeeping && !usedPeriod) {
        sounds.stop(KThemeSounds.countdown);
      } else if (!beeping && newBeeping) {
        sounds.play(KThemeSounds.countdown, volume: periodsRem > 1 ? 0.5 : 1);
      }
    }
    _lastTimerUpdate = (node: currentNode, time: now, beeping: newBeeping);
    final oldState = (timer.timeRemaining, timer.periodsRemaining, timer.ai);
    if (mainTimeRemaining > 0) {
      timer.timeRemaining = mainTimeRemaining;
      timer.periodsRemaining = null;
    } else {
      timer.timeRemaining = math.max(0, timeRemaining);
      timer.periodsRemaining = math.max(0, periodsRem);
    }
    timer.ai = ai;
    if (oldState != (timer.timeRemaining, timer.periodsRemaining, timer.ai)) timerTicks.value += 1;
  }

  /// Changes whenever the clock shows something new (several times a second while it runs).
  final ValueNotifier<int> timerTicks = ValueNotifier(0);

  void setTimerPaused(bool paused) {
    timer.paused = paused;
    timerTicks.value += 1;
  }

  // -- move tree (movetree.py)

  void setCurrentNode(GameNode node) {
    game!.setCurrentNode(node);
    updateState();
  }

  @override
  set insertNode(GameNode? node) => insertNodeValue = node;
  GameNode? insertNodeValue;

  @override
  void redrawMoveTree() => notifyListeners();

  /// Redraws everything that shows the program's state.
  void refresh() => notifyListeners();

  /// Up or down to the move at the same depth in the next or previous branch (move tree layout order).
  void switchBranch(int direction) {
    final positions = moveTreeLayout(game!.root);
    final pos = positions[game!.currentNode];
    if (pos == null) return;
    final sameX = [
      for (final e in positions.entries)
        if (e.value.$1 == pos.$1) (e.value.$2, e.key),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final index = sameX.indexWhere((e) => e.$1 == pos.$2);
    final newIndex = (index < 0 ? 0 : index) + direction;
    if (newIndex < 0 || newIndex >= sameX.length) return;
    game!.setCurrentNode(sameX[newIndex].$2);
  }

  void deleteSelectedNode() {
    final selected = moveTreeSelectedNode ?? game!.currentNode;
    final parent0 = selected.parent;
    if (parent0 != null) {
      GameNode parent;
      final from = selected.shortcutFrom;
      if (from != null) {
        parent = from;
        final via = [
          for (final (m, v) in parent.shortcutsTo)
            if (identical(m, selected)) v,
        ];
        selected.removeShortcut();
        if (via.isNotEmpty) parent.children.remove(via[0]); // should always be
      } else {
        parent = parent0;
        parent.children.remove(selected);
      }
      setCurrentNode(parent);
    }
    moveTreeSelectedNode = null;
  }

  void pruneBranch() {
    final selected = moveTreeSelectedNode;
    if (selected != null && selected.parent != null) {
      var node = selected;
      while (node.parent != null) {
        node.parent!.children
          ..clear()
          ..add(node);
        node = node.parent!;
      }
      setCurrentNode(selected);
    }
    moveTreeSelectedNode = null;
  }

  void makeSelectedNodeMainBranch() {
    final selected = moveTreeSelectedNode ?? game!.currentNode;
    if (selected.parent != null) {
      var node = selected;
      while (node.parent != null) {
        node.parent!.children
          ..remove(node)
          ..insert(0, node);
        node = node.parent!;
      }
      setCurrentNode(selected);
    }
    moveTreeSelectedNode = null;
  }

  void toggleSelectedNodeCollapse() {
    final selected = moveTreeSelectedNode ?? game!.currentNode;
    if (selected.parent != null) {
      if (selected.shortcutFrom != null) {
        selected.removeShortcut();
      } else {
        // find branching point
        var node = selected.parent!;
        while (node.children.length == 1 && !node.isRoot && node.shortcutFrom == null) {
          node = node.parent!;
        }
        node.addShortcut(selected);
      }
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    timerTicks.dispose();
    board.dispose();
    super.dispose();
  }
}

/// The positions of the move tree's nodes: (column = depth along the drawn tree, row), as movetree.py lays them out.
Map<GameNode, (int, int)> moveTreeLayout(GameNode root) {
  List<GameNode> childrenWithShortcuts(GameNode move) {
    final via = {for (final (m, v) in move.shortcutsTo) v: m}; // children that are shortcut
    return [for (final m in move.orderedChildren) via[m] ?? m];
  }

  final movePos = <GameNode, (int, int)>{root: (0, 0)};
  final stack = childrenWithShortcuts(root).reversed.toList();
  final nextYPos = <int, int>{};
  while (stack.isNotEmpty) {
    final move = stack.removeLast();
    final from = move.shortcutFrom;
    final parent = (from != null && movePos.containsKey(from)) ? from : move.parent; // ignore broken shortcuts
    final x = parent != null ? movePos[parent]!.$1 + 1 : 0;
    final y = math.max(nextYPos[x] ?? 0, movePos[parent]!.$2);
    nextYPos[x] = y + 1;
    nextYPos[x - 1] = math.max(nextYPos[x]!, nextYPos[x - 1] ?? 0);
    movePos[move] = (x, y);
    stack.addAll(childrenWithShortcuts(move).reversed); // stack, so push top child last to process first
  }
  return movePos;
}

/// What the engine reports to the program (KaTrain's engine calls these on its `katrain`).
class _EngineHost implements EngineHost {
  final KaTrainGui gui;
  _EngineHost(this.gui);

  @override
  void log(String message, num level) => gui.log(message, level);

  @override
  void onEngineError(String message, Object? code, {required bool allowPopup, required String engineType}) {
    gui.log(message, outputError);
    if (allowPopup) gui.act('engine-recovery-popup', [message, code, engineType]);
  }

  @override
  void onEngineUpdate() => gui.updateState();

  @override
  void setStatus(String message) => gui.setStatus(message, statusInfo);
}
