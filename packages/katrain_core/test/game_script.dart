// Runs the operation scripts of tools/fixtures/game_fixtures.py (and the scripts built on it) on the port, with the
// same stand-ins for KaTrain and the engine, and compares the events and state after every operation.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

String? nodePath(GameNode? node) {
  if (node == null) return null;
  final parts = <int>[];
  var n = node;
  while (n.parent != null) {
    parts.add(n.parent!.children.indexOf(n));
    n = n.parent!;
  }
  return parts.reversed.join('.');
}

GameNode nodeAt(GameNode root, String path) {
  var node = root;
  for (final part in path.isEmpty ? const <String>[] : path.split('.')) {
    node = node.children[int.parse(part)];
  }
  return node;
}

Iterable<GameNode> preorder(GameNode root) sync* {
  final stack = [root];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    yield node;
    stack.addAll(node.children.reversed);
  }
}

/// Shortcut ids are node identities: compare them by order of first appearance.
String normalizeShortcutIds(String sgf) {
  final ids = <String, int>{};
  return sgf.replaceAllMapped(
    RegExp(r'(KTSID|KTSF)\[(\d+)\]'),
    (m) => '${m[1]}[${ids.putIfAbsent(m[2]!, () => ids.length + 1)}]',
  );
}

/// KT values are gzipped: compare what is inside, since deflate output may differ between zlib builds.
String gunzipValues(String sgf) => sgf.replaceAllMapped(
  RegExp(r'\[(H4sI[A-Za-z0-9+/=]*)\]'),
  (m) => '[gunzip:${base64.encode(GZipDecoder().decodeBytes(base64.decode(m[1]!)))}]',
);

Object? deepCopy(Object? value) => jsonDecode(jsonEncode(value));

String shortJson(Object? v) {
  final s = jsonEncode(v);
  return s.length > 300 ? '${s.substring(0, 300)}...' : s;
}

/// Where [actual] first differs from [expected], or null when they are equal.
String? firstDifference(Object? actual, Object? expected, [String path = '']) {
  if (actual is Map && expected is Map) {
    for (final key in {...expected.keys, ...actual.keys}) {
      final d = firstDifference(actual[key], expected[key], '$path/$key');
      if (d != null) return d;
    }
    return null;
  }
  if (actual is List && expected is List) {
    for (var i = 0; i < actual.length && i < expected.length; i++) {
      final d = firstDifference(actual[i], expected[i], '$path[$i]');
      if (d != null) return d;
    }
    if (actual.length != expected.length) {
      return '$path: length ${actual.length} != ${expected.length}, '
          'extra ${shortJson(actual.length > expected.length ? actual.sublist(expected.length) : expected.sublist(actual.length))}';
    }
    return null;
  }
  if (actual is String && expected is String && actual != expected) {
    var i = 0;
    while (i < actual.length && i < expected.length && actual[i] == expected[i]) {
      i++;
    }
    final from = i < 80 ? 0 : i - 80;
    return '$path: strings differ at $i:\n  actual   ${jsonEncode(actual.substring(from, (i + 80).clamp(0, actual.length)))}'
        '\n  expected ${jsonEncode(expected.substring(from, (i + 80).clamp(0, expected.length)))}';
  }
  return actual == expected ? null : '$path: ${shortJson(actual)} != ${shortJson(expected)}';
}

class RecordingHost implements GameHost {
  List<Object?> events = [];
  final Map<String, dynamic> settings;
  @override
  final Map<String, Player> playersInfo = {'B': Player('B'), 'W': Player('W')};
  @override
  Game? game;

  RecordingHost(this.settings);

  @override
  Object? config(String setting, [Object? defaultValue]) {
    if (setting.contains('/')) {
      final [cat, key] = setting.split('/');
      return (settings[cat] as Map<String, dynamic>? ?? const {})[key] ?? defaultValue;
    }
    return settings[setting] ?? defaultValue;
  }

  @override
  set pondering(bool value) => events.add(['pondering', value]);

  @override
  void log(String message, int level) => events.add(['log', message, level]);

  @override
  void setStatus(String message, num statusType, {GameNode? atNode}) =>
      events.add(['status', message, statusType, nodePath(atNode)]);

  @override
  void updateState({bool redrawBoard = false}) => events.add(['update_state', redrawBoard]);

  @override
  set insertNode(GameNode? node) => events.add(['insert_node', nodePath(node)]);

  @override
  void redrawMoveTree() => events.add(['redraw_tree']);
}

/// Records requests like the Python stand-in, and keeps the callbacks to feed results to.
class RecordingEngine implements AnalysisEngine<GameNode> {
  final RecordingHost host;
  @override
  final Map<String, dynamic> config;
  final List<AnalysisCallback> callbacks = [];
  @override
  int queryGeneration = 0;

