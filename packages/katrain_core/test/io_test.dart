// Transports: a real local KataGo (only when KATAGO_EXE, KATAGO_MODEL and KATAGO_CONFIG are set), and a remote
// KataGo played by a local WebSocket server that drops the first connection.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

class TestHost implements EngineHost {
  final List<String> logs = [];
  final List<List<Object?>> errors = [];
  final List<String> statuses = [];

  @override
  void log(String message, num level) => logs.add(message);

  @override
  void onEngineError(String message, Object? code, {required bool allowPopup, required String engineType}) =>
      errors.add([message, code, allowPopup]);

  @override
  void onEngineUpdate() {}

  @override
  void setStatus(String message) => statuses.add(message);
}

Map<String, dynamic> engineConfig(Map<String, dynamic> extra) => {
  'max_visits': 30,
  'fast_visits': 10,
  'max_time': 5.0,
  'wide_root_noise': 0.0,
  '_enable_ownership': true,
  ...extra,
};

void main() {
  final env = Platform.environment;
  final haveKataGo = ['KATAGO_EXE', 'KATAGO_MODEL', 'KATAGO_CONFIG'].every((k) => (env[k] ?? '').isNotEmpty);

  test('local KataGo analyses a position', () async {
    final host = TestHost();
    final (engine, connection) = await makeEngine(
      host,
      engineConfig({'katago': env['KATAGO_EXE'], 'model': env['KATAGO_MODEL'], 'config': env['KATAGO_CONFIG']}),
      resourceDir: '.',
    );
    final local = connection as LocalKataGo;
    expect(local.alive, isTrue, reason: host.errors.join('\n'));
    final node = gameParser.parseSgf('(;SZ[9]KM[7]RU[chinese];B[ee])').children[0];
    final done = Completer<Map<String, dynamic>>();
    node.analyze(engine, visits: 30);
    engine.requestAnalysis(
      node,
      visits: 30,
      callback: (result, partial) {
        if (!partial && !done.isCompleted) done.complete(result);
      },
    );
    final result = await done.future.timeout(const Duration(minutes: 3));
    expect((result['rootInfo'] as Map)['visits'], greaterThan(0));
    expect((result['moveInfos'] as List), isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(node.analysisExists, isTrue);
    await local.shutdown();
    expect(local.alive, isFalse);
    expect(host.errors, isEmpty);
  }, skip: haveKataGo ? false : 'set KATAGO_EXE, KATAGO_MODEL and KATAGO_CONFIG to run');

  test('a missing KataGo executable is reported', () async {
    final host = TestHost();
    final (_, connection) = await makeEngine(
      host,
      engineConfig({'katago': '/no/such/katago', 'model': 'm.bin.gz', 'config': 'c.cfg'}),
      resourceDir: '.',
    );
    expect((connection as LocalKataGo).alive, isFalse);
    expect(host.errors.single[1], 'KATAGO-EXE');
  });

  test('remote KataGo: reconnects and resends outstanding queries', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var connections = 0;
    final received = <String>[];
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      connections++;
      final thisConnection = connections;
      ws.listen((message) {
        final query = jsonDecode(message as String) as Map<String, dynamic>;
        received.add('$thisConnection:${query['id']}');
        if (thisConnection == 1) {
          ws.close(4000, 'going away'); // drop the first connection before answering
          return;
        }
        ws.add(
          jsonEncode({
            'id': query['id'],
            'isDuringSearch': false,
            'rootInfo': {'visits': 7, 'winrate': 0.5, 'scoreLead': 0.0},
            'moveInfos': [],
          }),
        );
      });
    });

    final host = TestHost();
    final engine = KataGoEngine(
      host,
      engineConfig({'remote_url': 'ws://127.0.0.1:${server.port}'}),
      engineType: 'remote',
    );
    final remote = RemoteKataGo(engine)..sleep = (_) async {};
    expect(await remote.start(), isTrue);
    final node = gameParser.parseSgf('(;SZ[9];B[cc])').children[0];
    final done = Completer<int>();
    engine.requestAnalysis(
      node,
      callback: (result, partial) => done.complete((result['rootInfo'] as Map)['visits'] as int),
    );
    expect(await done.future.timeout(const Duration(seconds: 10)), 7);
    expect(received, ['1:QUERY:1', '2:QUERY:1']);
    expect(host.statuses.last, 'Reconnected to remote KataGo.');
    expect(host.errors, isEmpty);
    await remote.shutdown();
    await server.close(force: true);
  });

  test('remote KataGo: invalid URLs are reported without a popup', () async {
    final host = TestHost();
    final engine = KataGoEngine(host, engineConfig({'remote_url': 'http://example.com'}), engineType: 'remote');
    expect(await RemoteKataGo(engine).start(), isFalse);
    // KaTrain only logs this one: no recovery popup
    expect(host.errors, isEmpty);
    expect(host.logs.last, contains('ws://'));
  });
}
