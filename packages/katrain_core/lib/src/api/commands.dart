// The commands of the local API (from the playeriv65/katrain fork's katrain/api/commands.py, same commands,
// arguments and results), run in the app. Commands that wait for KataGo (`waitsForEngine`) await its results; the
// app stays responsive meanwhile.

import 'package:collection/collection.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/katrain_base.dart' show neoDataFolder;
import '../constants.dart';
import '../engine/analysis_engine.dart';
import '../engine/io/local_katago.dart' show expandUser;
import '../game/game.dart';
import '../game/game_node.dart';
import '../game/player.dart';
import '../sgf/move.dart';
import '../utils/format.dart';
import 'args.dart';
import 'model.dart';
import 'overlay.dart';
import 'protocol.dart';
import 'sandbox.dart';
import 'state.dart';
import 'tsumego.dart';

const backgroundPriority = -50; // below the app's interactive queries (priorityDefault), above game re-analysis

/// The search settings agents may change, and whether each is a whole number.
const engineSettings = {'max_visits': true, 'fast_visits': true, 'max_time': false, 'wide_root_noise': false};

/// API names of the display toggles, and the app's analysis control each sets.
const viewToggles = {
  'hints': 'hints',
  'ownership': 'ownership',
  'policy': 'policy',
  'eval': 'eval',
  'children': 'show_children',
};

typedef CommandFn = FutureOr<Object?> Function(CommandHandler h, ApiArgs a);

/// A command: what it does, its help line, and whether it waits for KataGo.
class ApiCommand {
  final CommandFn run;
  final String help;
  final bool waitsForEngine;
  const ApiCommand(this.run, this.help, {this.waitsForEngine = false});
}

/// What the commands use of the app: its game and engine, settings, display and controls.
abstract interface class ApiHost {
  Game? get game;

  /// The engine the app uses (status and waiting); games analyse with their own `engines`.
  AnalysisEngine<GameNode>? get engine;
  bool engineAlive(AnalysisEngine<GameNode> engine);
  bool engineIdle(AnalysisEngine<GameNode> engine);
  int engineQueriesRemaining(AnalysisEngine<GameNode> engine);

  Map<String, Player> get playersInfo;
  Object? config(String setting, [Object? defaultValue]);
  void saveConfig([String? key]);

  /// KaTrain's `update_state`: AI moves, teaching, pondering, redraws.
  void updateState({bool redrawBoard = false});

  /// Redraws the variation and marks over the board.
  void redrawOverlay();
  void redrawMoveTree();

  bool get pondering;
  void toggleContinuousAnalysis({bool quiet = false});

  /// `play` or `analyze`.
  String get mode;
  void selectMode(String mode);

  /// The status bar text, and showing a text there.
  String get statusMessage;
  void showStatus(String text);

  /// Starts reviewing [moveTree] as a new game.
  void newGame(GameNode moveTree, {bool analyzeFast = false, String? sgfFilename});

  /// Puts KaTrain's tsumego frame around the problem on the board.
  void tsumegoFrame(bool ko, int margin);

  /// The variation drawn over the board (the board's own, also for hovering).
  PvOverlay? get pv;
  set pv(PvOverlay? value);

  bool analysisControl(String key);
  void setAnalysisControl(String key, bool value);
  bool get showMoveNumbers;
  set showMoveNumbers(bool value);

  /// The zoomed part of the board `[xmin, xmax, ymin, ymax]`, and stones not drawn (a hidden tsumego frame).
  List<int>? get zoomRegion;
  Set<(int, int)> get hiddenCoords;
  void setZoom(List<int>? region, [Set<(int, int)> hidden = const {}]);
}

/// Every command, by name.
final Map<String, ApiCommand> apiCommands = {..._coreCommands, ...tsumegoCommands, ...sandboxCommands};

class CommandHandler {
  final ApiHost host;
  final ApiState state;

  /// Where previous games are backed up before an import replaces them.
  final String dataFolder;
  CommandHandler(this.host, this.state, {String? dataFolder}) : dataFolder = dataFolder ?? expandUser(neoDataFolder);

  Future<Object?> dispatch(String name, Map<String, dynamic> args) async {
    final command = apiCommands[name];
    if (command == null) {
      throw ApiError('unknown_command', "unknown command '$name'", {'available': apiCommands.keys.toList()..sort()});
    }
    return await command.run(this, ApiArgs(args));
  }

  Game get game => host.game ?? (throw ApiError('no_game', 'no game loaded'));

  GameNode node(ApiArgs a, [String key = 'node']) => resolveNode(game, a.text(key));

  AnalysisEngine<GameNode> engineFor(GameNode node) {
    final engine = game.engines[node.nextPlayer];
    if (engine == null || !host.engineAlive(engine)) {
      throw ApiError('engine_unavailable', 'KataGo engine is not running', {'hint': 'check the engine status dot'});
    }
    return engine;
  }

  int defaultVisits(AnalysisEngine<GameNode> engine) => engine.config['max_visits'] as int;

  void refresh([bool redraw = true]) {
    host.updateState(redrawBoard: redraw);
    host.redrawOverlay();
  }

  void ensureNotInserting() {
    if (game.insertMode) throw ApiError('insert_mode', "finish KaTrain's insert mode before navigating");
  }

  void goto(GameNode node) {
    ensureNotInserting();
    host.pv = null;
    game.setCurrentNode(node);
    refresh();
  }

  Map<String, Object?> currentJson([ApiArgs? a]) => {
    'current': nodeJson(game.currentNode),
    if (a != null && a.flag('board')) 'board': boardJson(game.currentNode),
  };

  void setMode(String mode) {
    if (host.mode != mode) host.selectMode(mode);
  }

  /// The moves in [key], colours alternating from [start]'s player to move unless `color` says otherwise.
  List<Move> moves(ApiArgs a, GameNode start, [String key = 'moves']) {
    final moves = parseMoves(a.words(key), start.boardSize, parseColor(a.text('color')) ?? start.nextPlayer);
    if (moves.isEmpty) throw ApiError('bad_argument', 'no moves given');
    return moves;
  }

