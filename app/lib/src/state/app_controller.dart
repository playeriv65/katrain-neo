// The app's controller: the game being shown, the engine, and every action the screen, the keyboard and the local
// API take on them.
//
// Actions on the game run one after the other on a queue (a chain of futures), so a slow one (an AI move waits for
// its analysis) never blocks the screen and actions never interleave. An action queued for a game that has since
// been replaced is dropped. After every action the controller reacts: AI and teaching moves, pondering, redraw.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:katrain_core/api.dart' show ApiState;
import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';

import 'board_state.dart';
import 'dialogs.dart';
import 'game_clock.dart';
import 'graph_model.dart';
import 'move_tree_layout.dart';
import 'sounds.dart';
import 'view_state.dart';

class AppController extends HostBase with ChangeNotifier {
  /// Folder with the packaged resources, for `katrain/...` paths in the engine settings.
  final String resourceDir;
  final Sounds sounds;

  KataGoEngine? engine;
  Object? _engineIo;
  late final _EngineHost _engineHost = _EngineHost(this);

  /// What the engine reports to; for an engine made outside, e.g. in tests.
  EngineHost get engineHost => _engineHost;

  /// The screen showing this controller: opens dialogs and the menu.
  AppScreen? screen;

  bool _pondering = false;
  bool get isPondering => _pondering;
  @override
  set pondering(bool value) => _pondering = value;

  late bool showMoveNum = (config('trainer/show_move_numbers') ?? false) as bool;

  /// 0: everything shown, 1: no control bars, 2: board only.
  int zen = 0;
  String mode = modePlay;
  bool navDrawerOpen = false;

  /// Set while a dialog is open: the AI does not move then.
  bool popupOpen = false;

  final Map<String, bool> analysisControls = defaultAnalysisControls();
  final Map<String, PanelState> panels = defaultPanels();

  /// The status line: its text, its kind, and the node it was set at.
  (String?, num, GameNode?) statusState = (null, -1e9, null);
  String statusText = '';
  bool statusIsError = false;

  // what the panels show of the current position
  GameNode? activeCommentNode;
  List<CommentPart> infoParts = const [];
  String noteText = '';
  String statsScore = '';
  String statsWinrate = '';
  double? statsPointsLost;
  String statsPlayer = '';

  final GraphModel graph = GraphModel();
  final GameClock clock = GameClock();
  final BoardState board = BoardState();

  /// What the local API keeps: marks, snapshots, sandboxes, the tsumego problem.
  final ApiState apiState = ApiState();
  GameNode? moveTreeSelectedNode;

  Future<void> _queue = Future.value();
  int _queued = 0;
  Timer? _clockTimer;

  /// Whether no action is queued or running.
  bool get idle => _queued == 0;

