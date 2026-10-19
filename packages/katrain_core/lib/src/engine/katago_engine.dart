// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/engine.py (KataGoEngine) and
// katrain/core/remote_engine.py (RemoteKataGoEngine). This is the protocol; the process and WebSocket transports
// are in package:katrain_core/io.dart.
//
// KaTrain uses three threads and a write queue; here everything runs on one event loop, so queries are written as
// soon as they are requested. The bookkeeping (ids, generations, pondering) is the same.

import 'dart:convert';
import 'dart:math' as math;

import '../constants.dart';
import '../game/game_node.dart';
import '../i18n/i18n.dart';
import '../rules/rulesets.dart';
import '../sgf/move.dart';
import '../utils/py_format.dart';
import '../utils/py_str_format.dart';
import 'analysis_engine.dart';

/// What the engine needs from the application (KaTrain's `katrain` object).
abstract interface class EngineHost {
  void log(String message, num level);

  /// An engine error the user should know about; KaTrain opens its engine recovery popup when [allowPopup].
  void onEngineError(String message, Object? code, {required bool allowPopup, required String engineType});

  /// Called after every line from KataGo (KaTrain's `update_state`).
  void onEngineUpdate();

  /// A short status message (KaTrain's `controls.set_status(..., STATUS_INFO)`).
  void setStatus(String message);
}

/// The link to a running KataGo: lines go out with [send]; the owner feeds incoming lines to the engine.
abstract interface class EngineConnection {
  bool get alive;
  void send(String line);
  Future<void> close();
}

/// `resolve_engine_backend`: 'local', 'remote' or 'custom'.
String resolveEngineBackend(Map<String, dynamic> config) {
  final backend = ((config['backend'] as String?) ?? '').trim().toLowerCase();
  if (const ['local', 'remote', 'custom'].contains(backend)) return backend;
  if (((config['remote_url'] as String?) ?? '').trim().isNotEmpty) return 'remote';
  if (((config['altcommand'] as String?) ?? '').trim().isNotEmpty) return 'custom';
  return 'local';
}

class _Query {
  final AnalysisCallback? callback;
  final AnalysisErrorCallback? errorCallback;
  final DateTime startTime;
  final Move? nextMove;
  final GameNode? node;
  _Query(this.callback, this.errorCallback, this.startTime, this.nextMove, this.node);
}

/// Talks KataGo's JSON analysis protocol for KaTrain: builds queries from nodes, keeps track of them, and hands the
/// results to the callbacks.
class KataGoEngine implements AnalysisEngine<GameNode> {
  static const ponderKey = '_kt_continuous';

  final EngineHost host;
  final Map<String, dynamic> config;

  /// 'local' or 'remote', passed to the recovery popup so it can tailor its advice.
  final String engineType;

  final Map<String, _Query> _queries = {};
  final Map<String, Map<String, dynamic>> _sentPayloads = {}; // remote only: to resume after reconnecting
  Map<String, dynamic>? _ponderQuery;
  int _queryCounter = 0;
  int basePriority = 0;
  int queryGeneration = 0;
  final Map<String, dynamic> overrideSettings = {'reportAnalysisWinratesAs': 'BLACK'};

  EngineConnection? connection;

  // KaTrain's write queue: queries requested while one is being written go out after it, in order
  final List<(Map<String, dynamic>, AnalysisCallback?, AnalysisErrorCallback?, Move?, GameNode?, int)> _pending = [];
  bool _flushing = false;

  // KaTrain's reader threads stop after an uncaught KataGo exception
  bool _stdoutStopped = false;
  bool _stderrStopped = false;

  KataGoEngine(this.host, this.config, {this.engineType = 'local'});

  bool get allowRecovery => (config['allow_recovery'] as bool?) ?? true;

  bool get _remote => engineType == 'remote';

  void onError(String message, Object? code, {bool allowPopup = true}) {
    host.log(message, outputError);
    if (allowRecovery && allowPopup) {
      host.onEngineError(message, code, allowPopup: true, engineType: engineType);
    }
  }

  /// A new game: older queries are dropped and their results ignored.
  void onNewGame() {
    basePriority += 1;
    queryGeneration += 1;
    drainPending();
    terminateQueries();
    _ponderQuery = null;
    _queries.clear();
    _sentPayloads.clear();
  }