  /// Moves for the player to move at [node], one each (candidates to compare).
  List<Move> candidates(GameNode node, List<String> names) {
    final moves = [for (final m in names) Move(coords: parseCoords(m, node.boardSize), player: node.nextPlayer)];
    for (final m in moves) {
      checkMovesLegal(node, [m]);
    }
    return moves;
  }

  /// Creates (or reuses) nodes for [moves] below [start]; returns the nodes and how many were created. New nodes
  /// are analysed fast, fully or not at all ([analyze]).
  (List<GameNode>, int) addNodes(GameNode start, List<Move> moves, {String analyze = 'fast'}) {
    checkMovesLegal(start, moves);
    var node = start;
    final nodes = <GameNode>[];
    var created = 0;
    for (final move in moves) {
      final existing = node.children.where((c) => c.move == move).firstOrNull;
      node = existing ?? node.play(move);
      if (existing == null) {
        nodeId(node); // number new nodes in move order
        created += 1;
        state.created.add(node);
        if (analyze != 'none') node.analyze(game.engines[node.nextPlayer]!, analyzeFast: analyze == 'fast');
      }
      nodes.add(node);
    }
    return (nodes, created);
  }

  Map<String, Object?> editNotice(int created) => created > 0 && state.demo == null
      ? {'game_modified': true, 'hint': "moves were added to the game record; use 'demo start' for throwaway lines"}
      : {'game_modified': created > 0, 'in_demo': state.demo != null};

  /// Removes [node] and the nodes below it from the tree; returns how many.
  int removeSubtree(GameNode node) {
    final subtree = node.nodesInTree;
    for (final n in subtree) {
      n.removeShortcut();
    }
    node.parent!.children.removeWhere((c) => identical(c, node));
    return subtree.length;
  }

  // -- snapshots

  Snapshot capture() {
    final pv = host.pv;
    return Snapshot(
      root: game.root,
      node: game.currentNode,
      mode: host.mode,
      region: game.regionOfInterest,
      marks: state.marks,
      pv: pv != null && pv.pinned ? pv.copy() : null, // only variations the API showed, not mouse hovers
      message: host.statusMessage,
    );
  }

  void restore(Snapshot snap) {
    final g = game;
    if (!identical(g.root, snap.root)) {
      throw ApiError('game_changed', 'the snapshot belongs to a different game than the one loaded');
    }
    final tree = Set<GameNode>.identity()..addAll(g.root.nodesInTree);
    var node = snap.node;
    while (!tree.contains(node) && node.parent != null) {
      node = node.parent!; // the saved node was deleted: its nearest remaining ancestor
    }
    state.marks = List.of(snap.marks);
    goto(node);
    g.regionOfInterest = snap.region == null ? null : List.of(snap.region!);
    setMode(snap.mode);
    final pv = snap.pv;
    if (pv != null && tree.contains(pv.node)) host.pv = PvOverlay(pv.moves, pv.node, index: pv.index, pinned: true);
    host.showStatus(snap.message);
    refresh();
  }

  // -- analysis plumbing

  /// Sends one KataGo query, feeds the results into the node as the app does, and waits for the final one.
  ///
  /// [background] is for sandbox positions the user cannot see: below the app's own queries in priority, no
  /// progress reports and no refresh. [regionRoot] stores a region result as the node's evaluation.
  Future<Map<String, dynamic>> search(
    GameNode node,
    AnalysisEngine<GameNode> engine,
    int visits, {
    List<int>? region,
    Move? refineMove,
    int timeout = 300,
    double? maxTime,
    bool? ownership,
    bool background = false,
    bool regionRoot = false,
  }) async {
    if (node.nodesFromRoot.any((n) => n.clearPlacements.isNotEmpty)) {
      throw ApiError('unsupported_position', 'positions with AE (cleared stones) cannot be analyzed');
    }
    final done = Completer<Map<String, dynamic>>();
    engine.requestAnalysis(
      node,
      callback: (result, partial) {
        try {
          node.setAnalysis(result, refineMove, false, regionRoot ? null : region, partial);
        } finally {
          if (!partial && !done.isCompleted) done.complete(result);
        }
      },
      errorCallback: (result) {
        if (!done.isCompleted) done.completeError(ApiError('engine_error', '${result['error'] ?? result}'));
      },
      visits: visits,
      timeLimit: false,
      nextMove: refineMove,
      regionOfInterest: region,
      priority: background ? backgroundPriority : priorityExtraAnalysis,
      reportEvery: (refineMove != null || background) ? null : reportDt.toDouble(),
      extraSettings: maxTime != null && maxTime > 0 ? {'maxTime': maxTime} : null,
      ownership: ownership,
    );
    final Map<String, dynamic> result;
    try {
      result = await done.future.timeout(Duration(seconds: timeout));
    } on TimeoutException {
      throw ApiError('timeout', 'analysis did not finish within ${timeout}s', {
        'hint': 'raise --timeout or lower --visits',
      });
    }
    if (!background) host.updateState();
    return result;
  }
}

/// Candidates sorted by points lost, unknown losses last.
void sortByPointsLost(List<Map<String, Object?>> candidates) =>
    stableSortBy(candidates, (c) => (c['points_lost'] as num?) ?? double.infinity);

// -- meta and reading

Object? _commands(CommandHandler h, ApiArgs a) => {
  for (final name in apiCommands.keys.toList()..sort())
    name: {'help': apiCommands[name]!.help, 'waits_for_engine': apiCommands[name]!.waitsForEngine},
};

