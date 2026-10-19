// Differential tests: the queries written to KataGo and the handling of its answers must match KaTrain
// (fixtures from tools/fixtures/engine_fixtures.py).

import 'dart:convert';

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'fixtures_util.dart';

class RecordingConnection implements EngineConnection {
  final List<String> written = [];

  @override
  bool alive = true;

  @override
  void send(String line) => written.add(line);

  @override
  Future<void> close() async => alive = false;
}

class RecordingHost implements EngineHost {
  int updates = 0;
  final List<List<Object?>> errors = [];
  final List<String> statuses = [];

  @override
  void log(String message, num level) {}

  @override
  void onEngineError(String message, Object? code, {required bool allowPopup, required String engineType}) =>
      errors.add([message, code, engineType]);

  @override
  void onEngineUpdate() => updates++;

  @override
  void setStatus(String message) => statuses.add(message);
}

Iterable<GameNode> preorder(GameNode root) sync* {
  final stack = [root];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    yield node;
    stack.addAll(node.children.reversed);
  }
}

void main() {
  test('queries and answers match KaTrain step by step', () {
    final data = loadFixture('engine.json');
    final host = RecordingHost();
    final engine = KataGoEngine(host, Map<String, dynamic>.of(data['config'] as Map<String, dynamic>));
    final connection = RecordingConnection();
    engine.connection = connection;
    final root = gameParser.parseSgf(data['sgf'] as String);
    final nodes = preorder(root).toList();
    final events = <List<Object?>>[];

    List<Object?> takeWritten() {
      final w = [for (final line in connection.written) jsonDecode(line)];
      connection.written.clear();
      return w;
    }

    nodes[2].setAnalysis(
      // as KataGo's JSON arrives: dynamic maps
      jsonDecode(
        jsonEncode({
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
        }),
      ) as Map<String, dynamic>,
      null,
      false,
      null,
      false,
    );

    for (final step in (data['steps'] as List).cast<Map<String, dynamic>>()) {
      switch (step['op']) {
        case 'request':
          final node = nodes[step['node'] as int];
          final tag = step['tag'] as String;
          final kw = step['kwargs'] as Map<String, dynamic>;
          final nextMove = step['next_move'] == null
              ? null
              : Move.fromGtp(step['next_move'] as String, player: node.nextPlayer);
          engine.requestAnalysis(
            node,
            callback: (result, partial) =>
                events.add(['callback', tag, result['id'], partial, (result['rootInfo'] as Map)['visits']]),
            errorCallback: (step['error_callback'] as bool)
                ? (result) => events.add(['error_callback', tag, result['id'], result['error']])
                : null,
            nextMove: nextMove,
            visits: kw['visits'] as int?,
            analyzeFast: (kw['analyze_fast'] as bool?) ?? false,
            timeLimit: (kw['time_limit'] as bool?) ?? true,
            findAlternatives: (kw['find_alternatives'] as bool?) ?? false,
            regionOfInterest: (kw['region_of_interest'] as List?)?.cast<int>(),
            priority: (kw['priority'] as int?) ?? 0,
            ponder: (kw['ponder'] as bool?) ?? false,
            ownership: kw['ownership'] as bool?,
            extraSettings: kw['extra_settings'] as Map<String, dynamic>?,
            includePolicy: (kw['include_policy'] as bool?) ?? true,
            reportEvery: (kw['report_every'] as num?)?.toDouble(),
          );
          expect(takeWritten(), step['written'], reason: 'written for $tag');
          expect(node.analysisVisitsRequested, step['visits_requested'], reason: 'visits requested for $tag');
        case 'lines':
          events.clear();
          final before = host.updates;
          for (final line in (step['lines'] as List).cast<String>()) {
            engine.handleLine(line);
          }
          expect(events, step['events'], reason: 'callbacks');
          expect(host.updates - before, step['updates'], reason: 'updates');
          expect(engine.outstandingQueries.toList()..sort(), step['outstanding']);
        case 'terminate_query':
          engine.terminateQuery(step['query'] as String);
          expect(takeWritten(), step['written']);
          expect(engine.outstandingQueries.toList()..sort(), step['outstanding']);
        case 'terminate_queries_for_node':
          engine.terminateQueries(onlyForNode: nodes[step['node'] as int]);
          expect(takeWritten(), step['written']);
          expect(engine.outstandingQueries.toList()..sort(), step['outstanding']);
        case 'stop_pondering':
          engine.stopPondering();
          expect(takeWritten(), step['written']);
          expect(engine.outstandingQueries.toList()..sort(), step['outstanding']);
        case 'on_new_game':
          engine.onNewGame();
          expect(takeWritten(), step['written']);
          expect(engine.outstandingQueries.toList()..sort(), step['outstanding']);
        default:
          fail('unknown step ${step['op']}');
      }
    }
    expect(host.errors, data['errors']);
  });

  test('no connection: nothing is written, visits are still recorded', () {
    final engine = KataGoEngine(RecordingHost(), {
      'max_visits': 500,
      'fast_visits': 25,
      'max_time': 8.0,
      'wide_root_noise': 0.04,
      '_enable_ownership': true,
    });
    final node = gameParser.parseSgf('(;SZ[9];B[cc])').children[0];
    engine.requestAnalysis(node, callback: (_, _) {});
    expect(node.analysisVisitsRequested, 500);
    expect(engine.queriesRemaining(), 1);
  });

  test('remote answers: a warning is shown and the result still delivered', () {
    final host = RecordingHost();
    final engine = KataGoEngine(host, {
      'max_visits': 10,
      'fast_visits': 5,
      'max_time': 1.0,
      'wide_root_noise': 0.0,
      '_enable_ownership': false,
    }, engineType: 'remote');
    final connection = RecordingConnection();
    engine.connection = connection;
    final node = gameParser.parseSgf('(;SZ[9];B[cc])').children[0];
    final results = <bool>[];
    engine.requestAnalysis(node, callback: (_, partial) => results.add(partial));
    final id = (jsonDecode(connection.written.single) as Map)['id'];
    engine.handleRemoteLine(
      jsonEncode({
        'id': id,
        'warning': 'slow',
        'rootInfo': {'visits': 10},
        'moveInfos': [],
      }),
    );
    expect(host.statuses, ['slow']);
    expect(results, [false]);
    expect(engine.outstandingPayloads(), isEmpty);
  });

  test('backend selection', () {
    expect(resolveEngineBackend({'backend': 'Remote'}), 'remote');
    expect(resolveEngineBackend({'remote_url': 'ws://x'}), 'remote');
    expect(resolveEngineBackend({'altcommand': 'katago ...'}), 'custom');
    expect(resolveEngineBackend({}), 'local');
  });
}
