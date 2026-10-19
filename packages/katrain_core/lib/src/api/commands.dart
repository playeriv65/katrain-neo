// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/api/commands.py: the
// commands of the local API, run in the app. Commands that wait for KataGo (`waitsForEngine`) await its results;
// the app stays responsive meanwhile.

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
import '../utils/py_format.dart';
import 'model.dart';
import 'overlay.dart';
import 'protocol.dart';
import 'sandbox.dart';
import 'tsumego.dart';

const backgroundPriority = -50; // below KaTrain's interactive queries (PRIORITY_DEFAULT=1000), above re-analysis
const engineSettings = {'max_visits': int, 'fast_visits': int, 'max_time': double, 'wide_root_noise': double};
const viewToggles = {
  'hints': 'hints',
  'ownership': 'ownership',
  'policy': 'policy',
  'eval': 'eval',
  'children': 'show_children',
};

typedef ApiArgs = Map<String, dynamic>;
typedef CommandFn = FutureOr<Object?> Function(CommandHandler h, ApiArgs a);

/// A command: what it does, its help line, and whether it waits for KataGo.
class ApiCommand {
  final CommandFn fn;
  final String help;
  final bool waitsForEngine;
  const ApiCommand(this.fn, this.help, {this.waitsForEngine = false});
}

/// A principal variation drawn over the board (KaTrain's `animating_pv`); [pinned] for one shown through the API,
/// which survives mouse hovers.
class ApiPv {
  final List<String> moves;
  final GameNode node;
  int? index;
  bool pinned;
  ApiPv(this.moves, this.node, {this.index, this.pinned = false});
}

/// What the commands use of the app (KaTrain's GUI object and its widgets).
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

  /// KaTrain's `update_state`.
  void updateState({bool redrawBoard = false});

  /// Redraws the hover layer (PV, marks).
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

  /// KaTrain's `_do_new_game`.
  void newGame(GameNode moveTree, {bool analyzeFast = false, String? sgfFilename});

  /// KaTrain's `_do_tsumego_frame`.
  void tsumegoFrame(bool ko, int margin);

  ApiPv? get pv;
  set pv(ApiPv? value);

  bool analysisControl(String key);
  void setAnalysisControl(String key, bool value);
  bool get showMoveNumbers;
  set showMoveNumbers(bool value);

  /// The zoomed part of the board `[xmin, xmax, ymin, ymax]`, and stones not drawn (a hidden tsumego frame).
  List<int>? get zoomRegion;
  Set<(int, int)> get hiddenCoords;
  void setZoom(List<int>? region, [Set<(int, int)> hidden = const {}]);
}

/// Python's truth value of a JSON argument (`if a.get(key)`, `a.get(key) or default`).
bool truthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is List) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

/// The API's `_bool`: strings count as true only for 1/true/yes/on.
bool apiBool(Object? v, [bool defaultValue = false]) {
  if (v == null) return defaultValue;
  if (v is String) return const ['1', 'true', 'yes', 'on'].contains(v.trim().toLowerCase());
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is List) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

/// Python's `int(v)`.
int? _pyIntOrNull(Object? v) {
  if (v is bool) return v ? 1 : 0;
  if (v is int) return v;
  if (v is double) return v.isFinite ? v.truncate() : null;
  if (v is String) return int.tryParse(v.trim().replaceAll('_', ''));
  return null;
}

int? apiInt(ApiArgs a, String key, {int? defaultValue, int? minimum}) {
  final v = a[key];
  if (v == null || v == '') return defaultValue;
  final i = _pyIntOrNull(v);
  if (i == null) throw ApiError('bad_argument', "'$key' must be an integer, got ${pyRepr(v)}");
  if (minimum != null && i < minimum) throw ApiError('bad_argument', "'$key' must be >= $minimum");
  return i;
}