  AppController(super.configStore, {required this.resourceDir, Sounds? sounds, super.debugLevel})
    : sounds = sounds ?? const Sounds.silent();

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
    final lower = message.toLowerCase();
    if (level == outputError || (level == outputKatagoStderr && lower.contains('error') && !lower.contains('tuning'))) {
      setStatus('ERROR: $message', statusError);
    }
  }

  // -- engine and lifetime

  /// Starts the engine and a new game, or loads [sgfFile]. Tests pass an [engineWithoutIo] instead of running
  /// KataGo.
  Future<void> start({String? sgfFile, KataGoEngine? engineWithoutIo}) async {
    if (engine != null) return;
    if (engineWithoutIo != null) {
      engine = engineWithoutIo;
    } else {
      await _makeEngine(GameNode(properties: {'SZ': config('game/size')}).boardSize); // a loaded game may differ
    }
    if (sgfFile != null) {
      loadSgfFile(sgfFile, fast: true, rewind: true);
    } else {
      startGame();
    }
    loadUiState();
    _startClock();
  }

  void _startClock() =>
      _clockTimer ??= Timer.periodic(Duration(milliseconds: (GameClock.interval * 1000).round()), (_) => tickClock());

  Map<String, dynamic> get _engineConfig => (config('engine') as Map).cast<String, dynamic>();

  /// Stops the clock and the engine (on closing the window).
  Future<void> shutdown() async {
    _clockTimer?.cancel();
    _clockTimer = null;
    await _stopEngine();
  }

  Future<void> _stopEngine() async {
    final io = _engineIo;
    if (io is LocalKataGo) await io.shutdown(finish: false);
    if (io is RemoteKataGo) await io.shutdown();
  }

  /// The board size a local KataGo was started for; null when the engine takes any (remote, custom command, tests).
  (int, int)? _engineBoardSize;

  Future<void> _makeEngine((int, int) boardSize) async {
    final (newEngine, io) = await makeEngine(
      _engineHost,
      _engineConfig,
      resourceDir: resourceDir,
      boardSize: boardSize,
    );
    engine = newEngine;
    _engineIo = io;
    _engineBoardSize = io is LocalKataGo ? io.boardSize : null;
  }

  /// Rebuilds the engine from the current settings, for the current game's board, and analyses again (settings
  /// changed, a board of another size, or Retry).
  Future<void> restartEngine() async {
    log('Restarting engine', outputInfo);
    setStatus(i18n.tr('restarting engine'), statusInfo);
    await _stopEngine();
    await _makeEngine(game!.boardSize);
    final newEngine = engine!;
    game!.engines
      ..['B'] = newEngine
      ..['W'] = newEngine;
    game!.analyzeAllNodes(analyzeFast: true); // the old engine was possibly broken, so redo any failures
    updateState();
    _startClock();
  }

  // -- the action queue

  /// Runs [action] after the actions queued before it, on the game shown now (dropped if that game is replaced
  /// meanwhile), then reacts to the result. Completes when it has run.
  Future<void> _enqueue(String what, FutureOr<void> Function(Game game) action, {bool react = true}) {
    final g = game;
    if (g == null) return Future.value();
    _queued += 1;
    return _queue = _queue.then((_) async {
      try {
        if (!identical(game, g)) {
          log('Skipped $what: the game was replaced', outputExtraDebug);
          return;
        }
        await action(g);
        if (react) await _react();
      } catch (e, st) {
        log('$what failed: $e', outputError);
        debugPrintStack(stackTrace: st);
      } finally {
        _queued -= 1;
      }
    });
  }

  /// Opens [dialog] (the clock pauses while it is open).
  void openDialog(AppDialog dialog) {
    if (game == null) return;
    clock.paused = true;
    screen?.openDialog(dialog);
  }

  void toggleMenu() => screen?.toggleMenu();

  @override
  void updateState({bool redrawBoard = false}) =>
      _enqueue('update', (_) => _react(redrawBoard: redrawBoard), react: false);

  List<num> get _evalThresholds => (config('trainer/eval_thresholds') as List).cast<num>();

  /// After every action: mistake sounds, teaching undos and AI moves in play mode, pondering, and the redraw.
  Future<void> _react({bool redrawBoard = false}) async {
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
        g.analyzeUndo(cn);
      }
      if (cn.analysisComplete &&
          nextPlayer.ai &&
          cn.children.isEmpty &&
          g.endResult == null &&
          !(teachingUndo && cn.autoUndo == null)) {
        await _aiMove(g, cn); // only for this position: an undo in between stops it
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
    if (redrawBoard) board.notifyBoardChanged();
    updateEvaluation();
    tickClock();
    notifyListeners();
  }

  // -- games

  /// Replaces the game with [moveTree] (or a new one from the settings) at once; [newGame] queues it.
  void startGame({GameNode? moveTree, bool analyzeFast = false, String? sgfFilename}) {
    _pondering = false;
    // a new game is played, a loaded one reviewed
    if ((moveTree != null && mode == modePlay) || (moveTree == null && mode == modeAnalyze)) switchUiMode();
    board
      ..pv = null
      ..resetRotation()
      ..setZoom(null); // the zoomed problem view belongs to the old game
    apiState.tsumego = null;
    engine!.onNewGame(); // drop the old game's queries
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
        // nobody plays a loaded game
        info.playerType = playerHuman;
        info.playerSubtype = playingNormal;
      }
      updatePlayer(bw, playerType: info.playerType, playerSubtype: info.playerSubtype);
    }
    graph.initializeFromGame(game!.root);
    updateState(redrawBoard: true);
    // a local KataGo only takes the board size it was started for
    final size = game!.boardSize;
    if (_engineBoardSize != null && _engineBoardSize != size) {
      log('The board is ${size.$1}x${size.$2}: restarting KataGo for it', outputInfo);
      unawaited(restartEngine());
    }
  }

  Future<void> newGame({GameNode? moveTree, bool analyzeFast = false}) =>
      _enqueue('new game', (_) => startGame(moveTree: moveTree, analyzeFast: analyzeFast));

  /// Reads an SGF, NGF or GIB file and starts reviewing it; a file that cannot be read is reported.
  void loadSgfFile(String file, {bool fast = false, bool rewind = true}) {
    final GameNode moveTree;
    try {
      moveTree = gameParser.parseBytes(File(file).readAsBytesSync(), fileName: file);
    } on Object catch (e) {
      log(fillTemplate(i18n.tr('Failed to load SGF'), {'error': e}), outputError);
      return;
    }
    startGame(moveTree: moveTree, analyzeFast: fast, sgfFilename: File(file).absolute.path);
    if (!rewind) game!.redo(999);
  }

  /// Reads a game from text, e.g. pasted from the clipboard; false when it is not a game record.
  bool loadSgfText(String text) {
    final GameNode moveTree;
    try {
      moveTree = gameParser.parseSgf(text);
    } on Object catch (e) {
      final contents = text.substring(0, math.min(50, text.length));
      setStatus(
        fillTemplate(i18n.tr('Failed to import from clipboard'), {'error': e, 'contents': contents}),
        statusInfo,
      );
      return false;
    }
    moveTree.nodesInTree.last.analyze(engine!); // the end of the game first, where one usually looks
    startGame(moveTree: moveTree, analyzeFast: true);
    redo(9999);
    log('Imported game from clipboard.', outputInfo);
    return true;
  }

  /// Saves the game to [path], or to the file it came from; without either, asks where.
  Future<void> saveGame([String? path]) => _enqueue('save', (g) {
    final file = path ?? g.sgfFilename;
    if (file == null) return openDialog(AppDialog.saveGameAs);
    try {
      final msg = writeSgf(g, file);
      log(msg, outputInfo);
      setStatus(msg, statusInfo, checkLevel: false);
    } on Object catch (e) {
      log('Failed to save SGF to $file: $e', outputError);
    }
  });

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

  // -- moves and navigation

  /// Plays at [coords] (null passes) for the player to move.
  Future<void> play((int, int)? coords) => _enqueue('play', (g) {
    board.pv = null;
    try {
      final captured = g.prisonerCount['W']! + g.prisonerCount['B']!;
      g.play(Move(coords: coords, player: nextPlayerInfo.player));
      if (captured < g.prisonerCount['W']! + g.prisonerCount['B']!) {
        sounds.play(KThemeSounds.capturing);
      } else if (!g.currentNode.isPass) {
        _playStoneSound();
      }
    } on IllegalMoveException catch (e) {
      setStatus('Illegal Move: $e', statusError);
    }
  });

  Future<void> aiMove() => _enqueue('AI move', (g) => _aiMove(g, null));

  Future<void> _aiMove(Game g, GameNode? onlyAt) async {
    if (onlyAt != null && !identical(g.currentNode, onlyAt)) return;
    final strategy = nextPlayerInfo.strategy;
    final settings = config('ai/$strategy');
    if (settings == null) return log('AI Mode $strategy not found!', outputError);
    await generateAiMove(g, strategy, (settings as Map).cast<String, dynamic>());
  }

  Future<void> resign() => _enqueue('resign', (g) => g.currentNode.endState = '${g.currentNode.player}+R');

  Future<void> undo([int moves = 1]) => _enqueue('undo', (g) {
    board.pv = null;
    g.undo(moves);
  });

  /// Back to the human's last move: two moves when the AI has answered in play mode.
  Future<void> undoSmart() => _enqueue('undo', (g) {
    board.pv = null;
    g.undo(mode == modePlay && lastPlayerInfo.ai && nextPlayerInfo.human ? 2 : 1);
  });

  /// Back to the last branching point (`branch`) or to where this line left the main line (`main-branch`).
  Future<void> undoTo(String target) => _enqueue('undo', (g) {
    board.pv = null;
    g.undo(target);
  });

  Future<void> redo([int moves = 1]) => _enqueue('redo', (g) {
    board.pv = null;
    g.redo(moves);
  });

  /// To the next (or with [backwards], the previous) mistake by a human player.
  Future<void> findMistake({bool backwards = false}) => _enqueue('find mistake', (g) {
    board.pv = null;
    final threshold = _evalThresholds[_evalThresholds.length - 4].toDouble();
    backwards ? g.undo(9999, threshold) : g.redo(9999, threshold);
  });

  /// To the move at the same depth in the branch below ([direction] 1) or above (-1).
  Future<void> nextBranch(int direction) => _enqueue('switch branch', (g) {
    board.pv = null;
    final positions = moveTreeLayout(g.root);
    final pos = positions[g.currentNode];
    if (pos == null) return;
    final column = [
      for (final e in positions.entries)
        if (e.value.$1 == pos.$1) (e.value.$2, e.key),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final index = column.indexWhere((e) => e.$1 == pos.$2) + direction;
    if (index >= 0 && index < column.length) g.setCurrentNode(column[index].$2);
  });

  void setCurrentNode(GameNode node) {
    game!.setCurrentNode(node);
    updateState();
  }

  Future<void> insertMode([Object mode = 'toggle']) => _enqueue('insert mode', (g) {
    g.setInsertMode(mode);
    if (this.mode != modeAnalyze) switchUiMode();
  });

  void rotate() => board.rotate();

  // -- analysis

  Future<void> resetAnalysis() => _enqueue('reset analysis', (g) => g.resetCurrentAnalysis());

  /// One of the extra analysis modes (`extra`, `equalize`, `sweep`, `alternative`, `local`, `game`, `stop`).
  Future<void> analyzeExtra(String analysis, {bool mistakesOnly = false, List<int>? moveRange, int? visits}) =>
      _enqueue(
        'analysis',
        (g) => g.analyzeExtra(analysis, mistakesOnly: mistakesOnly, moveRange: moveRange, visits: visits),
      );

  /// Plays on with the AI until move [until] (or `end`), aiming at [blackAdvantage] points for Black.
  Future<void> selfplay(Object until, {double? blackAdvantage}) =>
      _enqueue('self-play', (g) => g.selfplay(until, targetBAdvantage: blackAdvantage));

  /// Lets the user drag a region of interest on the board.
  void selectRegion() {
    setStatus(i18n.tr('analysis:region:start'), statusInfo);
    board.selectingRegionOfInterest = true;
  }

  Future<void> tsumegoFrame(bool ko, int margin) => _enqueue('tsumego frame', (_) => applyTsumegoFrame(ko, margin));

  /// Fills the board around the problem on it and analyses only the problem's area.
  void applyTsumegoFrame(bool ko, int margin) {
    final g = game!;
    if (g.stones.isEmpty) return;
    final (node, region) = tsumegoFrameForGame(g, g.komi, nextPlayerInfo.player == 'B', ko, margin);
    g.setCurrentNode(node);
    if (mode == modePlay) switchUiMode();
    if (region != null) {
      g.setRegionOfInterest([region.$1.$2, region.$1.$1, region.$2.$2, region.$2.$1]);
      g.regionRoot = true; // the best move inside the problem is the reference: frame moves are noise
      node.analyze(g.engines[node.nextPlayer]!, regionOfInterest: g.regionOfInterest, regionRoot: true);
    } else {
      node.analyze(g.engines[node.nextPlayer]!);
    }
    updateState(redrawBoard: true);
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

  void setNote(String note) {
    game!.currentNode.note = note;
    noteText = note;
  }

  // -- sounds

  void _playStoneSound() => sounds.play(KThemeSounds.randomStone());

  void playMistakeSound(GameNode node) {
    if ((config('timer/sound') ?? false) == true &&
        node.playedMistakeSound == null &&
        sounds.mistakeSounds.isNotEmpty) {
      node.playedMistakeSound = true;
      sounds.play(sounds.mistakeSounds[math.Random().nextInt(sounds.mistakeSounds.length)]);
    }
  }

  // -- modes and the view each mode keeps

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
    updateState(); // locks the AI even if nothing else changed
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

  // -- status line and evaluation

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

  /// Shows the analysis and comments of the current position, and updates the score graph.
  void updateEvaluation() {
    final g = game;
    if (g == null) return;
    final currentNode = g.currentNode;
    if ((!identical(currentNode, statusState.$3) && !(statusState.$2 == statusError && statusState.$3 == null)) ||
        ((engine?.isIdle() ?? false) && statusState.$2 == statusAnalysis)) {
      // a status belongs to its position (startup errors stay); analysis messages go once nothing is queued
      statusText = '';
      statusState = (null, -1e9, null);
    }
    var commentNode = currentNode;
    if (mode == modePlay && lastPlayerInfo.ai && nextPlayerInfo.human) {
      // against the AI, explain the human's move rather than the AI's answer
      if (nextPlayerInfo.beingTaught && currentNode.children.isNotEmpty && currentNode.children.last.autoUndo == true) {
        commentNode = currentNode.children.last;
      } else if (currentNode.parent != null) {
        commentNode = currentNode.parent!;
      }
    } else if (lastPlayerInfo.ai && nextPlayerInfo.ai && !currentNode.analysisExists && currentNode.parent != null) {
      commentNode = currentNode.parent!;
    }
    activeCommentNode = commentNode;
    final lockAi = (config('trainer/lock_ai') ?? false) == true && mode == modePlay;
    final details = panels['notes_panel']!.options['info-details']! && !lockAi;
    infoParts = currentNode.move != null || currentNode.isRoot
        ? commentNode.commentParts(teach: playersInfo[commentNode.player]!.beingTaught, details: details)
        : const [];
    final analysed = commentNode.analysisExists;
    statsScore = analysed ? commentNode.formatScore() ?? '' : '';
    statsWinrate = analysed ? commentNode.formatWinrate() ?? '' : '';
    statsPointsLost = analysed ? commentNode.pointsLost : null;
    statsPlayer = analysed ? commentNode.player : '';
    graph.updateValue(currentNode);
    noteText = currentNode.note;
  }

  // -- clock

  void tickClock() {
    final g = game;
    if (g == null) return;
    clock.tick(
      g,
      nextPlayerInfo,
      (
        mainTime: ((config('timer/main_time') ?? 0) as num).toDouble(),
        byoLength: ((config('timer/byo_length') ?? 30) as num).toDouble(),
        byoPeriods: ((config('timer/byo_periods') ?? 5) as num).toInt(),
        minimalUse: ((config('timer/minimal_use') ?? 0) as num).toDouble(),
        sound: config('timer/sound') == true,
      ),
      sounds,
      running: mode == modePlay && !popupOpen,
    );
  }

  // -- move tree

  @override
  set insertNode(GameNode? node) => insertNodeValue = node;
  GameNode? insertNodeValue;

  @override
  void redrawMoveTree() => notifyListeners();

  /// Redraws everything that shows the app's state.
  void refresh() => notifyListeners();

  void deleteSelectedNode() {
    final selected = moveTreeSelectedNode ?? game!.currentNode;
    moveTreeSelectedNode = null;
    final parent = selected.parent;
    if (parent == null) return;
    final from = selected.shortcutFrom;
    if (from != null) {
      // a collapsed branch: remove the hidden line the shortcut stands for
      final via = [
        for (final (m, v) in from.shortcutsTo)
          if (identical(m, selected)) v,
      ];
      selected.removeShortcut();
      if (via.isNotEmpty) from.children.remove(via[0]);
      setCurrentNode(from);
    } else {
      parent.children.remove(selected);
      setCurrentNode(parent);
    }
  }

  /// Keeps only the line through the selected node.
  void pruneBranch() {
    final selected = moveTreeSelectedNode;
    moveTreeSelectedNode = null;
    if (selected == null || selected.parent == null) return;
    for (var node = selected; node.parent != null; node = node.parent!) {
      node.parent!.children
        ..clear()
        ..add(node);
    }
    setCurrentNode(selected);
  }

  void makeSelectedNodeMainBranch() {
    final selected = moveTreeSelectedNode ?? game!.currentNode;
    moveTreeSelectedNode = null;
    if (selected.parent == null) return;
    for (var node = selected; node.parent != null; node = node.parent!) {
      node.parent!.children
        ..remove(node)
        ..insert(0, node);
    }
    setCurrentNode(selected);
  }

  void toggleSelectedNodeCollapse() {
    final selected = moveTreeSelectedNode ?? game!.currentNode;
    if (selected.parent == null) return;
    if (selected.shortcutFrom != null) {
      selected.removeShortcut();
    } else {
      // collapse back to the branching point
      var node = selected.parent!;
      while (node.children.length == 1 && !node.isRoot && node.shortcutFrom == null) {
        node = node.parent!;
      }
      node.addShortcut(selected);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    clock.dispose();
    board.dispose();
    super.dispose();
  }
}

/// What the engine reports to the app.
class _EngineHost implements EngineHost {
  final AppController app;
  _EngineHost(this.app);

  @override
  void log(String message, num level) => app.log(message, level);

  @override
  void onEngineError(String message, Object? code, {required bool allowPopup, required String engineType}) {
    // the engine has logged the error already
    if (allowPopup && app.game != null) app.screen?.showEngineFailure(EngineFailure(message, code, engineType));
  }

  @override
  void onEngineUpdate() => app.updateState();

  @override
  void setStatus(String message) => app.setStatus(message, statusInfo);
}