  RecordingEngine(this.host, this.config);

  @override
  void requestAnalysis(
    GameNode analysisNode, {
    required AnalysisCallback callback,
    AnalysisErrorCallback? errorCallback,
    int? visits,
    bool analyzeFast = false,
    bool timeLimit = true,
    bool findAlternatives = false,
    List<int>? regionOfInterest,
    int priority = 0,
    bool ponder = false,
    bool? ownership,
    Move? nextMove,
    Map<String, dynamic>? extraSettings,
    bool includePolicy = true,
    double? reportEvery,
  }) {
    if (analysisNode.nodesFromRoot.any((n) => n.clearPlacements.isNotEmpty)) {
      host.events.add(['query_skipped', nodePath(analysisNode)]);
      return;
    }
    host.events.add([
      'query',
      callbacks.length,
      nodePath(analysisNode),
      {
        'visits': visits,
        'analyze_fast': analyzeFast,
        'time_limit': timeLimit,
        'find_alternatives': findAlternatives,
        'region_of_interest': regionOfInterest,
        'priority': priority,
        'ponder': ponder,
        'ownership': ownership,
        'next_move': nextMove == null ? null : [nextMove.player, nextMove.gtp()],
        'extra_settings': extraSettings,
        'include_policy': includePolicy,
        'report_every': reportEvery,
      },
    ]);
    callbacks.add(callback);
    var v = visits;
    if (v == null) {
      v = config['max_visits'] as int;
      if (analyzeFast && config['fast_visits'] != null) v = config['fast_visits'] as int;
    }
    if (v > analysisNode.analysisVisitsRequested) analysisNode.analysisVisitsRequested = v;
  }

  @override
  void terminateQueries({GameNode? onlyForNode}) => host.events.add(['terminate', nodePath(onlyForNode)]);

  @override
  void stopPondering() => host.events.add(['stop_pondering']);
}

/// Replays a recorded operation script: [handlers] add the operations of scripts built on the game one.
class ScriptRunner {
  final Map<String, dynamic> data;
  late final Map<String, dynamic> settings;
  late final RecordingHost host;
  late final RecordingEngine engine;
  late final List<int> now;
  Directory? _tmp;
  Directory get tmp => _tmp ??= Directory.systemTemp.createTempSync('katrain_neo_script');
  final Map<String, Future<void> Function(Map<String, dynamic> op)> handlers = {};
  Game? game;

  ScriptRunner(this.data, {RecordingEngine Function(RecordingHost host, Map<String, dynamic> config)? engine}) {
    settings = deepCopy(data['config']) as Map<String, dynamic>;
    host = RecordingHost(settings);
    this.engine = (engine ?? RecordingEngine.new)(host, settings['engine'] as Map<String, dynamic>);
    now = (data['now'] as List).cast<int>();
  }

  Map<String, dynamic>? snapshot() {
    final g = game;
    if (g == null) return null;
    return {
      'current': nodePath(g.currentNode),
      'board': g.boardString,
      'prisoners': g.prisonerCount,
      'insert_mode': g.insertMode,
      'insert_after': nodePath(g.insertAfter),
      'region_of_interest': g.regionOfInterest,
      'external': g.externalGame,
      'tree': [
        for (final node in preorder(g.root))
          [
            nodePath(node),
            node.move == null ? null : '${node.move!.player}${node.move!.gtp()}',
            node.placements.length,
            node.autoUndo,
            node.aiThoughts,
            node.analysisVisitsRequested,
            node.analysisComplete,
            nodePath(node.shortcutFrom),
            [for (final (to, _) in node.shortcutsTo) nodePath(to)],
          ],
      ],
    };
  }