Map<String, Object?> status(CommandHandler h) {
  final host = h.host, game = h.game;
  final root = game.root, cn = game.currentNode;
  final engine = host.engine;
  final demo = h.state.demo;
  return {
    'game': {
      'board_size': [game.boardSize.$1, game.boardSize.$2],
      'komi': game.komi,
      'rules': root.ruleset,
      'handicap': root.handicap,
      'players': {
        for (final bw in const ['B', 'W'])
          bw: {
            'name': [
              root.getProperty('P$bw'),
              host.playersInfo[bw]!.name,
            ].firstWhere(ApiArgs.isGiven, orElse: () => null),
            'rank': root.getProperty('${bw}R'),
            'type': host.playersInfo[bw]!.playerType,
            'subtype': host.playersInfo[bw]!.playerSubtype,
          },
      },
      'result': root.getProperty('RE'),
      'sgf_filename': game.sgfFilename,
      'game_id': game.gameId,
      'nodes': root.nodesInTree.length,
      'main_line_moves': mainLine(root).last.depth,
    },
    'current': nodeJson(cn),
    'current_line_moves': lineNodes(cn).last.depth,
    'on_main_line': onMainLine(cn),
    'mode': host.mode,
    'pondering': host.pondering,
    'insert_mode': game.insertMode,
    'region_of_interest': regionJson(game.regionOfInterest),
    'engine': engine == null
        ? null
        : {
            'alive': host.engineAlive(engine),
            'idle': host.engineIdle(engine),
            'queries_remaining': host.engineQueriesRemaining(engine),
            'model': '${engine.config['model'] ?? ''}'.split(RegExp(r'[/\\]')).last,
            for (final key in engineSettings.keys) key: engine.config[key],
          },
    'demo': demo == null ? null : {'started_at': nodeRef(demo.snapshot.node), 'label': demo.label},
    'pv_shown': host.pv != null,
    'marks': h.state.marks.length,
    'tsumego': h.state.tsumego?.summary(),
  };
}

Object? _history(CommandHandler h, ApiArgs a) {
  final node = h.node(a);
  final cur = h.game.currentNode;
  final withEval = a.flag('eval', orElse: true);
  return {
    'node': nodeRef(node),
    'nodes': [
      for (final n in a.flag('future') ? lineNodes(node) : node.nodesFromRoot)
        {
          ...nodeJson(n, withEval: withEval),
          if (identical(n, cur)) 'current': true,
          if (n.children.length > 1) 'variations': n.children.length,
        },
    ],
  };
}

Object? _tree(CommandHandler h, ApiArgs a) => {
  'current': nodeRef(h.game.currentNode),
  'tree': treeJson(resolveNode(h.game, a.text('node', orElse: 'root')), a.integer('max_depth')),
};

Object? _variations(CommandHandler h, ApiArgs a) {
  final node = h.node(a);
  final siblings = node.parent?.orderedChildren ?? [node];
  return {
    'node': nodeRef(node),
    'children': [for (final c in node.orderedChildren) branchJson(c, a.integer('max_len', orElse: 20))],
    'siblings': [for (final s in siblings) nodeRef(s)],
    'sibling_index': siblings.indexWhere((s) => identical(s, node)),
    'branch_points_on_line': [
      for (final n in lineNodes(node))
        if (n.children.length > 1)
          {
            'node': nodeRef(n),
            'move_number': n.depth,
            'branches': [for (final c in n.orderedChildren) branchJson(c, 8)],
          },
    ],
  };
}

// -- SGF and games

/// Saves the current game before replacing it, so nothing is lost by an API import.
String? _backupGame(CommandHandler h) {
  final game = h.game;
  if (game.root.nodesInTree.length <= 1) return null;
  final folder = Directory('${h.dataFolder}${Platform.pathSeparator}api_backups')..createSync(recursive: true);
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(RegExp(r'[-:]'), '')
      .replaceAll('T', '_')
      .replaceAll('.', '_');
  final path = '${folder.path}${Platform.pathSeparator}backup_$stamp.sgf';
  File(path).writeAsStringSync(game.root.sgf());
  return path;
}

/// Replaces the game with [moveTree] (after backing it up); the API's own state of the old game goes.
String? loadTree(CommandHandler h, GameNode moveTree, {bool fast = false, bool atEnd = false, String? sgfFilename}) {
  final backup = _backupGame(h);
  h.state
    ..demo = null
    ..marks = []
    ..tsumego = null;
  h.host.setZoom(null);
  h.host.newGame(moveTree, analyzeFast: fast, sgfFilename: sgfFilename);
  if (atEnd) h.game.redo(9999);
  h.refresh();
  return backup;
}

Object? _sgfExport(CommandHandler h, ApiArgs a) {
  final trainer = ((h.host.config('trainer') as Map?) ?? const {}).cast<String, dynamic>();
  final comments = a.flag('comments');
  final sgf = h.game.root.sgf(
    SgfSaveOptions(
      saveCommentsPlayer: comments ? const {'B': true, 'W': true} : null,
      saveCommentsClass: comments ? (trainer['save_feedback'] as List?)?.cast<bool>() : null,
      evalThresholds: (trainer['eval_thresholds'] as List?)?.cast<num>(),
      saveAnalysis: a.flag('analysis'),
      saveMarks: a.flag('marks'),
    ),
  );
  final path = a.text('path');
  if (path == null) return {'sgf': sgf};
  final file = File(absPath(path));
  if (file.existsSync() && !a.flag('overwrite')) {
    throw ApiError('file_exists', '${file.path} exists', {'hint': 'pass overwrite=true to replace it'});
  }
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(sgf);
  return {'path': file.path, 'bytes': utf8.encode(sgf).length};
}

Object? _sgfImport(CommandHandler h, ApiArgs a) {
  final content = a.text('content'), path = a.text('path');
  if (content == null && path == null) throw ApiError('bad_argument', "give 'path' or 'content'");
  final filename = content == null ? absPath(path!) : null;
  final GameNode tree;
  try {
    tree = filename == null
        ? gameParser.parseSgf(content!)
        : gameParser.parseBytes(File(filename).readAsBytesSync(), fileName: filename);
  } on Object catch (e) {
    throw ApiError('sgf_parse_error', 'could not read SGF: $e');
  }
  final backup = loadTree(h, tree, fast: a.flag('fast'), atEnd: a.flag('at_end'), sgfFilename: filename);
  return {'loaded': filename ?? '<content>', 'previous_game_backup': backup, ...status(h)};
}