  void terminateQueries({GameNode? onlyForNode}) {
    for (final entry in _queries.entries.toList()) {
      if (onlyForNode == null || identical(onlyForNode, entry.value.node)) {
        terminateQuery(entry.key);
      }
    }
  }

  void stopPondering() {
    final pq = _ponderQuery;
    _ponderQuery = null;
    if (pq != null) terminateQuery(pq['id'] as String, ignoreFurtherResults: false);
  }

  void terminateQuery(String? queryId, {bool ignoreFurtherResults = true}) {
    host.log('Terminating query $queryId', outputDebug);
    if (queryId != null) {
      sendQuery({'action': 'terminate', 'terminateId': queryId}, null, null);
      if (ignoreFurtherResults) {
        _queries.remove(queryId);
      }
    }
  }

  /// Forgets all outstanding queries (KaTrain clears its `queries` dict on restart).
  void clearQueries() => _queries.clear();

  void clearSentPayloads() => _sentPayloads.clear();

  bool isIdle() => _queries.isEmpty && _pending.isEmpty;

  int queriesRemaining() => _queries.length + (_pending.isEmpty ? 0 : 1);

  /// Ids of the queries waiting for results.
  Iterable<String> get outstandingQueries => _queries.keys;

  /// Queues a query (KaTrain's `send_query`) and writes the queue.
  void sendQuery(
    Map<String, dynamic> query,
    AnalysisCallback? callback,
    AnalysisErrorCallback? errorCallback, {
    Move? nextMove,
    GameNode? node,
  }) {
    _pending.add((query, callback, errorCallback, nextMove, node, queryGeneration));
    if (_flushing) return;
    _flushing = true;
    try {
      while (_pending.isNotEmpty) {
        final conn = connection;
        if (conn == null || !conn.alive) return; // KaTrain keeps them queued; a restart drops them
        final (q, cb, ecb, move, n, generation) = _pending.removeAt(0);
        if (generation != queryGeneration) continue;
        _write(conn, q, cb, ecb, move, n);
      }
    } finally {
      _flushing = false;
    }
  }

  /// Drops queries that were not written yet (KaTrain's `_drain_write_queue`).
  void drainPending() => _pending.clear();

  /// What KaTrain's writer thread does with one query: id, pondering, registration, write.
  void _write(
    EngineConnection conn,
    Map<String, dynamic> query,
    AnalysisCallback? callback,
    AnalysisErrorCallback? errorCallback,
    Move? nextMove,
    GameNode? node,
  ) {
    if (!query.containsKey('id')) {
      _queryCounter += 1;
      query['id'] = 'QUERY:$_queryCounter';
    }
    final ponder = (query.remove(ponderKey) as bool?) ?? false;
    if (ponder) {
      final pq = _ponderQuery ?? const <String, dynamic>{};
      // replace the active pondering query only when its position or settings change
      final keys = {...query.keys, ...pq.keys}..removeAll(['id', 'maxVisits', 'reportDuringSearchEvery']);
      final differs = keys.any((k) => !_deepEquals(pq[k], query[k]));
      if (!differs) return;
      stopPondering();
      query['maxVisits'] = 10000000;
      query['reportDuringSearchEvery'] = ponderingReportDt;
      _ponderQuery = query;
    }
    final terminate = query['action'] == 'terminate';
    final id = query['id'] as String;
    if (!terminate) {
      _queries[id] = _Query(callback, errorCallback, DateTime.now(), nextMove, node);
      if (_remote) _sentPayloads[id] = query;
    }
    final tag = ponder ? 'ponder ' : (terminate ? 'terminate ' : '');
    final payload = jsonEncode(query);
    host.log('Sending ${tag}query $id: $payload', outputDebug);
    conn.send(payload);
  }