  Future<void> run(Map<String, dynamic> op) async {
    final g = game;
    final handler = handlers[op['op']];
    if (handler != null) return handler(op);
    switch (op['op']) {
      case 'seed':
        globalRandom.seed(BigInt.from(op['seed'] as int));
      case 'config':
        final [cat, key] = (op['key'] as String).split('/');
        (settings[cat] as Map<String, dynamic>)[key] = deepCopy(op['value']);
      case 'player':
        host.playersInfo[op['bw']]!
          ..update(op['type'] as String, op['subtype'] as String)
          ..calculatedRank = (op['rank'] as num?)?.toDouble()
          ..name = op['name'] as String;
      case 'new_game':
        final sgf = op['sgf'] as String?;
        engine.callbacks.clear();
        game = Game(
          host,
          engine,
          moveTree: sgf == null ? null : gameParser.parseSgf(sgf),
          analyzeFast: op['analyze_fast'] as bool,
          gameProperties: (op['props'] as Map<String, dynamic>?),
          now: DateTime(now[0], now[1], now[2], now[3], now[4], now[5]),
        );
        host.game = game;
        await Future<void>.delayed(Duration.zero); // the initial analysis runs as a later event
      case 'play':
        final player = (op['player'] as String?) ?? g!.currentNode.nextPlayer;
        g!.play(
          Move.fromGtp(op['move'] as String, player: player),
          ignoreKo: op['ignore_ko'] as bool,
          analyze: op['analyze'] as bool,
        );
      case 'sync':
        final moves = [
          for (final m in (op['moves'] as List).cast<String>()) Move.fromGtp(m.substring(1), player: m[0]),
        ];
        host.events.add(['synced', nodePath(g!.syncBranch(moves))]);
      case 'undo':
        g!.undo(op['n'] as Object, (op['stop'] as num?)?.toDouble());
      case 'redo':
        g!.redo(op['n'] as int, (op['stop'] as num?)?.toDouble());
      case 'goto':
        g!.setCurrentNode(nodeAt(g.root, op['path'] as String));
      case 'insert':
        g!.setInsertMode(op['mode'] as Object);
      case 'roi':
        g!.setRegionOfInterest((op['region'] as List).cast<int>());
      case 'extra':
        final kwargs = op['kwargs'] as Map<String, dynamic>;
        g!.analyzeExtra(
          op['mode'] as String,
          mistakesOnly: (kwargs['mistakes_only'] ?? false) as bool,
          moveRange: (kwargs['move_range'] as List?)?.cast<int>(),
          visits: kwargs['visits'] as int?,
        );
      case 'reset_analysis':
        g!.resetCurrentAnalysis();
      case 'analyze_all':
        g!.analyzeAllNodes(
          priority: op['priority'] as int,
          analyzeFast: op['analyze_fast'] as bool,
          evenIfPresent: op['even_if_present'] as bool,
        );
      case 'feed':
        engine.callbacks[op['query'] as int](deepCopy(op['result']) as Map<String, dynamic>, op['partial'] as bool);
      case 'undo_threshold':
        nodeAt(g!.root, op['path'] as String).undoThreshold = (op['value'] as num).toDouble();
      case 'analyze_undo':
        g!.analyzeUndo(nodeAt(g.root, op['path'] as String));
      case 'selfplay':
        g!.selfplay(op['until'] as Object, targetBAdvantage: (op['target'] as num?)?.toDouble());
      case 'manual_score':
        host.events.add(['result', g!.manualScore, g.endResult]);
      case 'end_state':
        g!.currentNode.endState = op['value'] as String?;
      case 'save':
        final filename = '${tmp.path}${Platform.pathSeparator}out${Platform.pathSeparator}game.sgf';
        final message = writeSgf(g!, filename, trainerConfig: op['trainer'] as Map<String, dynamic>?);
        final sgf = File(filename).readAsStringSync();
        File(filename).deleteSync();
        host.events.add(['sgf', normalizeShortcutIds(sgf), message.replaceAll(filename, '<file>')]);
        // the file name starts with the program's name
        host.events.add(['filename', g.generateFilename().replaceFirst('${writerName}_', 'KaTrain_')]);
      default:
        fail('unknown op ${op['op']}');
    }
  }

  /// Runs every operation and fails at the first one whose events, error or state differ from the recording.
  Future<void> check() async {
    final ops = (data['ops'] as List).cast<Map<String, dynamic>>();
    final outputs = (data['outputs'] as List).cast<Map<String, dynamic>>();
    try {
      for (var i = 0; i < ops.length; i++) {
        final op = ops[i];
        host.events = [];
        String? error;
        try {
          await run(op);
        } on IllegalMoveException catch (e) {
          error = e.message;
        } on Exception catch (e) {
          if (!handlers.containsKey(op['op'])) rethrow;
          error = e.toString().replaceFirst(RegExp('^Exception: '), ''); // str(e) of a Python exception
        }
        final actual = deepCopy({'events': host.events, 'error': error, 'state': snapshot()});
        final expected = deepCopy(outputs[i]) as Map<String, dynamic>;
        for (final output in [actual as Map<String, dynamic>, expected]) {
          for (final event in (output['events'] as List).cast<List>()) {
            if (event[0] == 'sgf') event[1] = gunzipValues(event[1] as String);
          }
        }
        final difference = firstDifference(actual, expected);
        if (difference != null) fail('operation $i ${shortJson(op)}\n$difference');
      }
    } finally {
      _tmp?.deleteSync(recursive: true);
    }
  }
}