Object? _gameNew(CommandHandler h, ApiArgs a) {
  final host = h.host;
  final size = a.text('size', orElse: '${host.config('game/size')}');
  final komi = a['komi'] ?? host.config('game/komi'); // 0 is a komi
  final rules = a.text('rules', orElse: '${host.config('game/rules')}');
  final tree = gameParser.parseSgf('(;GM[1]FF[4]SZ[$size]KM[$komi]RU[$rules])');
  final handicap = a.integer('handicap', orElse: 0, min: 0)!;
  if (handicap > 0) {
    tree.setProperty('HA', handicap);
    tree.placeHandicapStones(handicap);
  }
  return {'previous_game_backup': loadTree(h, tree), ...status(h)};
}

// -- analysis

Map<String, Object?> _analysisView(GameNode node, ApiArgs a, {List<String>? moves}) => analysisJson(
  node,
  top: moves != null ? null : a.integer('top', orElse: 10),
  includePv: a.flag('pv', orElse: true),
  pvLimit: a.integer('pv_limit'),
  ownership: a.flag('ownership'),
  policy: a.flag('policy'),
  moves: moves,
);

Object? _analysisGet(CommandHandler h, ApiArgs a) {
  final node = h.node(a);
  return a.has('moves') ? _analysisView(node, a, moves: a.words('moves')) : _analysisView(node, a);
}

/// Whether [node] already has a complete analysis of about [visits] (a search may stop early at max_time).
bool _deepEnough(GameNode node, int visits) => node.analysisComplete && node.rootVisits >= 0.95 * visits;

Future<Object?> _analysisRun(CommandHandler h, ApiArgs a) async {
  final timeout = a.integer('timeout', orElse: 300, min: 1)!;
  final node = h.node(a);
  final engine = h.engineFor(node);
  final visits = a.integer('visits', orElse: h.defaultVisits(engine), min: 1)!;
  final regionArg = a.text('region');
  final region = regionArg == 'gui'
      ? h.game.regionOfInterest
      : (regionArg == null ? null : parseRegion(regionArg, node.boardSize));
  final cached = !a.flag('force') && region == null && _deepEnough(node, visits);
  if (!cached) {
    if (!a.flag('wait', orElse: true)) {
      node.analyze(engine, visits: visits, priority: priorityExtraAnalysis, timeLimit: false, regionOfInterest: region);
      return {'queued': true, 'node': nodeRef(node), 'visits': visits};
    }
    if (region != null && !node.analysisExists) {
      // region results don't carry a root evaluation: get one first
      final fast = engine.config['fast_visits'] as int?;
      await h.search(node, engine, fast != null && fast > 0 ? fast : 25, timeout: timeout);
    }
    await h.search(node, engine, visits, region: region, timeout: timeout, maxTime: a.number('max_time'));
  }
  return {
    ..._analysisView(node, a),
    'reused_existing': cached,
    'requested_visits': visits,
    'region': regionJson(region),
  };
}

Future<Object?> _analysisMoves(CommandHandler h, ApiArgs a) async {
  final timeout = a.integer('timeout', orElse: 300, min: 1)!;
  final node = h.node(a);
  final engine = h.engineFor(node);
  final visits = a.integer('visits', orElse: h.defaultVisits(engine), min: 1)!;
  final names = a.words('moves');
  if (names.isEmpty) throw ApiError('bad_argument', 'give at least one move to compare');
  final moves = h.candidates(node, names);
  if (!node.analysisExists) await h.search(node, engine, visits, timeout: timeout);
  final errors = <String, Object?>{};
  await Future.wait([
    for (final move in moves)
      h
          .search(node, engine, visits, refineMove: move, timeout: timeout)
          .then<void>((_) {})
          .catchError((Object e) => errors[move.gtp()] = (e as ApiError).toJson(), test: (e) => e is ApiError),
  ]);
  final result = _analysisView(node, a, moves: [for (final m in moves) m.gtp()]);
  sortByPointsLost(result['candidates'] as List<Map<String, Object?>>);
  return {...result, 'compared_visits': visits, if (errors.isNotEmpty) 'errors': errors};
}

Object? _analysisGame(CommandHandler h, ApiArgs a) {
  final visits = a.has('visits') ? a.integer('visits', min: 1) : null;
  List<int>? moveRange;
  final range = a.text('move_range');
  if (range != null) {
    final m = RegExp(r'^\s*(\d+)\s*[-:]\s*(\d+)\s*$').firstMatch(range);
    if (m == null) throw ApiError('bad_argument', 'move_range must look like 20-60, got $range');
    moveRange = [int.parse(m[1]!), int.parse(m[2]!)];
  }
  final mistakesOnly = a.flag('mistakes_only');
  h.engineFor(h.game.currentNode);
  h.game.analyzeExtra('game', mistakesOnly: mistakesOnly, visits: visits, moveRange: moveRange);
  return {
    'queued': true,
    'mistakes_only': mistakesOnly,
    'visits': ?visits,
    'move_range': ?moveRange,
    'queries_remaining': h.host.engineQueriesRemaining(h.host.engine!),
  };
}