  /// Python's `==` on JSON-like values (1 == 1.0, dicts regardless of key order).
  static bool _deepEquals(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !_deepEquals(a[k], b[k])) return false;
      }
      return true;
    }
    return a == b;
  }

  /// Payloads of the queries still waiting, to send again on a new connection (remote engine).
  List<String> outstandingPayloads() => [
    for (final id in _queries.keys)
      if (_sentPayloads.containsKey(id)) jsonEncode(_sentPayloads[id]),
  ];

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
    final nodes = analysisNode.nodesFromRoot;
    final moves = [for (final node in nodes) ...node.moves];
    final initialStones = [for (final node in nodes) ...node.placements];
    final clearPlacements = [for (final node in nodes) ...node.clearPlacements];
    if (clearPlacements.isNotEmpty) {
      host.log('Not analyzing node $analysisNode as there are AE commands in the path', outputDebug);
      return;
    }
    if (nextMove != null) moves.add(nextMove);
    final includeOwnership = ownership ?? ((config['_enable_ownership'] as bool? ?? false) && nextMove == null);

    var maxVisits = visits;
    if (maxVisits == null) {
      maxVisits = config['max_visits'] as int;
      if (analyzeFast && config['fast_visits'] != null && config['fast_visits'] != 0) {
        maxVisits = config['fast_visits'] as int;
      }
    }

    final (sizeX, sizeY) = analysisNode.boardSize;
    List<Map<String, dynamic>> avoid;
    if (findAlternatives) {
      avoid = [
        {
          'moves': (analysisNode.analysis['moves'] as Map<String, dynamic>).keys.toList(),
          'player': analysisNode.nextPlayer,
          'untilDepth': 1,
        },
      ];
    } else if (regionOfInterest != null && regionOfInterest.isNotEmpty) {
      final [xmin, xmax, ymin, ymax] = regionOfInterest;
      avoid = [
        for (final player in ['B', 'W'])
          {
            'moves': [
              for (var x = 0; x < sizeX; x++)
                for (var y = 0; y < sizeY; y++)
                  if (x < xmin || x > xmax || y < ymin || y > ymax) Move(coords: (x, y)).gtp(),
            ],
            'player': player,
            'untilDepth': 1, // tried a large number here, or 2, but this seems more natural
          },
      ];
    } else {
      avoid = [];
    }

    final settings = <String, dynamic>{...overrideSettings, 'wideRootNoise': config['wide_root_noise']};
    if (timeLimit) settings['maxTime'] = config['max_time'];

    final query = <String, dynamic>{
      'rules': getRules(analysisNode.ruleset),
      'priority': basePriority + priority,
      'analyzeTurns': [moves.length],
      'maxVisits': maxVisits,
      'komi': analysisNode.komi,
      'boardXSize': sizeX,
      'boardYSize': sizeY,
      'includeOwnership': includeOwnership && nextMove == null,
      'includeMovesOwnership': includeOwnership && nextMove == null,
      'includePolicy': includePolicy,
      'initialStones': [
        for (final m in initialStones) [m.player, m.gtp()],
      ],
      'initialPlayer': analysisNode.initialPlayer,
      'moves': [
        for (final m in moves) [m.player, m.gtp()],
      ],
      'overrideSettings': {...settings, ...?extraSettings},
      ponderKey: ponder,
    };
    if (reportEvery != null) query['reportDuringSearchEvery'] = reportEvery;
    if (avoid.isNotEmpty) query['avoidMoves'] = avoid;
    sendQuery(query, callback, errorCallback, nextMove: nextMove, node: analysisNode);
    analysisNode.analysisVisitsRequested = math.max(analysisNode.analysisVisitsRequested, maxVisits);
  }

  /// One line from KataGo's stdout (local engine).
  void handleLine(String raw) {
    if (_stdoutStopped) return;
    final line = raw.trim();
    if (line.isEmpty) return;
    if (line.contains('Uncaught exception')) {
      _stdoutStopped = true;
      onError('KataGo Engine Failed: $line', katagoException);
      return;
    }
    try {
      final analysis = jsonDecode(line) as Map<String, dynamic>;
      if (!analysis.containsKey('id')) {
        host.log('Error without ID $analysis received from KataGo', outputError);
        return;
      }
      final queryId = analysis['id'] as String;
      final query = _queries[queryId];
      if (query == null) {
        if (analysis['action'] != 'terminate') {
          host.log('Query result $queryId discarded -- recent new game or node reset?', outputDebug);
        }
        return;
      }
      if (analysis.containsKey('error')) {
        _queries.remove(queryId);
        if (query.errorCallback != null) {
          query.errorCallback!(analysis);
        } else if (!(query.nextMove != null && (analysis['error'] as String).contains('Illegal move'))) {
          // a sweep tries illegal moves on purpose
          host.log('$analysis received from KataGo', outputError);
        }
      } else if (analysis.containsKey('warning')) {
        host.log('$analysis received from KataGo', outputDebug);
      } else if (analysis.containsKey('terminateId')) {
        host.log('$analysis received from KataGo', outputDebug);
      } else {
        _deliverResult(queryId, query, analysis);
      }
      host.onEngineUpdate();
    } catch (e) {
      host.log('Unexpected exception $e while processing KataGo output $line', outputError);
    }
  }

  /// One line from KataGo's stderr (local engine).
  void handleStderrLine(String line) {
    if (_stderrStopped) return;
    if (line.contains('Uncaught exception') || line.contains('what()')) {
      _stderrStopped = true;
      final message = line.length > 9 ? line.substring(9).trim() : line.trim();
      onError('KataGo Engine Failed: $message', katagoException);
      return;
    }
    host.log(line.trim(), outputKatagoStderr);
  }

  /// One response from a remote KataGo (remote engine): warnings are shown and the result still delivered.
  void handleRemoteLine(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return;
    Map<String, dynamic> analysis;
    try {
      analysis = jsonDecode(line) as Map<String, dynamic>;
    } on FormatException catch (e) {
      host.log('Bad JSON from remote KataGo: $e (line: ${line.substring(0, math.min(200, line.length))})', outputError);
      return;
    }
    try {
      if (!analysis.containsKey('id')) {
        host.log('Error without ID $analysis received from remote KataGo', outputError);
        return;
      }
      final queryId = analysis['id'] as String;
      final query = _queries[queryId];
      if (query == null) {
        if (analysis['action'] != 'terminate') {
          host.log('Query result $queryId discarded -- recent new game or node reset?', outputDebug);
        }
        return;
      }
      if (analysis.containsKey('warning')) {
        final warning = pyStr(analysis['warning']);
        host.log('Remote KataGo warning: $warning', outputInfo);
        host.setStatus(warning);
      }
      if (analysis.containsKey('error')) {
        _queries.remove(queryId);
        _sentPayloads.remove(queryId);
        if (query.errorCallback != null) {
          query.errorCallback!(analysis);
        } else if (!(query.nextMove != null && (analysis['error'] as String).contains('Illegal move'))) {
          host.log('$analysis received from remote KataGo', outputError);
        }
      } else if (analysis.containsKey('terminateId')) {
        host.log('$analysis received from remote KataGo', outputDebug);
      } else {
        _deliverResult(queryId, query, analysis);
      }
      host.onEngineUpdate();
    } catch (e) {
      host.log('Unexpected exception $e processing remote KataGo output: $line', outputError);
    }
  }

  void _deliverResult(String queryId, _Query query, Map<String, dynamic> analysis) {
    final partial = (analysis['isDuringSearch'] as bool?) ?? false;
    if (!partial) {
      _queries.remove(queryId);
      _sentPayloads.remove(queryId);
    }
    final seconds = DateTime.now().difference(query.startTime).inMicroseconds / 1e6;
    final resultsExist = !((analysis['noResults'] as bool?) ?? false);
    final candidates = (analysis['moveInfos'] as List?)?.length ?? 0;
    final visits = resultsExist ? (analysis['rootInfo'] as Map<String, dynamic>)['visits'] : 'n/a';
    host.log(
      '[${pyFixed(seconds, 1)}][$queryId][${partial ? '....' : 'done'}] KataGo analysis received: '
      '$candidates candidate moves, $visits visits',
      outputDebug,
    );
    try {
      if (query.callback != null && resultsExist) query.callback!(analysis, partial);
    } catch (e) {
      host.log('Error in engine callback for query $queryId: $e', outputError);
    }
  }

  /// A restarted process starts with fresh readers (KaTrain starts new threads).
  void resetReaders() {
    _stdoutStopped = false;
    _stderrStopped = false;
  }

  /// The process ended or the connection was lost (local engine, KaTrain's `check_alive(exception_if_dead=True)`).
  void onProcessExit(int? exitCode, {String osError = '', bool maybeOpenRecovery = false}) {
    if (exitCode == null) {
      host.log(pyFormat(i18n.tr('Engine died unexpectedly'), {'error': osError}), outputDebug);
      return;
    }
    final died = exitCode == 3221225781
        ? i18n.tr('Engine missing DLL')
        : pyFormat(i18n.tr('Engine died unexpectedly'), {'error': '$osError status $exitCode'});
    if (exitCode != 1) {
      // 1 is a deliberate exit
      onError(died, exitCode, allowPopup: maybeOpenRecovery);
    }
  }
}
