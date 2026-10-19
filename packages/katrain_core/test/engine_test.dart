// Behaviour tests for KataGoEngine without a KataGo process: the analysis queries it writes (KataGo's JSON analysis
// protocol), how it keeps track of them, and how it hands KataGo's answers to the callbacks.

import 'dart:convert';

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

class RecordingConnection implements EngineConnection {
  final List<String> written = [];

  @override
  bool alive = true;

  @override
  void send(String line) => written.add(line);

  @override
  Future<void> close() async => alive = false;

  /// The decoded lines written since the last call.
  List<Map<String, dynamic>> take() {
    final lines = [for (final line in written) jsonDecode(line) as Map<String, dynamic>];
    written.clear();
    return lines;
  }
}

class RecordingHost implements EngineHost {
  int updates = 0;
  final List<(String, num)> logs = [];
  final List<(String, Object?, String)> errors = [];
  final List<String> statuses = [];

  List<String> get errorLogs => [
    for (final (message, level) in logs)
      if (level == outputError) message,
  ];

  @override
  void log(String message, num level) => logs.add((message, level));

  @override
  void onEngineError(String message, Object? code, {required bool allowPopup, required String engineType}) =>
      errors.add((message, code, engineType));

  @override
  void onEngineUpdate() => updates++;

  @override
  void setStatus(String message) => statuses.add(message);
}

/// Handicap 2 on 9x9, white to play; the second variation clears a stone (AE).
const gameSgf =
    '(;GM[1]FF[4]SZ[9]KM[5.5]RU[chinese]HA[2]AB[cc][gg]PL[W]'
    ';W[ee];B[ec];W[ce](;B[dd];W[gc];B[cg])(;B[dc];AE[ee];W[ff]))';

Map<String, dynamic> defaultConfig() => {
  'max_visits': 500,
  'fast_visits': 25,
  'max_time': 8.0,
  'wide_root_noise': 0.04,
  '_enable_ownership': true,
};

/// The main line of [sgf]: root, then the first child at every step.
List<GameNode> mainLine(String sgf) {
  final nodes = [gameParser.parseSgf(sgf)];
  while (nodes.last.children.isNotEmpty) {
    nodes.add(nodes.last.children.first);
  }
  return nodes;
}

/// A KataGo answer line for query [id].
String answer(String id, {int visits = 10, bool? partial, Map<String, dynamic> extra = const {}}) => jsonEncode({
  'id': id,
  'isDuringSearch': ?partial,
  'turnNumber': 1,
  'rootInfo': {'visits': visits, 'winrate': 0.5, 'scoreLead': 1.0},
  'moveInfos': [
    {
      'move': 'D4',
      'order': 0,
      'visits': visits,
      'winrate': 0.5,
      'scoreLead': 1.0,
      'pv': ['D4'],
    },
  ],
  ...extra,
});