Future<Object?> _analysisWait(CommandHandler h, ApiArgs a) async {
  final timeout = a.integer('timeout', orElse: 300, min: 1)!;
  final engine = h.engineFor(h.game.currentNode);
  if (h.host.pondering) {
    throw ApiError('pondering', 'continuous analysis is on, the engine never becomes idle', {
      'hint': 'analysis ponder off',
    });
  }
  final deadline = DateTime.now().add(Duration(seconds: timeout));
  while (!h.host.engineIdle(engine)) {
    if (DateTime.now().isAfter(deadline)) {
      throw ApiError('timeout', 'engine still busy after ${timeout}s', {
        'queries_remaining': h.host.engineQueriesRemaining(engine),
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return {'idle': true};
}

Object? _analysisPonder(CommandHandler h, ApiArgs a) {
  if (a.flag('on', orElse: true) != h.host.pondering) h.host.toggleContinuousAnalysis(quiet: true);
  return {'pondering': h.host.pondering};
}

Object? _analysisStop(CommandHandler h, ApiArgs a) {
  h.game.analyzeExtra('stop');
  h.refresh(false);
  return {'stopped': true};
}

Map<String, Object?> _engineGet(CommandHandler h, ApiArgs a) {
  final engineConfig = h.host.config('engine') as Map;
  return {for (final key in engineSettings.keys) key: engineConfig[key]};
}

Object? _engineSet(CommandHandler h, ApiArgs a) {
  final engineConfig = h.host.config('engine') as Map;
  final engine = h.host.engine;
  final changed = <String, Object?>{
    for (final MapEntry(key: key, value: whole) in engineSettings.entries)
      if (a[key] != null) key: whole ? a.integer(key, min: 0) : a.number(key, min: 0),
  };
  if (changed.isEmpty) {
    throw ApiError('bad_argument', 'nothing to change, use one of ${engineSettings.keys.join(', ')}');
  }
  engineConfig.addAll(changed);
  if (engine != null && !identical(engine.config, engineConfig)) engine.config.addAll(changed);
  if (a.flag('save')) h.host.saveConfig('engine');
  return {'changed': changed, 'saved': a.flag('save'), ..._engineGet(h, a)};
}

// -- navigation and editing

Object? _goto(CommandHandler h, ApiArgs a) {
  h.goto(h.node(a));
  return h.currentJson(a);
}

Object? _step(CommandHandler h, ApiArgs a, {required bool forward}) {
  h.ensureNotInserting();
  h.host.pv = null;
  final n = a.integer('n', orElse: 1, min: 1)!;
  forward ? h.game.redo(n) : h.game.undo(n);
  h.refresh();
  return h.currentJson(a);
}

Object? _branch(CommandHandler h, ApiArgs a) {
  final cn = h.game.currentNode;
  final siblings = cn.parent?.orderedChildren ?? (throw ApiError('no_variation', 'the root has no siblings'));
  final idx = a.integer('index') ?? siblings.indexWhere((s) => identical(s, cn)) + a.integer('direction', orElse: 1)!;
  if (idx < 0 || idx >= siblings.length) {
    throw ApiError('no_variation', 'no sibling at index $idx', {'siblings': siblings.length});
  }
  h.goto(siblings[idx]);
  return {...h.currentJson(a), 'sibling_index': idx, 'siblings': siblings.length};
}

Object? _play(CommandHandler h, ApiArgs a) {
  final game = h.game, cn = game.currentNode;
  if (game.insertMode) throw ApiError('insert_mode', "finish KaTrain's insert mode first");
  final moves = h.moves(a, cn);
  final (nodes, created) = h.addNodes(cn, moves, analyze: a.flag('analyze', orElse: true) ? 'full' : 'none');
  h.host.pv = null;
  game.setCurrentNode(nodes.last);
  h.refresh();
  return {
    ...h.currentJson(a),
    'played': [for (final m in moves) m.gtp()],
    'nodes': [for (final n in nodes) nodeRef(n)],
    ...h.editNotice(created),
  };
}

Object? _variationAdd(CommandHandler h, ApiArgs a) {
  final start = h.node(a, 'from');
  final (nodes, created) = h.addNodes(start, h.moves(a, start), analyze: a.text('analyze', orElse: 'fast')!);
  a.flag('goto') ? h.goto(nodes.last) : h.refresh();
  return {
    'from': nodeRef(start),
    'nodes': [for (final n in nodes) nodeRef(n)],
    'end': nodeRef(nodes.last),
    ...h.editNotice(created),
  };
}

Object? _variationDelete(CommandHandler h, ApiArgs a) {
  final node = h.node(a);
  final parent = node.parent ?? (throw ApiError('bad_argument', 'cannot delete the root'));
  final subtree = node.nodesInTree;
  final foreign = subtree.where((n) => !h.state.created.contains(n)).length;
  if (foreign > 0 && !a.flag('force')) {
    throw ApiError('protected', '$foreign of ${subtree.length} nodes were not created through the API', {
      'hint': 'pass force=true to delete original game nodes',
    });
  }
  final wasCurrent = subtree.any((n) => identical(n, h.game.currentNode));
  final deleted = h.removeSubtree(node);
  wasCurrent ? h.goto(parent) : h.refresh();
  return {'deleted_nodes': deleted, ...h.currentJson()};
}

Object? _variationPromote(CommandHandler h, ApiArgs a) {
  final node = h.node(a);
  for (var n = node; n.parent != null; n = n.parent!) {
    final siblings = n.parent!.children;
    siblings.removeWhere((c) => identical(c, n));
    siblings.insert(0, n);
  }
  h.refresh();
  return {'promoted': nodeRef(node), 'on_main_line': onMainLine(node)};
}

List<String> _colored(List<Move> moves) => [for (final m in moves) '${m.player}:${m.gtp()}'];

Object? _variationRegister(CommandHandler h, ApiArgs a) {
  final start = h.node(a, 'from');
  final moves = h.moves(a, start);
  checkMovesLegal(start, moves);
  final id = h.state.nextVariationId();
  h.state.variations[id] = RegisteredVariation(start, moves, a.text('label'));
  return {'id': id, 'from': nodeRef(start), 'moves': _colored(moves), 'label': a.text('label')};
}

Object? _variationList(CommandHandler h, ApiArgs a) => [
  for (final MapEntry(key: id, value: v) in h.state.variations.entries)
    {
      'id': id,
      'from': nodeRef(v.from),
      'moves': _colored(v.moves),
      'label': v.label,
      'current_game': identical(v.root, h.game.root),
    },
];

Object? _variationShow(CommandHandler h, ApiArgs a) {
  final id = a.text('id');
  final v = h.state.variations[id] ?? (throw ApiError('not_found', "no registered variation '$id'"));
  if (!identical(v.root, h.game.root)) throw ApiError('game_changed', 'this variation belongs to a different game');
  final step = a.integer('step', min: 1);
  if (a.text('as') == 'branch') {
    final (nodes, created) = h.addNodes(v.from, v.moves);
    h.goto(step == null ? nodes.last : nodes[(step < nodes.length ? step : nodes.length) - 1]);
    return {
      ...h.currentJson(a),
      'nodes': [for (final n in nodes) nodeRef(n)],
      ...h.editNotice(created),
    };
  }
  return showPv(h, v.from, v.moves, step);
}

// -- board display: variations, marks, region, view toggles

/// Overlays [moves] from [node] as numbered stones, without changing the game tree: the first [step] of them, or
/// all of them animated.
Map<String, Object?> showPv(CommandHandler h, GameNode node, List<Move> moves, [int? step]) {
  var expected = node.nextPlayer;
  for (final m in moves) {
    if (m.player != expected) {
      throw ApiError('bad_argument', 'PV display needs alternating colors starting with the player to move', {
        'hint': "use 'variation add' for sequences with tenuki/passes by one side",
      });
    }
    expected = Move.opponentPlayer(expected);
  }
  checkMovesLegal(node, moves);
  final cn = h.game.currentNode;
  if (!identical(node, cn) && !identical(node.parent, cn) && !cn.nodesFromRoot.any((n) => identical(n, node))) {
    h.goto(node); // the board can only hide stones of descendants of the variation's start
  }
  final pv = [for (final m in moves) m.gtp()];
  final shown = step == null ? pv.length : (step < pv.length ? step : pv.length);
  h.host.pv = PvOverlay(pv, node, index: step == null ? null : shown - 1, pinned: true);
  h.host.redrawOverlay();
  return {'from': nodeRef(node), 'pv': pv, 'shown_moves': shown, 'animated': step == null};
}

Object? _pvShow(CommandHandler h, ApiArgs a) {
  final node = h.node(a, 'from');
  final List<String> raw;
  final candidate = a.text('candidate')?.toUpperCase();
  if (candidate != null) {
    final pv = node.candidateMoves.where((c) => (c['move'] as String).toUpperCase() == candidate).firstOrNull?['pv'];
    if (pv is! List || pv.isEmpty) {
      throw ApiError('not_found', 'no analysed candidate $candidate with a PV at ${nodeRef(node)}', {
        'hint': 'run analysis.moves first',
      });
    }
    raw = pv.cast<String>();
  } else {
    raw = a.words('moves');
  }
  final moves = parseMoves(raw, node.boardSize, node.nextPlayer);
  if (moves.isEmpty) throw ApiError('bad_argument', 'give moves or candidate');
  return showPv(h, node, moves, a.integer('step', min: 1));
}

Object? _pvStep(CommandHandler h, ApiArgs a) {
  final pv = h.host.pv ?? (throw ApiError('no_pv', 'no PV is being shown'));
  final length = pv.moves.length;
  final shown = (a.integer('index') ?? (pv.index ?? length - 1) + 1 + a.integer('delta', orElse: 1)!).clamp(1, length);
  pv
    ..index = shown - 1
    ..pinned = true;
  h.host.redrawOverlay();
  return {'pv': pv.moves, 'shown_moves': shown, 'last_shown': pv.moves[shown - 1]};
}

Object? _pvHide(CommandHandler h, ApiArgs a) {
  h.host.pv = null;
  h.host.redrawOverlay();
  return {'hidden': true};
}

/// The colour asked for (red when none), and its name.
(List<double>, String) _markColor(ApiArgs a, String fallback) {
  final name = a.text('color', orElse: fallback)!;
  final rgb =
      parseMarkColor(name) ?? (throw ApiError('bad_argument', "unknown color '$name' (named color or #rrggbb)"));
  return (rgb, name);
}

Object? _markAdd(CommandHandler h, ApiArgs a) {
  final game = h.game;
  final kind = a.text('type', orElse: 'circle')!;
  final pointTypes = [
    for (final t in markTypes)
      if (t != 'area') t,
  ];
  if (!pointTypes.contains(kind)) throw ApiError('bad_argument', 'type must be one of ${pointTypes.join(', ')}');
  final (rgb, color) = _markColor(a, 'red');
  final points = a.words('points');
  if (points.isEmpty) throw ApiError('bad_argument', 'no points given');
  // one point takes the whole text as its label; several split it at spaces
  final texts = a['text'] is List || points.length > 1 ? a.words('text') : [?a.text('text')];
  final scope = a.text('scope') == 'global' ? null : nodeId(game.currentNode);
  final added = <Mark>[];
  for (var i = 0; i < points.length; i++) {
    final point = parseCoords(points[i], game.boardSize) ?? (throw ApiError('bad_coordinate', 'cannot mark pass'));
    final mark = Mark(
      id: h.state.nextMarkId(),
      type: kind,
      point: point,
      rgb: rgb,
      color: color,
      text: kind != 'label' ? null : (i < texts.length ? texts[i] : String.fromCharCode(0x41 + i % 26)),
      nodeId: scope,
    );
    // a mark replaces the one at the same point and scope
    h.state.marks = [
      for (final m in h.state.marks)
        if (m.point != point || m.nodeId != scope) m,
      mark,
    ];
    added.add(mark);
  }
  h.host.redrawOverlay();
  return {
    'added': [for (final m in added) m.toJson()],
  };
}

Object? _markArea(CommandHandler h, ApiArgs a) {
  final game = h.game;
  final (rgb, color) = _markColor(a, 'yellow');
  final mark = Mark(
    id: h.state.nextMarkId(),
    type: 'area',
    region: parseRegion(a.text('region', orElse: ''), game.boardSize),
    rgb: rgb,
    color: color,
    text: a.text('text'),
    nodeId: a.text('scope') == 'global' ? null : nodeId(game.currentNode),
  );
  h.state.marks = [...h.state.marks, mark];
  h.host.redrawOverlay();
  return {
    'added': [mark.toJson()],
  };
}

Object? _markList(CommandHandler h, ApiArgs a) => [for (final m in h.state.marks) m.toJson()];

Object? _markClear(CommandHandler h, ApiArgs a) {
  final before = h.state.marks.length;
  bool Function(Mark) keep;
  if (a.has('ids')) {
    final ids = {
      for (final i in a.words('ids'))
        int.tryParse(i.replaceFirst(RegExp(r'^#+'), '')) ?? (throw ApiError('bad_argument', 'bad mark id $i')),
    };
    keep = (m) => !ids.contains(m.id);
  } else if (a.has('points')) {
    final points = {for (final p in a.words('points')) parseCoords(p, h.game.boardSize)};
    keep = (m) => !points.contains(m.point);
  } else {
    keep = (_) => false;
  }
  h.state.marks = h.state.marks.where(keep).toList();
  h.host.redrawOverlay();
  return {'removed': before - h.state.marks.length, 'remaining': h.state.marks.length};
}

Object? _regionSet(CommandHandler h, ApiArgs a) {
  final game = h.game;
  game.setRegionOfInterest(parseRegion(a.text('region', orElse: ''), game.boardSize));
  h.refresh(false);
  return {'region_of_interest': regionJson(game.regionOfInterest)};
}

Object? _regionClear(CommandHandler h, ApiArgs a) {
  h.game.regionOfInterest = null;
  h.refresh(false);
  return {'region_of_interest': null};
}

Object? _viewSet(CommandHandler h, ApiArgs a) {
  final host = h.host;
  final changed = <String, Object?>{};
  for (final MapEntry(key: key, value: control) in viewToggles.entries) {
    if (a.hasFlag(key)) host.setAnalysisControl(control, changed[key] = a.flag(key));
  }
  if (a.hasFlag('move_numbers')) host.showMoveNumbers = changed['move_numbers'] = a.flag('move_numbers');
  if (a.hasFlag('zoom') || a.hasFlag('hide_frame')) {
    var zoom = host.zoomRegion;
    var hidden = host.hiddenCoords;
    final ts = h.state.tsumego;
    if (a.hasFlag('zoom')) {
      final spec = (a.text('zoom') ?? '').trim().toLowerCase();
      zoom = switch (spec) {
        '' || 'off' || 'false' || 'none' => null,
        'auto' =>
          ts?.viewRegion ??
              (throw ApiError('no_tsumego', 'zoom=auto needs a loaded tsumego problem; give a region like C3:G7')),
        _ => parseRegion(spec.toUpperCase(), h.game.boardSize),
      };
    }
    if (a.hasFlag('hide_frame')) hidden = a.flag('hide_frame') ? (ts?.frameCoords ?? {}) : {};
    host.setZoom(zoom, hidden);
    changed['zoom'] = regionJson(zoom);
    changed['hidden_stones'] = hidden.length;
  }
  h.refresh();
  return {
    'changed': changed,
    'view': {
      for (final MapEntry(key: key, value: control) in viewToggles.entries) key: host.analysisControl(control),
      'move_numbers': host.showMoveNumbers,
      'zoom': regionJson(host.zoomRegion),
      'hidden_stones': host.hiddenCoords.length,
    },
  };
}

Object? _modeSet(CommandHandler h, ApiArgs a) {
  final mode = a.text('mode');
  if (mode != modePlay && mode != modeAnalyze) {
    throw ApiError('bad_argument', "mode must be '$modePlay' or '$modeAnalyze'");
  }
  h.setMode(mode!);
  return {'mode': h.host.mode};
}

Object? _message(CommandHandler h, ApiArgs a) {
  final text = a.text('text', orElse: '')!;
  final shown = text.length > 300 ? text.substring(0, 300) : text;
  h.host.showStatus(shown);
  return {'shown': shown};
}

// -- saved states and demos

Object? _stateSave(CommandHandler h, ApiArgs a) {
  final name = a.text('name', orElse: 'default')!;
  return (h.state.snapshots[name] = h.capture()).toJson(name);
}

Object? _stateRestore(CommandHandler h, ApiArgs a) {
  final name = a.text('name', orElse: 'default')!;
  final snap =
      h.state.snapshots[name] ??
      (throw ApiError('not_found', "no saved state '$name'", {'available': h.state.snapshots.keys.toList()..sort()}));
  h.restore(snap);
  return {'restored': name, ...h.currentJson(a)};
}

Object? _stateList(CommandHandler h, ApiArgs a) => [
  for (final MapEntry(key: name, value: snap) in h.state.snapshots.entries) snap.toJson(name),
];

Object? _demoStart(CommandHandler h, ApiArgs a) {
  if (h.state.demo != null) throw ApiError('demo_active', 'a demo is already running', {'hint': 'demo end first'});
  h.state.demo = Demo(h.capture(), h.game.root.nodesInTree, a.text('label'));
  h.setMode(modeAnalyze); // no AI replies or teaching undos while demonstrating
  return {'demo': 'started', 'label': a.text('label'), ...h.currentJson(a)};
}

Object? _demoEnd(CommandHandler h, ApiArgs a) {
  final demo = h.state.demo ?? (throw ApiError('no_demo', 'no demo is running'));
  h.state.demo = null;
  h.host.pv = null;
  final game = h.game;
  if (!identical(game.root, demo.snapshot.root)) {
    return {'demo': 'ended', 'warning': 'a different game was loaded during the demo; nothing restored'};
  }
  var removed = 0;
  final keep = a.flag('keep');
  if (!keep) {
    for (final n in game.root.nodesInTree) {
      if (!demo.existing.contains(n) && demo.existing.contains(n.parent)) removed += h.removeSubtree(n);
    }
  }
  h.restore(demo.snapshot);
  return {'demo': 'ended', 'removed_nodes': removed, 'kept': keep, ...h.currentJson(a)};
}

Object? _demoStatus(CommandHandler h, ApiArgs a) {
  final demo = h.state.demo;
  if (demo == null) return {'active': false};
  return {
    'active': true,
    'label': demo.label,
    'started_at': nodeRef(demo.snapshot.node),
    'added_nodes': h.game.root.nodesInTree.where((n) => !demo.existing.contains(n)).length,
  };
}

final Map<String, ApiCommand> _coreCommands = {
  'commands': const ApiCommand(_commands, 'List available API commands.'),
  'status': ApiCommand((h, a) => status(h), 'Game info, current node, mode, engine state, demo state.'),
  'board': ApiCommand(
    (h, a) => boardJson(h.node(a), asciiBoard: a.flag('ascii', orElse: true)),
    'Stones on the board at a node (default: current).',
  ),
  'node': ApiCommand(
    (h, a) => nodeJson(h.node(a), detail: true),
    'Details of one node: move, children, comments, properties, evaluation.',
  ),
  'history': const ApiCommand(
    _history,
    'Moves from the root to a node; with future=true continue to the end of the line.',
  ),
  'tree': const ApiCommand(_tree, 'Game tree with variations (linear stretches collapsed).'),
  'variations': const ApiCommand(
    _variations,
    'Alternatives at a node (its children) and the branch points on its line.',
  ),
  'sgf.export': const ApiCommand(
    _sgfExport,
    "Export the game as SGF text, or write it to 'path' (refuses to overwrite unless overwrite=true).",
  ),
  'sgf.import': const ApiCommand(
    _sgfImport,
    'Load an SGF (path or content) into the GUI. The previous game is backed up first.',
  ),
  'game.new': const ApiCommand(
    _gameNew,
    'Start a new empty game (size, komi, rules, handicap). The previous game is backed up first.',
  ),
  'analysis.get': const ApiCommand(_analysisGet, 'Analysis KaTrain already has for a node (no new search).'),
  'analysis.run': const ApiCommand(
    _analysisRun,
    'Search a node to `visits` (reuses existing results if already deep enough) and return the analysis.',
    waitsForEngine: true,
  ),
  'analysis.moves': const ApiCommand(
    _analysisMoves,
    'Search specific candidate moves at a node and compare them (points lost, PV).',
    waitsForEngine: true,
  ),
  'analysis.game': const ApiCommand(
    _analysisGame,
    'Queue whole-game (re)analysis in the background; poll with analysis.wait or status.',
  ),
  'analysis.wait': const ApiCommand(
    _analysisWait,
    'Wait until the engine has no pending queries (not while pondering).',
    waitsForEngine: true,
  ),
  'analysis.ponder': const ApiCommand(_analysisPonder, 'Turn continuous analysis of the current position on or off.'),
  'analysis.stop': const ApiCommand(_analysisStop, 'Stop pondering and cancel all pending KataGo queries.'),
  'engine.get': const ApiCommand(_engineGet, 'Current search settings.'),
  'engine.set': const ApiCommand(
    _engineSet,
    'Change search settings (max_visits, fast_visits, max_time, wide_root_noise); save=true persists them.',
  ),
  'nav.goto': const ApiCommand(_goto, 'Jump to a node (move number, n<ID>, main:<N>, root, end).'),
  'nav.next': ApiCommand((h, a) => _step(h, a, forward: true), 'Step forward n moves along the current line.'),
  'nav.prev': ApiCommand((h, a) => _step(h, a, forward: false), 'Step back n moves.'),
  'nav.branch': const ApiCommand(
    _branch,
    'Switch to the next (direction=1) or previous (-1) sibling variation, or a given index.',
  ),
  'play': const ApiCommand(
    _play,
    'Play moves from the current node (adds them to the game tree, analyzed like GUI moves).',
  ),
  'variation.add': const ApiCommand(
    _variationAdd,
    'Add a variation below a node without validating against the GUI state; goto=true jumps to its end.',
  ),
  'variation.delete': const ApiCommand(
    _variationDelete,
    'Delete a node and everything below it. Nodes not created via the API need force=true.',
  ),
  'variation.promote': const ApiCommand(_variationPromote, 'Make the line through a node the main line.'),
  'variation.register': const ApiCommand(
    _variationRegister,
    'Register a variation (moves from a node) under a short id like v1, without touching the board.',
  ),
  'variation.list': const ApiCommand(_variationList, 'Registered variations.'),
  'variation.show': const ApiCommand(
    _variationShow,
    'Show a registered variation: as=pv (overlay, default) or as=branch (creates nodes, goes to step).',
  ),
  'pv.show': const ApiCommand(
    _pvShow,
    "Overlay a variation as numbered stones (moves=..., or candidate=<move> to use KataGo's PV). step=N shows N "
    'moves.',
  ),
  'pv.step': const ApiCommand(_pvStep, 'Step the shown PV: delta=+1/-1, or index=N (number of moves shown).'),
  'pv.hide': const ApiCommand(_pvHide, 'Remove the PV overlay.'),
  'mark.add': const ApiCommand(
    _markAdd,
    'Mark points: type=circle|square|triangle|cross|label|dot, text for labels, color, scope=node|global.',
  ),
  'mark.area': const ApiCommand(
    _markArea,
    'Highlight a rectangular area, e.g. region=C3:G7, with optional label text and color.',
  ),
  'mark.list': const ApiCommand(_markList, 'All API marks.'),
  'mark.clear': const ApiCommand(_markClear, 'Remove marks: all (default), ids=[...], or points=[...].'),
  'region.set': const ApiCommand(
    _regionSet,
    "Restrict KataGo's candidate moves to a region (KaTrain's region of interest), e.g. C3:G7.",
  ),
  'region.clear': const ApiCommand(_regionClear, 'Remove the region of interest.'),
  'view.set': const ApiCommand(
    _viewSet,
    'Toggle display layers: hints, ownership, policy, eval, children, move_numbers (true/false); '
    'zoom=C3:G7|auto|off',
  ),
  'mode.set': const ApiCommand(_modeSet, 'Switch between play and analyze mode.'),
  'message': const ApiCommand(_message, "Show a short line in KaTrain's status bar."),
  'state.save': const ApiCommand(
    _stateSave,
    'Remember the current position, mode, region, marks, shown PV and status text; returns a katrain:// link.',
  ),
  'state.restore': const ApiCommand(_stateRestore, 'Return to a saved state.'),
  'state.list': const ApiCommand(_stateList, 'Saved states.'),
  'demo.start': const ApiCommand(
    _demoStart,
    'Begin a temporary demonstration: everything added until demo.end is removed again (unless keep=true).',
  ),
  'demo.end': const ApiCommand(
    _demoEnd,
    'End the demo: drop nodes added during it (keep=true keeps them) and restore the saved position.',
  ),
  'demo.status': const ApiCommand(_demoStatus, 'Whether a demo is running and where it started.'),
};