/// Python's `float(v)`.
double? _pyFloatOrNull(Object? v) {
  if (v is bool) return v ? 1 : 0;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// Python's `urllib.parse.quote(text, safe='')`.
String pyQuote(String text) {
  final out = StringBuffer();
  for (final b in utf8.encode(text)) {
    final c = String.fromCharCode(b);
    if (RegExp(r'[A-Za-z0-9_.\-~]').hasMatch(c)) {
      out.write(c);
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

String _isoSeconds(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:'
    '${_two(t.second)}';
String _two(int v) => v.toString().padLeft(2, '0');

/// API-side state kept by the app (marks, snapshots, demo, registered variations, tsumego, sandboxes).
class ApiState {
  List<Map<String, Object?>> marks = [];
  int _markId = 1;
  final Map<String, Map<String, Object?>> snapshots = {};
  Map<String, Object?>? demo;
  final Set<GameNode> created = Set.identity(); // nodes created through the API
  final Map<String, Map<String, Object?>> variations = {};
  int _variationId = 1;
  TsumegoState? tsumego;
  final Map<String, Sandbox> sandboxes = {};

  int nextMarkId() => _markId++;
  int nextVariationId() => _variationId++;
}

List<Map<String, Object?>> _copyMarks(List<Map<String, Object?>> marks) => [
  for (final m in marks) {for (final MapEntry(:key, :value) in m.entries) key: value is List ? List.of(value) : value},
];

/// Every command, by name.
final Map<String, ApiCommand> apiCommands = {..._coreCommands, ...tsumegoCommands, ...sandboxCommands};

class CommandHandler {
  final ApiHost host;
  final ApiState state;

  /// Where previous games are backed up before an import replaces them.
  final String dataFolder;
  CommandHandler(this.host, this.state, {String? dataFolder}) : dataFolder = dataFolder ?? expandUser(neoDataFolder);

  // -- plumbing

  Future<Object?> dispatch(String name, ApiArgs args) async {
    final entry = apiCommands[name];
    if (entry == null) {
      throw ApiError('unknown_command', "unknown command '$name'", {'available': apiCommands.keys.toList()..sort()});
    }
    return await entry.fn(this, args);
  }

  Game get game {
    final g = host.game;
    if (g == null) throw ApiError('no_game', 'no game loaded');
    return g;
  }

  GameNode node(ApiArgs a, [String key = 'node']) => resolveNode(game, a[key]);

  AnalysisEngine<GameNode> engineFor(GameNode node) {
    final engine = game.engines[node.nextPlayer];
    if (engine == null || !host.engineAlive(engine)) {
      throw ApiError('engine_unavailable', 'KataGo engine is not running', {'hint': 'check the engine status dot'});
    }
    return engine;
  }

  void refresh([bool redraw = true]) {
    host.updateState(redrawBoard: redraw);
    host.redrawOverlay();
  }

  void goto(GameNode node) {
    final g = game;
    if (g.insertMode) throw ApiError('insert_mode', "finish KaTrain's insert mode before navigating");
    host.pv = null;
    g.setCurrentNode(node);
    refresh();
  }

  Map<String, Object?> currentJson([ApiArgs? a]) {
    final out = <String, Object?>{'current': nodeJson(game.currentNode)};
    if (a != null && apiBool(a['board'])) out['board'] = boardJson(game.currentNode);
    return out;
  }

  void setMode(String mode) {
    if (host.mode != mode) host.selectMode(mode);
  }

  /// Creates (or reuses) nodes for [moves] below [start]. Returns the nodes and how many were created.
  (List<GameNode>, int) addNodes(GameNode start, List<Move> moves, {String analyze = 'fast'}) {
    checkMovesLegal(start, moves);
    var node = start;
    final nodes = <GameNode>[];
    var created = 0;
    for (final move in moves) {
      GameNode? existing;
      for (final c in node.children) {
        if (c.move == move) {
          existing = c;
          break;
        }
      }
      node = existing ?? node.play(move);
      if (existing == null) {
        nodeId(node); // number new nodes in move order
        created += 1;
        state.created.add(node);
        if (analyze != 'none') {
          node.analyze(game.engines[node.nextPlayer]!, analyzeFast: analyze == 'fast');
        }
      }
      nodes.add(node);
    }
    return (nodes, created);
  }

  Map<String, Object?> editNotice(int created) {
    if (created > 0 && state.demo == null) {
      return {
        'game_modified': true,
        'hint': "moves were added to the game record; use 'demo start' for throwaway lines",
      };
    }
    return {'game_modified': created > 0, 'in_demo': state.demo != null};
  }

  // -- snapshots

  Map<String, Object?> capture() {
    final g = game;
    final p = host.pv;
    Map<String, Object?>? pv;
    if (p != null && p.pinned) pv = {'moves': List.of(p.moves), 'node': p.node, 'index': p.index};
    return {
      'root': g.root,
      'node': g.currentNode,
      'mode': host.mode,
      'region': g.regionOfInterest == null ? null : List.of(g.regionOfInterest!),
      'marks': _copyMarks(state.marks),
      'pv': pv,
      'message': host.statusMessage,
      'time': DateTime.now(),
    };
  }

  void restore(Map<String, Object?> snap) {
    final g = game;
    if (!identical(g.root, snap['root'])) {
      throw ApiError('game_changed', 'the snapshot belongs to a different game than the one loaded');
    }
    var node = snap['node'] as GameNode;
    final tree = Set<GameNode>.identity()..addAll(g.root.nodesInTree);
    while (!tree.contains(node) && node.parent != null) {
      node = node.parent!;
    }
    state.marks = _copyMarks(snap['marks'] as List<Map<String, Object?>>);
    goto(node);
    final region = snap['region'] as List<int>?;
    g.regionOfInterest = region == null ? null : List.of(region);
    setMode(snap['mode'] as String);
    final pv = snap['pv'] as Map<String, Object?>?;
    if (pv != null && tree.contains(pv['node'])) {
      host.pv = ApiPv(pv['moves'] as List<String>, pv['node'] as GameNode, index: pv['index'] as int?, pinned: true);
    }
    host.showStatus((snap['message'] as String?) ?? '');
    refresh();
  }

  static Map<String, Object?> snapshotJson(String name, Map<String, Object?> snap) {
    final node = snap['node'] as GameNode;
    final pv = snap['pv'] as Map<String, Object?>?;
    final message = snap['message'] as String?;
    return {
      'name': name,
      'node': nodeRef(node),
      'move_number': node.depth,
      'mode': snap['mode'],
      'marks': (snap['marks'] as List).length,
      'pv': pv?['moves'],
      'message': message == null || message.isEmpty ? null : message,
      'link': 'katrain://state/${pyQuote(name)}',
      'saved': _isoSeconds(snap['time'] as DateTime),
    };
  }

  // -- analysis plumbing

  /// Sends one KataGo query, feeds the results into the node as the GUI does, and waits for the final one.
  ///
  /// [background] is for sandbox positions the user cannot see: below the GUI's own queries in priority, no
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
        if (!done.isCompleted) {
          done.completeError(ApiError('engine_error', pyStr(result.containsKey('error') ? result['error'] : result)));
        }
      },
      visits: visits,
      timeLimit: false,
      nextMove: refineMove,
      regionOfInterest: region,
      priority: background ? backgroundPriority : priorityExtraAnalysis,
      reportEvery: (refineMove != null || background) ? null : reportDt.toDouble(),
      extraSettings: maxTime != null && maxTime != 0 ? {'maxTime': maxTime} : null,
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

// -- meta / reading

Object? _cmdCommands(CommandHandler h, ApiArgs a) => {
  for (final name in apiCommands.keys.toList()..sort())
    name: {'help': apiCommands[name]!.help, 'waits_for_engine': apiCommands[name]!.waitsForEngine},
};

String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

Map<String, Object?> cmdStatus(CommandHandler h, ApiArgs a) {
  final host = h.host, game = h.game;
  final root = game.root, cn = game.currentNode;
  final engine = host.engine;
  final players = <String, Object?>{};
  for (final bw in const ['B', 'W']) {
    final info = host.playersInfo[bw]!;
    final name = root.getProperty('P$bw');
    players[bw] = {
      'name': name != null && name.isNotEmpty ? name : (info.name.isNotEmpty ? info.name : null),
      'rank': root.getProperty('${bw}R'),
      'type': info.playerType,
      'subtype': info.playerSubtype,
    };
  }
  Map<String, Object?>? engineInfo;
  if (engine != null) {
    engineInfo = {
      'alive': host.engineAlive(engine),
      'idle': host.engineIdle(engine),
      'queries_remaining': host.engineQueriesRemaining(engine),
      'model': _basename(pyStr(engine.config['model'] ?? '')),
      for (final key in engineSettings.keys) key: engine.config[key],
    };
  }
  final demo = h.state.demo;
  final ts = h.state.tsumego;
  return {
    'game': {
      'board_size': [game.boardSize.$1, game.boardSize.$2],
      'komi': game.komi,
      'rules': root.ruleset,
      'handicap': root.handicap,
      'players': players,
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
    'engine': engineInfo,
    'demo': demo == null
        ? null
        : {'started_at': nodeRef((demo['snapshot'] as Map)['node'] as GameNode), 'label': demo['label']},
    'pv_shown': host.pv != null,
    'marks': h.state.marks.length,
    'tsumego': ts?.summary(),
  };
}

Object? _cmdBoard(CommandHandler h, ApiArgs a) => boardJson(h.node(a), asciiBoard: apiBool(a['ascii'], true));

Object? _cmdNode(CommandHandler h, ApiArgs a) => nodeJson(h.node(a), detail: true);

Object? _cmdHistory(CommandHandler h, ApiArgs a) {
  final node = h.node(a);
  final nodes = apiBool(a['future']) ? lineNodes(node) : node.nodesFromRoot;
  final withEval = apiBool(a['eval'], true);
  final cur = h.game.currentNode;
  final out = <Map<String, Object?>>[];
  for (final n in nodes) {
    final entry = nodeJson(n, withEval: withEval);
    if (identical(n, cur)) entry['current'] = true;
    if (n.children.length > 1) entry['variations'] = n.children.length;
    out.add(entry);
  }
  return {'node': nodeRef(node), 'nodes': out};
}

Object? _cmdTree(CommandHandler h, ApiArgs a) {
  final start = resolveNode(h.game, truthy(a['node']) ? a['node'] : 'root');
  return {'current': nodeRef(h.game.currentNode), 'tree': treeJson(start, apiInt(a, 'max_depth'))};
}

Object? _cmdVariations(CommandHandler h, ApiArgs a) {
  final node = h.node(a);
  final branchPoints = <Map<String, Object?>>[];
  for (final n in lineNodes(node)) {
    if (n.children.length > 1) {
      branchPoints.add({
        'node': nodeRef(n),
        'move_number': n.depth,
        'branches': [for (final c in n.orderedChildren) branchJson(c, 8)],
      });
    }
  }
  final siblings = node.parent != null ? node.parent!.orderedChildren : [node];
  return {
    'node': nodeRef(node),
    'children': [for (final c in node.orderedChildren) branchJson(c, apiInt(a, 'max_len', defaultValue: 20))],
    'siblings': [for (final s in siblings) nodeRef(s)],
    'sibling_index': siblings.indexWhere((s) => identical(s, node)),
    'branch_points_on_line': branchPoints,
  };
}

// -- SGF

String _stamp(DateTime t) =>
    '${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}_'
    '${(t.millisecond * 1000 + t.microsecond).toString().padLeft(6, '0')}';

/// Saves the current game before replacing it, so nothing is lost by an API import.
String? _backupGame(CommandHandler h) {
  final game = h.game;
  if (game.root.nodesInTree.length <= 1) return null;
  final folder = Directory('${h.dataFolder}${Platform.pathSeparator}api_backups')..createSync(recursive: true);
  final path = '${folder.path}${Platform.pathSeparator}backup_${_stamp(DateTime.now())}.sgf';
  File(path).writeAsStringSync(game.root.sgf());
  return path;
}

String? loadTree(CommandHandler h, GameNode moveTree, {bool fast = false, bool atEnd = false, String? sgfFilename}) {
  final backup = _backupGame(h);
  h.state.demo = null;
  h.state.marks = [];
  h.state.tsumego = null;
  h.host.setZoom(null);
  h.host.newGame(moveTree, analyzeFast: fast, sgfFilename: sgfFilename);
  if (atEnd) h.game.redo(9999);
  h.refresh();
  return backup;
}

String _absolute(String path) => absPath(path);

Object? _cmdSgfExport(CommandHandler h, ApiArgs a) {
  final game = h.game;
  final trainer = ((h.host.config('trainer', const {}) as Map?) ?? const {}).cast<String, dynamic>();
  final comments = apiBool(a['comments']);
  final sgf = game.root.sgf(
    SgfSaveOptions(
      saveCommentsPlayer: comments ? const {'B': true, 'W': true} : null,
      saveCommentsClass: comments ? (trainer['save_feedback'] as List?)?.cast<bool>() : null,
      evalThresholds: (trainer['eval_thresholds'] as List?)?.cast<num>(),
      saveAnalysis: apiBool(a['analysis']),
      saveMarks: apiBool(a['marks']),
    ),
  );
  final pathArg = a['path'];
  if (!truthy(pathArg)) return {'sgf': sgf};
  final path = _absolute(pyStr(pathArg));
  final file = File(path);
  if (file.existsSync() && !apiBool(a['overwrite'])) {
    throw ApiError('file_exists', '$path exists', {'hint': 'pass overwrite=true to replace it'});
  }
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(sgf);
  return {'path': path, 'bytes': utf8.encode(sgf).length};
}

Object? _cmdSgfImport(CommandHandler h, ApiArgs a) {
  final fast = apiBool(a['fast']), atEnd = apiBool(a['at_end']);
  GameNode tree;
  String? filename;
  try {
    if (truthy(a['content'])) {
      tree = gameParser.parseSgf(pyStr(a['content']));
    } else if (truthy(a['path'])) {
      filename = _absolute(pyStr(a['path']));
      tree = gameParser.parseBytes(File(filename).readAsBytesSync(), fileName: filename);
    } else {
      throw ApiError('bad_argument', "give 'path' or 'content'");
    }
  } on ApiError {
    rethrow;
  } on Object catch (e) {
    throw ApiError('sgf_parse_error', 'could not read SGF: $e');
  }
  final backup = loadTree(h, tree, fast: fast, atEnd: atEnd, sgfFilename: filename);
  return {'loaded': filename ?? '<content>', 'previous_game_backup': backup, ...cmdStatus(h, {})};
}

Object? _cmdGameNew(CommandHandler h, ApiArgs a) {
  final host = h.host;
  final size = pyStr(truthy(a['size']) ? a['size'] : host.config('game/size'));
  final komi = a.containsKey('komi') ? a['komi'] : host.config('game/komi');
  final rules = truthy(a['rules']) ? a['rules'] : host.config('game/rules');
  final tree = gameParser.parseSgf('(;GM[1]FF[4]SZ[$size]KM[${pyStr(komi)}]RU[${pyStr(rules)}])');
  final handicap = apiInt(a, 'handicap', defaultValue: 0)!;
  if (handicap != 0) {
    tree.setProperty('HA', handicap);
    tree.placeHandicapStones(handicap);
  }
  final backup = loadTree(h, tree);
  return {'previous_game_backup': backup, ...cmdStatus(h, {})};
}

// -- analysis

({int? top, bool includePv, int? pvLimit, bool ownership, bool policy}) _analysisArgs(ApiArgs a) => (
  top: apiInt(a, 'top', defaultValue: 10),
  includePv: apiBool(a['pv'], true),
  pvLimit: apiInt(a, 'pv_limit'),
  ownership: apiBool(a['ownership']),
  policy: apiBool(a['policy']),
);

Map<String, Object?> _analysisView(GameNode node, ApiArgs a, {List<String>? moves, bool allMoves = false}) {
  final v = _analysisArgs(a);
  return analysisJson(
    node,
    top: allMoves ? null : v.top,
    includePv: v.includePv,
    pvLimit: v.pvLimit,
    ownership: v.ownership,
    policy: v.policy,
    moves: moves,
  );
}

Object? _cmdAnalysisGet(CommandHandler h, ApiArgs a) {
  final moves = a['moves'];
  return _analysisView(h.node(a), a, moves: truthy(moves) ? (moves as List).cast<String>() : null);
}

Future<Object?> _cmdAnalysisRun(CommandHandler h, ApiArgs a) async {
  final timeout = apiInt(a, 'timeout', defaultValue: 300, minimum: 1)!;
  final node = h.node(a);
  final engine = h.engineFor(node);
  final visits = apiInt(a, 'visits', defaultValue: engine.config['max_visits'] as int, minimum: 1)!;
  List<int>? region;
  final regionArg = a['region'];
  if (regionArg == 'gui') {
    region = h.game.regionOfInterest;
  } else if (truthy(regionArg)) {
    region = parseRegion(regionArg, node.boardSize);
  }
  final cached =
      !apiBool(a['force']) &&
      (region == null || region.isEmpty) &&
      node.analysisComplete &&
      node.rootVisits >= 0.95 * visits; // requested visits may have been cut short by max_time
  if (!cached) {
    if (!apiBool(a['wait'], true)) {
      node.analyze(engine, visits: visits, priority: priorityExtraAnalysis, timeLimit: false, regionOfInterest: region);
      return {'queued': true, 'node': nodeRef(node), 'visits': visits};
    }
    if (region != null && region.isNotEmpty && !node.analysisExists) {
      // region results don't carry a root evaluation
      final fast = engine.config['fast_visits'] as int?;
      await h.search(node, engine, fast != null && fast != 0 ? fast : 25, timeout: timeout);
    }
    final maxTime = truthy(a['max_time']) ? _pyFloatOrNull(a['max_time']) : null;
    await h.search(node, engine, visits, region: region, timeout: timeout, maxTime: maxTime);
  }
  final result = _analysisView(node, a);
  result.addAll({'reused_existing': cached, 'requested_visits': visits, 'region': regionJson(region)});
  return result;
}

Future<Object?> _cmdAnalysisMoves(CommandHandler h, ApiArgs a) async {
  final timeout = apiInt(a, 'timeout', defaultValue: 300, minimum: 1)!;
  final node = h.node(a);
  final engine = h.engineFor(node);
  final visits = apiInt(a, 'visits', defaultValue: engine.config['max_visits'] as int, minimum: 1)!;
  final raw = a['moves'] ?? const [];
  final names = raw is String ? splitWords(raw) : [for (final m in raw as List) m];
  if (names.isEmpty) throw ApiError('bad_argument', 'give at least one move to compare');
  final moves = [for (final m in names) Move(coords: parseCoords(m, node.boardSize), player: node.nextPlayer)];
  for (final m in moves) {
    checkMovesLegal(node, [m]);
  }
  if (!node.analysisExists) await h.search(node, engine, visits, timeout: timeout);
  final errors = <String, Object?>{};
  await Future.wait([
    for (final move in moves)
      h
          .search(node, engine, visits, refineMove: move, timeout: timeout)
          .then<void>(
            (_) {},
            onError: (Object e) {
              if (e is! ApiError) throw e;
              errors[move.gtp()] = e.toJson();
            },
          ),
  ]);
  final result = _analysisView(node, a, moves: [for (final m in moves) m.gtp()], allMoves: true);
  mergeSortBy(result['candidates'] as List<Map<String, Object?>>, (c) => (c['points_lost'] as num?) ?? 1e9);
  result['compared_visits'] = visits;
  if (errors.isNotEmpty) result['errors'] = errors;
  return result;
}

Object? _cmdAnalysisGame(CommandHandler h, ApiArgs a) {
  final kwargs = <String, Object?>{'mistakes_only': apiBool(a['mistakes_only'])};
  if (truthy(a['visits'])) kwargs['visits'] = apiInt(a, 'visits', minimum: 1);
  if (truthy(a['move_range'])) {
    final parts = pyStr(a['move_range']).replaceAll(':', '-').split('-');
    if (parts.length != 2) throw ApiError('bad_argument', 'move_range must look like 20-60');
    kwargs['move_range'] = [for (final p in parts) int.parse(p.trim())];
  }
  h.engineFor(h.game.currentNode);
  h.game.analyzeExtra(
    'game',
    mistakesOnly: kwargs['mistakes_only'] as bool,
    visits: kwargs['visits'] as int?,
    moveRange: kwargs['move_range'] as List<int>?,
  );
  return {'queued': true, ...kwargs, 'queries_remaining': h.host.engineQueriesRemaining(h.host.engine!)};
}

Future<Object?> _cmdAnalysisWait(CommandHandler h, ApiArgs a) async {
  final timeout = apiInt(a, 'timeout', defaultValue: 300, minimum: 1)!;
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

Object? _cmdAnalysisPonder(CommandHandler h, ApiArgs a) {
  final on = apiBool(a['on'], true);
  if (on != h.host.pondering) h.host.toggleContinuousAnalysis(quiet: true);
  return {'pondering': h.host.pondering};
}

Object? _cmdAnalysisStop(CommandHandler h, ApiArgs a) {
  h.game.analyzeExtra('stop');
  h.refresh(false);
  return {'stopped': true};
}

Map<String, Object?> _cmdEngineGet(CommandHandler h, ApiArgs a) {
  final engineConfig = h.host.config('engine') as Map;
  return {for (final key in engineSettings.keys) key: engineConfig[key]};
}

Object? _cmdEngineSet(CommandHandler h, ApiArgs a) {
  final engineConfig = h.host.config('engine') as Map;
  final changed = <String, Object?>{};
  for (final MapEntry(key: key, value: type) in engineSettings.entries) {
    if (a[key] == null) continue;
    final num? value = type == int ? _pyIntOrNull(a[key]) : _pyFloatOrNull(a[key]);
    if (value == null) throw ApiError('bad_argument', '$key must be ${type == int ? 'int' : 'float'}');
    if (value < 0) throw ApiError('bad_argument', '$key must be >= 0');
    engineConfig[key] = value;
    final engine = h.host.engine;
    if (engine != null && !identical(engine.config, engineConfig)) engine.config[key] = value;
    changed[key] = value;
  }
  if (changed.isEmpty) {
    throw ApiError('bad_argument', 'nothing to change, use one of ${pyRepr(engineSettings.keys.toList()..sort())}');
  }
  if (apiBool(a['save'])) h.host.saveConfig('engine');
  return {'changed': changed, 'saved': apiBool(a['save']), ..._cmdEngineGet(h, {})};
}

// -- navigation and editing

Object? _cmdGoto(CommandHandler h, ApiArgs a) {
  h.goto(h.node(a));
  return h.currentJson(a);
}

void _checkNotInserting(CommandHandler h) {
  if (h.game.insertMode) throw ApiError('insert_mode', "finish KaTrain's insert mode before navigating");
}

Object? _cmdNext(CommandHandler h, ApiArgs a) {
  _checkNotInserting(h);
  h.host.pv = null;
  h.game.redo(apiInt(a, 'n', defaultValue: 1, minimum: 1)!);
  h.refresh();
  return h.currentJson(a);
}

Object? _cmdPrev(CommandHandler h, ApiArgs a) {
  _checkNotInserting(h);
  h.host.pv = null;
  h.game.undo(apiInt(a, 'n', defaultValue: 1, minimum: 1)!);
  h.refresh();
  return h.currentJson(a);
}

Object? _cmdBranch(CommandHandler h, ApiArgs a) {
  final cn = h.game.currentNode;
  if (cn.parent == null) throw ApiError('no_variation', 'the root has no siblings');
  final siblings = cn.parent!.orderedChildren;
  final idx = a['index'] != null
      ? apiInt(a, 'index')!
      : siblings.indexWhere((s) => identical(s, cn)) + apiInt(a, 'direction', defaultValue: 1)!;
  if (!(0 <= idx && idx < siblings.length)) {
    throw ApiError('no_variation', 'no sibling at index $idx', {'siblings': siblings.length});
  }
  h.goto(siblings[idx]);
  return {...h.currentJson(a), 'sibling_index': idx, 'siblings': siblings.length};
}

Object? _cmdPlay(CommandHandler h, ApiArgs a) {
  final game = h.game, cn = game.currentNode;
  if (game.insertMode) throw ApiError('insert_mode', "finish KaTrain's insert mode first");
  final startPlayer = parseColor(a['color']) ?? cn.nextPlayer;
  final moves = parseMoves(a['moves'] ?? const [], cn.boardSize, startPlayer);
  if (moves.isEmpty) throw ApiError('bad_argument', 'no moves given');
  final (nodes, created) = h.addNodes(cn, moves, analyze: apiBool(a['analyze'], true) ? 'full' : 'none');
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

Object? _cmdVariationAdd(CommandHandler h, ApiArgs a) {
  final start = h.node(a, 'from');
  final startPlayer = parseColor(a['color']) ?? start.nextPlayer;
  final moves = parseMoves(a['moves'] ?? const [], start.boardSize, startPlayer);
  if (moves.isEmpty) throw ApiError('bad_argument', 'no moves given');
  final (nodes, created) = h.addNodes(start, moves, analyze: pyStr(a['analyze'] ?? 'fast'));
  if (apiBool(a['goto'])) {
    h.goto(nodes.last);
  } else {
    h.refresh();
  }
  return {
    'from': nodeRef(start),
    'nodes': [for (final n in nodes) nodeRef(n)],
    'end': nodeRef(nodes.last),
    ...h.editNotice(created),
  };
}

Object? _cmdVariationDelete(CommandHandler h, ApiArgs a) {
  final game = h.game;
  final node = h.node(a);
  if (node.parent == null) throw ApiError('bad_argument', 'cannot delete the root');
  final subtree = node.nodesInTree;
  final foreign = [
    for (final n in subtree)
      if (!h.state.created.contains(n)) n,
  ];
  if (foreign.isNotEmpty && !apiBool(a['force'])) {
    throw ApiError('protected', '${foreign.length} of ${subtree.length} nodes were not created through the API', {
      'hint': 'pass force=true to delete original game nodes',
    });
  }
  for (final n in subtree) {
    n.removeShortcut();
  }
  node.parent!.children.removeWhere((c) => identical(c, node));
  if (subtree.any((n) => identical(n, game.currentNode))) {
    h.goto(node.parent!);
  } else {
    h.refresh();
  }
  return {'deleted_nodes': subtree.length, ...h.currentJson()};
}

Object? _cmdVariationPromote(CommandHandler h, ApiArgs a) {
  final node = h.node(a);
  var n = node;
  while (n.parent != null) {
    final siblings = n.parent!.children;
    siblings.removeWhere((c) => identical(c, n));
    siblings.insert(0, n);
    n = n.parent!;
  }
  h.refresh();
  return {'promoted': nodeRef(node), 'on_main_line': onMainLine(node)};
}

List<String> _colored(List<Move> moves) => [for (final m in moves) '${m.player}:${m.gtp()}'];

Object? _cmdVariationRegister(CommandHandler h, ApiArgs a) {
  final start = h.node(a, 'from');
  final startPlayer = parseColor(a['color']) ?? start.nextPlayer;
  final moves = parseMoves(a['moves'] ?? const [], start.boardSize, startPlayer);
  if (moves.isEmpty) throw ApiError('bad_argument', 'no moves given');
  checkMovesLegal(start, moves);
  final vid = 'v${h.state.nextVariationId()}';
  h.state.variations[vid] = {'from': start, 'moves': moves, 'label': a['label'], 'root': h.game.root};
  return {'id': vid, 'from': nodeRef(start), 'moves': _colored(moves), 'label': a['label']};
}

Object? _cmdVariationList(CommandHandler h, ApiArgs a) {
  final root = h.game.root;
  return [
    for (final MapEntry(key: vid, value: v) in h.state.variations.entries)
      {
        'id': vid,
        'from': nodeRef(v['from'] as GameNode),
        'moves': _colored(v['moves'] as List<Move>),
        'label': v['label'],
        'current_game': identical(v['root'], root),
      },
  ];
}

Object? _cmdVariationShow(CommandHandler h, ApiArgs a) {
  final v = h.state.variations[pyStr(a['id'])];
  if (v == null) throw ApiError('not_found', "no registered variation '${pyStr(a['id'])}'");
  if (!identical(v['root'], h.game.root)) throw ApiError('game_changed', 'this variation belongs to a different game');
  final step = apiInt(a, 'step');
  if ((a['as'] ?? 'pv') == 'branch') {
    final (nodes, created) = h.addNodes(v['from'] as GameNode, v['moves'] as List<Move>);
    final target = step != null && step != 0 ? nodes[(step < nodes.length ? step : nodes.length) - 1] : nodes.last;
    h.goto(target);
    return {
      ...h.currentJson(a),
      'nodes': [for (final n in nodes) nodeRef(n)],
      ...h.editNotice(created),
    };
  }
  return showPv(h, v['from'] as GameNode, v['moves'] as List<Move>, step);
}

// -- board display: PV overlays, marks, region, view toggles

/// Overlays a sequence with numbered stones, without changing the game tree.
Map<String, Object?> showPv(CommandHandler h, GameNode node, List<Move> moves, [int? step]) {
  final cn = h.game.currentNode;
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
  if (!identical(node, cn) && !identical(node.parent, cn) && !cn.nodesFromRoot.any((n) => identical(n, node))) {
    h.goto(node); // the board can only hide stones of descendants of the PV start
  }
  final pv = [for (final m in moves) m.gtp()];
  final index = step == null ? null : (step < pv.length ? step : pv.length) - 1;
  h.host.pv = ApiPv(pv, node, index: index == null ? null : (index < 0 ? 0 : index), pinned: true);
  h.host.redrawOverlay();
  return {
    'from': nodeRef(node),
    'pv': pv,
    'shown_moves': step == null ? pv.length : h.host.pv!.index! + 1,
    'animated': step == null,
  };
}

Object? _cmdPvShow(CommandHandler h, ApiArgs a) {
  final node = h.node(a, 'from');
  Object? raw;
  if (truthy(a['candidate'])) {
    final want = pyStr(a['candidate']).toUpperCase();
    Map<String, dynamic>? cand;
    for (final c in node.candidateMoves) {
      if ((c['move'] as String).toUpperCase() == want) {
        cand = c;
        break;
      }
    }
    final pv = cand?['pv'] as List?;
    if (cand == null || pv == null || pv.isEmpty) {
      throw ApiError('not_found', 'no analysed candidate $want with a PV at ${nodeRef(node)}', {
        'hint': 'run analysis.moves first',
      });
    }
    raw = pv;
  } else {
    raw = a['moves'] ?? const [];
  }
  final moves = parseMoves(raw, node.boardSize, node.nextPlayer);
  if (moves.isEmpty) throw ApiError('bad_argument', 'give moves or candidate');
  return showPv(h, node, moves, apiInt(a, 'step', minimum: 1));
}

Object? _cmdPvStep(CommandHandler h, ApiArgs a) {
  final pvState = h.host.pv;
  if (pvState == null) throw ApiError('no_pv', 'no PV is being shown');
  final pv = pvState.moves;
  int shown;
  if (a['index'] != null) {
    shown = apiInt(a, 'index')!;
  } else {
    final current = pvState.index ?? pv.length - 1;
    shown = current + 1 + apiInt(a, 'delta', defaultValue: 1)!;
  }
  shown = shown < 1 ? 1 : (shown > pv.length ? pv.length : shown);
  pvState
    ..index = shown - 1
    ..pinned = true;
  h.host.redrawOverlay();
  return {'pv': pv, 'shown_moves': shown, 'last_shown': pv[shown - 1]};
}

Object? _cmdPvHide(CommandHandler h, ApiArgs a) {
  h.host.pv = null;
  h.host.redrawOverlay();
  return {'hidden': true};
}

Map<String, Object?> _markJson(Map<String, Object?> m) {
  final out = <String, Object?>{
    for (final MapEntry(:key, :value) in m.entries)
      if (!const ['rgb', 'coords', 'region', 'node'].contains(key)) key: value,
  };
  if (m.containsKey('coords')) out['point'] = gtp(m['coords'] as (int, int)?);
  if (m.containsKey('region')) out['region'] = regionJson(m['region'] as List<int>?);
  out['node'] = m['node'] == null ? null : 'n${m['node']}';
  return out;
}

Object? _cmdMarkAdd(CommandHandler h, ApiArgs a) {
  final game = h.game;
  final kind = pyStr(a['type'] ?? 'circle');
  if (!markTypes.contains(kind) || kind == 'area') {
    throw ApiError(
      'bad_argument',
      'type must be one of ${pyRepr([for (final t in markTypes)
        if (t != 'area') t])}',
    );
  }
  final rgb = parseMarkColor(a['color']);
  if (rgb == null) throw ApiError('bad_argument', 'unknown color ${pyRepr(a['color'])} (named color or #rrggbb)');
  var points = a['points'] ?? const [];
  if (points is String) points = splitWords(points);
  final pointList = points as List;
  if (pointList.isEmpty) throw ApiError('bad_argument', 'no points given');
  var texts = a['text'];
  if (texts is String) {
    texts = pointList.length == 1 ? [texts] : texts.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  }
  final textList = texts as List?;
  final scopeNode = a['scope'] == 'global' ? null : nodeId(game.currentNode);
  final added = <Map<String, Object?>>[];
  for (var i = 0; i < pointList.length; i++) {
    final coords = parseCoords(pointList[i], game.boardSize);
    if (coords == null) throw ApiError('bad_coordinate', 'cannot mark pass');
    String? text;
    if (kind == 'label') {
      text = textList != null && textList.isNotEmpty && i < textList.length
          ? pyStr(textList[i])
          : String.fromCharCode('A'.codeUnitAt(0) + i % 26);
    }
    // replace an existing mark at the same point and scope
    h.state.marks = [
      for (final m in h.state.marks)
        if (!(m['coords'] == coords && m['node'] == scopeNode)) m,
    ];
    final mark = <String, Object?>{
      'id': h.state.nextMarkId(),
      'type': kind,
      'coords': coords,
      'rgb': rgb,
      'color': a['color'] ?? 'red',
      'text': text,
      'node': scopeNode,
    };
    h.state.marks.add(mark);
    added.add(_markJson(mark));
  }
  h.host.redrawOverlay();
  return {'added': added};
}

Object? _cmdMarkArea(CommandHandler h, ApiArgs a) {
  final game = h.game;
  final color = truthy(a['color']) ? a['color'] : 'yellow';
  final rgb = parseMarkColor(color);
  if (rgb == null) throw ApiError('bad_argument', 'unknown color ${pyRepr(a['color'])}');
  final region = parseRegion(truthy(a['region']) ? a['region'] : '', game.boardSize);
  final mark = <String, Object?>{
    'id': h.state.nextMarkId(),
    'type': 'area',
    'region': region,
    'rgb': rgb,
    'color': color,
    'text': a['text'],
    'node': a['scope'] == 'global' ? null : nodeId(game.currentNode),
  };
  h.state.marks.add(mark);
  h.host.redrawOverlay();
  return {
    'added': [_markJson(mark)],
  };
}

Object? _cmdMarkList(CommandHandler h, ApiArgs a) => [for (final m in h.state.marks) _markJson(m)];

Object? _cmdMarkClear(CommandHandler h, ApiArgs a) {
  final before = h.state.marks.length;
  final ids = a['ids'], points = a['points'];
  if (truthy(ids)) {
    final idList = ids is List ? ids : splitWords(pyStr(ids));
    final wanted = {for (final i in idList) int.parse(pyStr(i).replaceFirst(RegExp(r'^#+'), ''))};
    h.state.marks = [
      for (final m in h.state.marks)
        if (!wanted.contains(m['id'])) m,
    ];
  } else if (truthy(points)) {
    final pointList = points is String ? splitWords(points) : points as List;
    final coords = {for (final p in pointList) parseCoords(p, h.game.boardSize)};
    h.state.marks = [
      for (final m in h.state.marks)
        if (!coords.contains(m['coords'])) m,
    ];
  } else {
    h.state.marks = [];
  }
  h.host.redrawOverlay();
  return {'removed': before - h.state.marks.length, 'remaining': h.state.marks.length};
}

Object? _cmdRegionSet(CommandHandler h, ApiArgs a) {
  final game = h.game;
  final region = parseRegion(truthy(a['region']) ? a['region'] : '', game.boardSize);
  game.setRegionOfInterest([region[0], region[1], region[2], region[3]]);
  h.refresh(false);
  return {'region_of_interest': regionJson(game.regionOfInterest)};
}

Object? _cmdRegionClear(CommandHandler h, ApiArgs a) {
  h.game.regionOfInterest = null;
  h.refresh(false);
  return {'region_of_interest': null};
}

Object? _cmdViewSet(CommandHandler h, ApiArgs a) {
  final host = h.host;
  final changed = <String, Object?>{};
  for (final MapEntry(key: key, value: control) in viewToggles.entries) {
    if (a[key] != null) {
      host.setAnalysisControl(control, apiBool(a[key]));
      changed[key] = apiBool(a[key]);
    }
  }
  if (a['move_numbers'] != null) {
    host.showMoveNumbers = apiBool(a['move_numbers']);
    changed['move_numbers'] = host.showMoveNumbers;
  }
  if (a['zoom'] != null || a['hide_frame'] != null) {
    var zoom = host.zoomRegion;
    var hidden = host.hiddenCoords;
    final ts = h.state.tsumego;
    if (a['zoom'] != null) {
      final spec = pyStr(a['zoom']).trim().toLowerCase();
      if (const ['off', 'false', 'none', ''].contains(spec)) {
        zoom = null;
      } else if (spec == 'auto') {
        if (ts == null) {
          throw ApiError('no_tsumego', 'zoom=auto needs a loaded tsumego problem; give a region like C3:G7');
        }
        zoom = ts.viewRegion;
      } else {
        zoom = parseRegion(a['zoom'], h.game.boardSize);
      }
    }
    if (a['hide_frame'] != null) {
      hidden = apiBool(a['hide_frame']) ? (ts?.frameCoords ?? <(int, int)>{}) : <(int, int)>{};
    }
    host.setZoom(zoom, hidden);
    changed['zoom'] = regionJson(zoom);
    changed['hidden_stones'] = hidden.length;
  }
  h.refresh();
  final view = <String, Object?>{
    for (final MapEntry(key: key, value: control) in viewToggles.entries) key: host.analysisControl(control),
    'move_numbers': host.showMoveNumbers,
    'zoom': regionJson(host.zoomRegion),
    'hidden_stones': host.hiddenCoords.length,
  };
  return {'changed': changed, 'view': view};
}

Object? _cmdModeSet(CommandHandler h, ApiArgs a) {
  final mode = a['mode'];
  if (mode != modePlay && mode != modeAnalyze) {
    throw ApiError('bad_argument', "mode must be '$modePlay' or '$modeAnalyze'");
  }
  h.setMode(mode as String);
  return {'mode': h.host.mode};
}

Object? _cmdMessage(CommandHandler h, ApiArgs a) {
  var text = pyStr(truthy(a['text']) ? a['text'] : '');
  if (text.length > 300) text = text.substring(0, 300);
  h.host.showStatus(text);
  return {'shown': text};
}

// -- snapshots and demo mode

Object? _cmdStateSave(CommandHandler h, ApiArgs a) {
  final name = pyStr(truthy(a['name']) ? a['name'] : 'default');
  h.state.snapshots[name] = h.capture();
  return CommandHandler.snapshotJson(name, h.state.snapshots[name]!);
}

Object? _cmdStateRestore(CommandHandler h, ApiArgs a) {
  final name = pyStr(truthy(a['name']) ? a['name'] : 'default');
  final snap = h.state.snapshots[name];
  if (snap == null) {
    throw ApiError('not_found', "no saved state '$name'", {'available': h.state.snapshots.keys.toList()..sort()});
  }
  h.restore(snap);
  return {'restored': name, ...h.currentJson(a)};
}

Object? _cmdStateList(CommandHandler h, ApiArgs a) => [
  for (final MapEntry(key: name, value: snap) in h.state.snapshots.entries) CommandHandler.snapshotJson(name, snap),
];

Object? _cmdDemoStart(CommandHandler h, ApiArgs a) {
  if (h.state.demo != null) throw ApiError('demo_active', 'a demo is already running', {'hint': 'demo end first'});
  final game = h.game;
  h.state.demo = {
    'snapshot': h.capture(),
    'existing': Set<GameNode>.identity()..addAll(game.root.nodesInTree),
    'label': a['label'],
  };
  h.setMode(modeAnalyze); // no AI replies or teaching undos while demonstrating
  return {'demo': 'started', 'label': a['label'], ...h.currentJson(a)};
}

Object? _cmdDemoEnd(CommandHandler h, ApiArgs a) {
  final demo = h.state.demo;
  if (demo == null) throw ApiError('no_demo', 'no demo is running');
  h.state.demo = null;
  final game = h.game;
  final snap = demo['snapshot'] as Map<String, Object?>;
  h.host.pv = null;
  if (!identical(game.root, snap['root'])) {
    return {'demo': 'ended', 'warning': 'a different game was loaded during the demo; nothing restored'};
  }
  var removed = 0;
  if (!apiBool(a['keep'])) {
    final existing = demo['existing'] as Set<GameNode>;
    final added = [
      for (final n in game.root.nodesInTree)
        if (!existing.contains(n) && n.parent != null && existing.contains(n.parent)) n,
    ];
    for (final node in added) {
      for (final n in node.nodesInTree) {
        n.removeShortcut();
        removed += 1;
      }
      node.parent!.children.removeWhere((c) => identical(c, node));
    }
  }
  h.restore(snap);
  return {'demo': 'ended', 'removed_nodes': removed, 'kept': apiBool(a['keep']), ...h.currentJson(a)};
}

Object? _cmdDemoStatus(CommandHandler h, ApiArgs a) {
  final demo = h.state.demo;
  if (demo == null) return {'active': false};
  final existing = demo['existing'] as Set<GameNode>;
  final added = [
    for (final n in h.game.root.nodesInTree)
      if (!existing.contains(n)) n,
  ];
  return {
    'active': true,
    'label': demo['label'],
    'started_at': nodeRef((demo['snapshot'] as Map)['node'] as GameNode),
    'added_nodes': added.length,
  };
}

final Map<String, ApiCommand> _coreCommands = {
  'commands': const ApiCommand(_cmdCommands, 'List available API commands.'),
  'status': const ApiCommand(cmdStatus, 'Game info, current node, mode, engine state, demo state.'),
  'board': const ApiCommand(_cmdBoard, 'Stones on the board at a node (default: current).'),
  'node': const ApiCommand(_cmdNode, 'Details of one node: move, children, comments, properties, evaluation.'),
  'history': const ApiCommand(
    _cmdHistory,
    'Moves from the root to a node; with future=true continue to the end of the line.',
  ),
  'tree': const ApiCommand(_cmdTree, 'Game tree with variations (linear stretches collapsed).'),
  'variations': const ApiCommand(
    _cmdVariations,
    'Alternatives at a node (its children) and the branch points on its line.',
  ),
  'sgf.export': const ApiCommand(
    _cmdSgfExport,
    "Export the game as SGF text, or write it to 'path' (refuses to overwrite unless overwrite=true).",
  ),
  'sgf.import': const ApiCommand(
    _cmdSgfImport,
    'Load an SGF (path or content) into the GUI. The previous game is backed up first.',
  ),
  'game.new': const ApiCommand(
    _cmdGameNew,
    'Start a new empty game (size, komi, rules, handicap). The previous game is backed up first.',
  ),
  'analysis.get': const ApiCommand(_cmdAnalysisGet, 'Analysis KaTrain already has for a node (no new search).'),
  'analysis.run': const ApiCommand(
    _cmdAnalysisRun,
    'Search a node to `visits` (reuses existing results if already deep enough) and return the analysis.',
    waitsForEngine: true,
  ),
  'analysis.moves': const ApiCommand(
    _cmdAnalysisMoves,
    'Search specific candidate moves at a node and compare them (points lost, PV).',
    waitsForEngine: true,
  ),
  'analysis.game': const ApiCommand(
    _cmdAnalysisGame,
    'Queue whole-game (re)analysis in the background; poll with analysis.wait or status.',
  ),
  'analysis.wait': const ApiCommand(
    _cmdAnalysisWait,
    'Wait until the engine has no pending queries (not while pondering).',
    waitsForEngine: true,
  ),
  'analysis.ponder': const ApiCommand(
    _cmdAnalysisPonder,
    'Turn continuous analysis of the current position on or off.',
  ),
  'analysis.stop': const ApiCommand(_cmdAnalysisStop, 'Stop pondering and cancel all pending KataGo queries.'),
  'engine.get': const ApiCommand(_cmdEngineGet, 'Current search settings.'),
  'engine.set': const ApiCommand(
    _cmdEngineSet,
    'Change search settings (max_visits, fast_visits, max_time, wide_root_noise); save=true persists them.',
  ),
  'nav.goto': const ApiCommand(_cmdGoto, 'Jump to a node (move number, n<ID>, main:<N>, root, end).'),
  'nav.next': const ApiCommand(_cmdNext, 'Step forward n moves along the current line.'),
  'nav.prev': const ApiCommand(_cmdPrev, 'Step back n moves.'),
  'nav.branch': const ApiCommand(
    _cmdBranch,
    'Switch to the next (direction=1) or previous (-1) sibling variation, or a given index.',
  ),
  'play': const ApiCommand(
    _cmdPlay,
    'Play moves from the current node (adds them to the game tree, analyzed like GUI moves).',
  ),
  'variation.add': const ApiCommand(
    _cmdVariationAdd,
    'Add a variation below a node without validating against the GUI state; goto=true jumps to its end.',
  ),
  'variation.delete': const ApiCommand(
    _cmdVariationDelete,
    'Delete a node and everything below it. Nodes not created via the API need force=true.',
  ),
  'variation.promote': const ApiCommand(_cmdVariationPromote, 'Make the line through a node the main line.'),
  'variation.register': const ApiCommand(
    _cmdVariationRegister,
    'Register a variation (moves from a node) under a short id like v1, without touching the board.',
  ),
  'variation.list': const ApiCommand(_cmdVariationList, 'Registered variations.'),
  'variation.show': const ApiCommand(
    _cmdVariationShow,
    'Show a registered variation: as=pv (overlay, default) or as=branch (creates nodes, goes to step).',
  ),
  'pv.show': const ApiCommand(
    _cmdPvShow,
    "Overlay a variation as numbered stones (moves=..., or candidate=<move> to use KataGo's PV). step=N shows N "
    'moves.',
  ),
  'pv.step': const ApiCommand(_cmdPvStep, 'Step the shown PV: delta=+1/-1, or index=N (number of moves shown).'),
  'pv.hide': const ApiCommand(_cmdPvHide, 'Remove the PV overlay.'),
  'mark.add': const ApiCommand(
    _cmdMarkAdd,
    'Mark points: type=circle|square|triangle|cross|label|dot, text for labels, color, scope=node|global.',
  ),
  'mark.area': const ApiCommand(
    _cmdMarkArea,
    'Highlight a rectangular area, e.g. region=C3:G7, with optional label text and color.',
  ),
  'mark.list': const ApiCommand(_cmdMarkList, 'All API marks.'),
  'mark.clear': const ApiCommand(_cmdMarkClear, 'Remove marks: all (default), ids=[...], or points=[...].'),
  'region.set': const ApiCommand(
    _cmdRegionSet,
    "Restrict KataGo's candidate moves to a region (KaTrain's region of interest), e.g. C3:G7.",
  ),
  'region.clear': const ApiCommand(_cmdRegionClear, 'Remove the region of interest.'),
  'view.set': const ApiCommand(
    _cmdViewSet,
    'Toggle display layers: hints, ownership, policy, eval, children, move_numbers (true/false); '
    'zoom=C3:G7|auto|off',
  ),
  'mode.set': const ApiCommand(_cmdModeSet, 'Switch between play and analyze mode.'),
  'message': const ApiCommand(_cmdMessage, "Show a short line in KaTrain's status bar."),
  'state.save': const ApiCommand(
    _cmdStateSave,
    'Remember the current position, mode, region, marks, shown PV and status text; returns a katrain:// link.',
  ),
  'state.restore': const ApiCommand(_cmdStateRestore, 'Return to a saved state.'),
  'state.list': const ApiCommand(_cmdStateList, 'Saved states.'),
  'demo.start': const ApiCommand(
    _cmdDemoStart,
    'Begin a temporary demonstration: everything added until demo.end is removed again (unless keep=true).',
  ),
  'demo.end': const ApiCommand(
    _cmdDemoEnd,
    'End the demo: drop nodes added during it (keep=true keeps them) and restore the saved position.',
  ),
  'demo.status': const ApiCommand(_cmdDemoStatus, 'Whether a demo is running and where it started.'),
};