void main() {
  late RecordingHost host;
  late RecordingConnection connection;
  late KataGoEngine engine;
  late List<GameNode> line; // root, W E5, B E7, W C5, B D6, W G7, B C3
  late GameNode aeNode; // the node with AE in the second variation (B D7, AE E5, W F4)

  /// Results delivered to callbacks: (tag, id, partial, visits).
  late List<(String, String, bool, int)> results;
  late List<(String, String, String)> errorResults;

  void cb(String tag, Map<String, dynamic> result, bool partial) =>
      results.add((tag, result['id'] as String, partial, (result['rootInfo'] as Map)['visits'] as int));

  /// Requests an analysis and returns the queries written for it.
  List<Map<String, dynamic>> request(
    GameNode node, {
    String tag = '',
    bool withErrorCallback = false,
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
    engine.requestAnalysis(
      node,
      callback: (result, partial) => cb(tag, result, partial),
      errorCallback: withErrorCallback
          ? (result) => errorResults.add((tag, result['id'] as String, result['error'] as String))
          : null,
      visits: visits,
      analyzeFast: analyzeFast,
      timeLimit: timeLimit,
      findAlternatives: findAlternatives,
      regionOfInterest: regionOfInterest,
      priority: priority,
      ponder: ponder,
      ownership: ownership,
      nextMove: nextMove,
      extraSettings: extraSettings,
      includePolicy: includePolicy,
      reportEvery: reportEvery,
    );
    return connection.take();
  }

  /// Requests an analysis that should be written as exactly one query, and returns it.
  Map<String, dynamic> query(GameNode node, {String tag = '', int? visits, bool ponder = false, int priority = 0}) =>
      request(node, tag: tag, visits: visits, ponder: ponder, priority: priority).single;

  setUp(() {
    host = RecordingHost();
    connection = RecordingConnection();
    engine = KataGoEngine(host, defaultConfig())..connection = connection;
    line = mainLine(gameSgf);
    aeNode = line[3].children[1].children[0];
    results = [];
    errorResults = [];
  });

  group('queries', () {
    test('a query describes the position: rules, komi, board, setup stones and moves', () {
      expect(query(line[3]), {
        'id': 'QUERY:1',
        'rules': 'chinese',
        'priority': 0,
        'analyzeTurns': [3],
        'maxVisits': 500,
        'komi': 5.5,
        'boardXSize': 9,
        'boardYSize': 9,
        'includeOwnership': true,
        'includeMovesOwnership': true,
        'includePolicy': true,
        'initialStones': [
          ['B', 'C7'],
          ['B', 'G3'],
        ],
        'initialPlayer': 'W',
        'moves': [
          ['W', 'E5'],
          ['B', 'E7'],
          ['W', 'C5'],
        ],
        'overrideSettings': {'reportAnalysisWinratesAs': 'BLACK', 'wideRootNoise': 0.04, 'maxTime': 8.0},
      });
      expect(line[3].analysisVisitsRequested, 500);
    });

    test('the root position is analysed with no moves', () {
      final q = query(line[0]);
      expect(q['moves'], isEmpty);
      expect(q['analyzeTurns'], [0]);
      expect(q['initialStones'], hasLength(2));
    });

    test('queries get unique ids', () {
      final ids = [for (var i = 0; i < 4; i++) query(line[i])['id']];
      expect(ids, ['QUERY:1', 'QUERY:2', 'QUERY:3', 'QUERY:4']);
      expect(engine.outstandingQueries, unorderedEquals(ids));
    });

    test('rules, komi and board size come from the root', () {
      Map<String, dynamic> queryFor(String sgf) => query(mainLine(sgf).last);
      expect(queryFor('(;SZ[9];B[ee])')['rules'], 'japanese');
      expect(queryFor('(;SZ[9]RU[jp];B[ee])')['rules'], 'japanese');
      expect(queryFor('(;SZ[9]RU[Korean];B[ee])')['rules'], 'korean');
      expect(queryFor('(;SZ[9]RU[tt];B[ee])')['rules'], 'tromp-taylor');
      expect(queryFor('(;SZ[9]RU[unheard of];B[ee])')['rules'], 'japanese');
      expect(queryFor('(;SZ[9]RU[{"ko":"POSITIONAL","scoring":"AREA"}];B[ee])')['rules'], {
        'ko': 'POSITIONAL',
        'scoring': 'AREA',
      });
      final q = queryFor('(;SZ[13:9];B[aa])');
      expect(q['komi'], 6.5);
      expect([q['boardXSize'], q['boardYSize']], [13, 9]);
      expect(q['moves'], [
        ['B', 'A9'],
      ]);
      expect(queryFor('(;SZ[9]KM[0];B[ee])')['komi'], 0);
    });

    test('visits: explicit, fast, or the configured maximum; the node remembers the most requested', () {
      expect(query(line[1])['maxVisits'], 500);
      expect(request(line[1], visits: 1234).single['maxVisits'], 1234);
      expect(line[1].analysisVisitsRequested, 1234);
      expect(request(line[1], visits: 50).single['maxVisits'], 50);
      expect(line[1].analysisVisitsRequested, 1234);

      expect(request(line[2], analyzeFast: true).single['maxVisits'], 25);
      expect(line[2].analysisVisitsRequested, 25);
      expect(request(line[2], analyzeFast: true, visits: 7).single['maxVisits'], 7);

      engine.config['fast_visits'] = 0; // no fast visits configured
      expect(request(line[3], analyzeFast: true).single['maxVisits'], 500);
    });

    test('time limit: the configured maximum time, unless turned off', () {
      expect((query(line[1])['overrideSettings'] as Map)['maxTime'], 8.0);
      final noLimit = request(line[1], timeLimit: false).single;
      expect((noLimit['overrideSettings'] as Map).containsKey('maxTime'), isFalse);
      expect(noLimit['maxVisits'], 500);
    });

    test('ownership is requested as configured, or as asked; policy unless turned off', () {
      final off = request(line[1], ownership: false, includePolicy: false).single;
      expect([off['includeOwnership'], off['includeMovesOwnership'], off['includePolicy']], [false, false, false]);

      engine.config['_enable_ownership'] = false;
      final notConfigured = query(line[1]);
      expect([notConfigured['includeOwnership'], notConfigured['includeMovesOwnership']], [false, false]);
      final asked = request(line[1], ownership: true).single;
      expect([asked['includeOwnership'], asked['includeMovesOwnership']], [true, true]);
    });

    test('a next move is analysed as one more move, without ownership', () {
      final q = request(line[3], nextMove: Move.fromGtp('D4', player: 'B'), ownership: true).single;
      expect(q['moves'], [
        ['W', 'E5'],
        ['B', 'E7'],
        ['W', 'C5'],
        ['B', 'D4'],
      ]);
      expect(q['analyzeTurns'], [4]);
      expect([q['includeOwnership'], q['includeMovesOwnership']], [false, false]);
    });

    test('a region of interest: both players avoid every point outside it on the first move', () {
      // columns B-E, rows 3-7
      final q = request(line[3], regionOfInterest: [1, 4, 2, 6]).single;
      final avoid = (q['avoidMoves'] as List).cast<Map<String, dynamic>>();
      expect([for (final a in avoid) a['player']], ['B', 'W']);
      expect([for (final a in avoid) a['untilDepth']], [1, 1]);
      final inside = {
        for (final c in 'BCDE'.split(''))
          for (var r = 3; r <= 7; r++) '$c$r',
      };
      final all = {
        for (final c in 'ABCDEFGHJ'.split(''))
          for (var r = 1; r <= 9; r++) '$c$r',
      };
      for (final a in avoid) {
        final moves = (a['moves'] as List).cast<String>();
        expect(moves.toSet(), all.difference(inside));
        expect(moves, hasLength(81 - 20));
      }
      expect(query(line[3]).containsKey('avoidMoves'), isFalse);
      expect(request(line[3], regionOfInterest: []).single.containsKey('avoidMoves'), isFalse);
    });

    test('finding alternatives: the player to move avoids the moves already analysed', () {
      final analysis = {
        'rootInfo': {'visits': 10, 'winrate': 0.5, 'scoreLead': 0.0},
        'moveInfos': [
          {
            'move': 'D5',
            'order': 0,
            'visits': 6,
            'winrate': 0.5,
            'scoreLead': 0.0,
            'pv': ['D5'],
          },
          {
            'move': 'F4',
            'order': 1,
            'visits': 4,
            'winrate': 0.4,
            'scoreLead': -1.0,
            'pv': ['F4'],
          },
        ],
      };
      line[2].setAnalysis(jsonDecode(jsonEncode(analysis)) as Map<String, dynamic>, null, false, null, false);
      final q = request(line[2], findAlternatives: true).single;
      expect(q['avoidMoves'], [
        {
          'moves': ['D5', 'F4'],
          'player': 'W',
          'untilDepth': 1,
        },
      ]);
    });

    test('priority, extra settings and report interval', () {
      final q = request(
        line[1],
        priority: 100,
        extraSettings: {'playoutDoublingAdvantage': 0.5, 'wideRootNoise': 0.1},
        reportEvery: 0.5,
      ).single;
      expect(q['priority'], 100);
      expect(q['overrideSettings'], {
        'reportAnalysisWinratesAs': 'BLACK',
        'wideRootNoise': 0.1,
        'maxTime': 8.0,
        'playoutDoublingAdvantage': 0.5,
      });
      expect(q['reportDuringSearchEvery'], 0.5);
      expect(query(line[1]).containsKey('reportDuringSearchEvery'), isFalse);
    });

    test('a position with stones cleared (AE) on the way is not analysed', () {
      expect(request(aeNode), isEmpty);
      expect(request(aeNode.children.single), isEmpty);
      expect(aeNode.analysisVisitsRequested, 0);
      expect(engine.outstandingQueries, isEmpty);
      // the node before it is fine
      expect(request(aeNode.parent!), hasLength(1));
    });
  });

  group('pondering', () {
    test('a pondering query searches until stopped and reports often', () {
      final q = query(line[3], ponder: true);
      expect(q['maxVisits'], 10000000);
      expect(q['reportDuringSearchEvery'], ponderingReportDt);
      expect(q.containsKey(KataGoEngine.ponderKey), isFalse);
      expect(engine.outstandingQueries, [q['id']]);
    });

    test('pondering the same position again sends nothing', () {
      query(line[3], ponder: true);
      expect(request(line[3], ponder: true), isEmpty);
      expect(request(line[3], ponder: true, visits: 99), isEmpty);
      expect(engine.outstandingQueries, hasLength(1));
    });

    test('pondering another position stops the previous pondering query first', () {
      final first = query(line[3], ponder: true);
      final written = request(line[4], ponder: true);
      expect(written, hasLength(2));
      final terminate = written.firstWhere((q) => q['action'] == 'terminate');
      final second = written.firstWhere((q) => q['action'] == null);
      expect(terminate['terminateId'], first['id']);
      expect(second['moves'], hasLength(4));
      expect(second['maxVisits'], 10000000);
      // the stopped query still delivers its last result
      engine.handleLine(answer(first['id'] as String, visits: 800));
      expect(results, [('', first['id'], false, 800)]);
      expect(engine.outstandingQueries, [second['id']]);
    });

    test('stopping pondering terminates the query and lets its final result through', () {
      expect(() => engine.stopPondering(), returnsNormally);
      expect(connection.take(), isEmpty);

      final q = query(line[3], ponder: true);
      engine.stopPondering();
      expect(connection.take(), [
        {'action': 'terminate', 'terminateId': q['id'], 'id': 'QUERY:2'},
      ]);
      engine.handleLine(answer(q['id'] as String, visits: 300, partial: false));
      expect(results.single.$4, 300);
      // pondering again starts a new query, even for the same position
      expect(query(line[3], ponder: true)['id'], 'QUERY:3');
    });
  });

  group('results', () {
    test('partial results arrive with the partial flag; the query is done after the final one', () {
      final id = query(line[1], tag: 'a')['id'] as String;
      engine.handleLine(answer(id, visits: 20, partial: true));
      expect(engine.outstandingQueries, [id]);
      engine.handleLine(answer(id, visits: 40, partial: true));
      engine.handleLine(answer(id, visits: 500, partial: false));
      expect(results, [('a', id, true, 20), ('a', id, true, 40), ('a', id, false, 500)]);
      expect(engine.outstandingQueries, isEmpty);
      expect(engine.isIdle(), isTrue);
      expect(host.updates, 3);
    });

    test('a result without isDuringSearch is final', () {
      final id = query(line[1])['id'] as String;
      engine.handleLine(answer(id));
      expect(results.single.$3, isFalse);
      expect(engine.outstandingQueries, isEmpty);
    });

    test('results go to the callback of their own query', () {
      final a = query(line[1], tag: 'a')['id'] as String;
      final b = query(line[2], tag: 'b')['id'] as String;
      engine.handleLine(answer(b, visits: 2));
      engine.handleLine(answer(a, visits: 1));
      expect(results, [('b', b, false, 2), ('a', a, false, 1)]);
    });

    test('"no results" ends the query without a callback', () {
      final id = query(line[1])['id'] as String;
      engine.handleLine(answer(id, extra: {'noResults': true}));
      expect(results, isEmpty);
      expect(engine.outstandingQueries, isEmpty);
    });

    test('a warning is no result: the query keeps running', () {
      final id = query(line[1])['id'] as String;
      engine.handleLine(jsonEncode({'id': id, 'warning': 'unused field'}));
      expect(results, isEmpty);
      expect(engine.outstandingQueries, [id]);
      expect(host.errorLogs, isEmpty);
      engine.handleLine(answer(id));
      expect(results, hasLength(1));
    });

    test('an error goes to the error callback and ends the query', () {
      final id = request(line[1], tag: 'e', withErrorCallback: true).single['id'] as String;
      engine.handleLine(jsonEncode({'id': id, 'error': 'bad query', 'field': 'rules'}));
      expect(errorResults, [('e', id, 'bad query')]);
      expect(results, isEmpty);
      expect(engine.outstandingQueries, isEmpty);
      expect(host.errorLogs, isEmpty);
      expect(host.errors, isEmpty); // no recovery popup for a single failed query
    });

    test('an error without error callback is logged; an illegal next move is expected and is not', () {
      final plain = query(line[1])['id'] as String;
      final sweep = request(line[3], nextMove: Move.fromGtp('E5', player: 'B')).single['id'] as String;
      engine.handleLine(jsonEncode({'id': plain, 'error': 'something failed'}));
      engine.handleLine(jsonEncode({'id': sweep, 'error': 'Illegal move at E5'}));
      expect(host.errorLogs, [contains('something failed')]);
      expect(engine.outstandingQueries, isEmpty);
      expect(results, isEmpty);
      expect(host.errors, isEmpty);
    });

    test('lines that belong to no query are ignored', () {
      final id = query(line[1])['id'] as String;
      engine.handleLine(answer('QUERY:999')); // unknown, e.g. from before a new game
      engine.handleLine(jsonEncode({'id': 'QUERY:7', 'action': 'terminate', 'terminateId': id})); // acknowledged
      engine.handleLine('');
      expect(results, isEmpty);
      expect(host.errorLogs, isEmpty);
      expect(engine.outstandingQueries, [id]);
    });

    test('malformed lines are logged and do not stop the engine', () {
      final id = query(line[1])['id'] as String;
      engine.handleLine('{not json');
      engine.handleLine(jsonEncode({'no': 'id'}));
      expect(host.errorLogs, hasLength(2));
      engine.handleLine(answer(id));
      expect(results, hasLength(1));
      expect(host.errors, isEmpty);
    });

    test('a failing callback is logged and does not stop the engine', () {
      engine.requestAnalysis(line[1], callback: (_, _) => throw StateError('callback broke'));
      final failing = connection.take().single['id'] as String;
      final fine = query(line[2], tag: 'ok')['id'] as String;
      engine.handleLine(answer(failing));
      engine.handleLine(answer(fine));
      expect(host.errorLogs, [contains('callback broke')]);
      expect(results, [('ok', fine, false, 10)]);
      expect(engine.outstandingQueries, isEmpty);
    });

    test('a KataGo crash is reported once and further output is ignored until the readers restart', () {
      final id = query(line[1])['id'] as String;
      engine.handleLine('Uncaught exception: out of memory');
      expect(host.errors, [('KataGo Engine Failed: Uncaught exception: out of memory', katagoException, 'local')]);
      engine.handleLine(answer(id));
      expect(results, isEmpty);
      engine.resetReaders();
      engine.handleLine(answer(id));
      expect(results, hasLength(1));
    });

    test('a crash on stderr is reported; other stderr output is only logged', () {
      engine.handleStderrLine('loading model');
      expect(host.errors, isEmpty);
      expect(host.logs.last, ('loading model', outputKatagoStderr));
      engine.handleStderrLine('terminate called after throwing: what(): CUDA error');
      expect(host.errors.single.$1, startsWith('KataGo Engine Failed:'));
      expect(host.errors.single.$2, katagoException);
      engine.handleStderrLine('what(): again');
      expect(host.errors, hasLength(1));
    });

    test('without recovery, a crash is only logged', () {
      engine.config['allow_recovery'] = false;
      engine.handleLine('Uncaught exception: boom');
      expect(host.errors, isEmpty);
      expect(host.errorLogs.single, contains('boom'));
    });
  });

  group('terminating', () {
    test('a terminated query is cancelled in KataGo and its later results are ignored', () {
      final id = query(line[1])['id'] as String;
      final other = query(line[2])['id'] as String;
      engine.terminateQuery(id);
      expect(connection.take(), [
        {'action': 'terminate', 'terminateId': id, 'id': 'QUERY:3'},
      ]);
      expect(engine.outstandingQueries, [other]);
      engine.handleLine(answer(id, partial: false));
      expect(results, isEmpty);
    });

    test('queries can be terminated for one node, or all of them', () {
      final a = query(line[1])['id'];
      final b = query(line[1], visits: 5)['id'];
      final c = query(line[2])['id'];
      final d = query(line[3])['id'];
      engine.terminateQueries(onlyForNode: line[1]);
      expect([for (final q in connection.take()) q['terminateId']], unorderedEquals([a, b]));
      expect(engine.outstandingQueries, unorderedEquals([c, d]));
      engine.terminateQueries();
      expect([for (final q in connection.take()) q['terminateId']], unorderedEquals([c, d]));
      expect(engine.outstandingQueries, isEmpty);
    });

    test('a new game drops all queries and raises the priority of new ones', () {
      final old = query(line[1])['id'] as String;
      final oldPonder = query(line[2], ponder: true)['id'] as String;
      final generation = engine.queryGeneration;
      engine.onNewGame();
      expect([for (final q in connection.take()) q['terminateId']], unorderedEquals([old, oldPonder]));
      expect(engine.outstandingQueries, isEmpty);
      expect(engine.queryGeneration, generation + 1);

      final fresh = query(line[1], priority: 10);
      expect(fresh['priority'], 11);
      expect(fresh['id'], isNot(anyOf(old, oldPonder)));
      // pondering the old position again is a new query
      expect(request(line[2], ponder: true), hasLength(1));

      engine.handleLine(answer(old, visits: 99));
      engine.handleLine(answer(oldPonder, visits: 98));
      engine.handleLine(answer(fresh['id'] as String, visits: 77));
      expect(results, [('', fresh['id'], false, 77)]);
    });
  });

  group('connection', () {
    test('queries wait while there is no connection, and go out in order once there is', () {
      engine.connection = null;
      request(line[1], tag: 'first');
      expect(line[1].analysisVisitsRequested, 500);
      expect(engine.isIdle(), isFalse);
      expect(engine.queriesRemaining(), 1);
      expect(engine.outstandingQueries, isEmpty);

      engine.connection = connection;
      final written = request(line[2], tag: 'second');
      expect([for (final q in written) (q['moves'] as List).length], [1, 2]);
      expect([for (final q in written) q['id']], ['QUERY:1', 'QUERY:2']);
      engine.handleLine(answer('QUERY:1'));
      expect(results.single.$1, 'first');
    });

    test('a dead connection gets nothing; queued queries are dropped by a new game', () {
      connection.alive = false;
      request(line[1]);
      expect(connection.written, isEmpty);
      engine.onNewGame();
      connection.alive = true;
      final written = request(line[2]);
      expect(written.single['moves'], hasLength(2));
      expect(engine.isIdle(), isFalse);
      engine.handleLine(answer(written.single['id'] as String));
      expect(engine.isIdle(), isTrue);
    });

    test('process exits: a deliberate exit is quiet, others are reported', () {
      engine.onProcessExit(1, maybeOpenRecovery: true);
      expect(host.errors, isEmpty);
      engine.onProcessExit(null);
      expect(host.errors, isEmpty);
      engine.onProcessExit(139, osError: 'segfault', maybeOpenRecovery: true);
      expect(host.errors.single.$1, allOf(contains('segfault'), contains('139')));
      expect(host.errors.single.$2, 139);
      engine.onProcessExit(3221225781, maybeOpenRecovery: true);
      expect(host.errors.last.$1, i18n.tr('Engine missing DLL'));
      // without the recovery popup it is only logged
      engine.onProcessExit(2);
      expect(host.errors, hasLength(2));
      expect(host.errorLogs.last, contains('2'));
    });
  });

  group('remote', () {
    late KataGoEngine remote;
    setUp(() {
      remote = KataGoEngine(host, defaultConfig(), engineType: 'remote')..connection = connection;
    });

    String send(GameNode node) {
      remote.requestAnalysis(node, callback: (result, partial) => cb('remote', result, partial));
      return connection.take().single['id'] as String;
    }

    test('a warning is shown and the result still delivered', () {
      final id = send(line[1]);
      remote.handleRemoteLine(answer(id, extra: {'warning': 'slow'}));
      expect(host.statuses, ['slow']);
      expect(results, [('remote', id, false, 10)]);
      expect(remote.outstandingQueries, isEmpty);
    });

    test('outstanding queries are kept to be sent again after reconnecting', () {
      final a = send(line[1]);
      final b = send(line[2]);
      final c = send(line[3]);
      final resend = [for (final p in remote.outstandingPayloads()) jsonDecode(p) as Map<String, dynamic>];
      expect([for (final q in resend) q['id']], [a, b, c]);
      expect(resend[1]['moves'], hasLength(2));

      remote.handleRemoteLine(answer(a, partial: true));
      remote.handleRemoteLine(answer(b));
      remote.handleRemoteLine(jsonEncode({'id': c, 'error': 'rejected'}));
      final left = [for (final p in remote.outstandingPayloads()) (jsonDecode(p) as Map)['id']];
      expect(left, [a]);
      expect(host.errorLogs.single, contains('rejected'));
    });

    test('bad remote lines are logged', () {
      remote.handleRemoteLine('<html>');
      remote.handleRemoteLine(jsonEncode({'no': 'id'}));
      expect(host.errorLogs, hasLength(2));
      expect(results, isEmpty);
    });

    test('a new game forgets the queries to resend', () {
      send(line[1]);
      remote.onNewGame();
      expect(remote.outstandingPayloads(), isEmpty);
    });
  });

  test('backend selection', () {
    expect(resolveEngineBackend({'backend': 'Remote'}), 'remote');
    expect(resolveEngineBackend({'backend': 'local', 'remote_url': 'ws://x'}), 'local');
    expect(resolveEngineBackend({'remote_url': 'ws://x'}), 'remote');
    expect(resolveEngineBackend({'remote_url': '  '}), 'local');
    expect(resolveEngineBackend({'altcommand': 'katago ...'}), 'custom');
    expect(resolveEngineBackend({}), 'local');
  });
}
