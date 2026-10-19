// A stand-in for KataGo behind the real engine: it records the queries the app writes and answers them when the
// test says so, and builds an AppController on it.

import 'dart:convert';

import 'package:katrain_core/katrain_core.dart';
import 'package:katrain_neo/src/state/app_controller.dart';

/// Black's score lead for an analysis query; [moves] are the GTP moves played, oldest first.
typedef ScoreFor = double Function(List<String> moves, Map<String, dynamic> query);

/// The connection to a pretend KataGo: queries are kept until [answerPending] answers them. Every answer has the
/// first three points never played on as candidates, best first, each a point worse for the player to move; after
/// [passAfter] moves passing is best. Captures are not looked at, so long games would get illegal suggestions.
class FakeKataGo implements EngineConnection {
  final List<Map<String, dynamic>> pending = [];
  final List<Map<String, dynamic>> sent = [];
  final List<String> terminated = [];

  /// Black's lead in every answer; tests change it to make moves good or bad.
  ScoreFor scoreFor = (_, _) => 0;

  int passAfter = 20;

  @override
  bool alive = true;

  late final KataGoEngine engine;

  @override
  void send(String line) {
    final query = jsonDecode(line) as Map<String, dynamic>;
    if (query['action'] == 'terminate') {
      final id = query['terminateId'] as String;
      terminated.add(id);
      pending.removeWhere((q) => q['id'] == id);
    } else {
      sent.add(query);
      pending.add(query);
    }
  }

  @override
  Future<void> close() async => alive = false;

  /// The queries asking for many visits, as pondering does.
  Iterable<Map<String, dynamic>> get ponderQueries => sent.where((q) => (q['maxVisits'] as int) >= 1000000);

  /// Answers every pending query once; returns how many.
  int answerPending() {
    final queries = List.of(pending);
    pending.clear();
    for (final q in queries) {
      engine.handleLine(jsonEncode(answer(q)));
    }
    return queries.length;
  }

  /// KataGo's final result for [query].
  Map<String, dynamic> answer(Map<String, dynamic> query) {
    final sizeX = query['boardXSize'] as int;
    final sizeY = query['boardYSize'] as int;
    final moves = [for (final m in query['moves'] as List) (m as List)[1] as String];
    final occupied = {for (final m in query['initialStones'] as List) (m as List)[1] as String, ...moves};
    final empty = [
      if (moves.length >= passAfter) 'pass',
      for (var y = sizeY - 1; y >= 0; y--)
        for (var x = 0; x < sizeX; x++)
          if (!occupied.contains(Move(coords: (x, y)).gtp())) Move(coords: (x, y)).gtp(),
    ];
    final lead = scoreFor(moves, query);
    final blackToMove = moves.isEmpty
        ? query['initialPlayer'] == 'B'
        : ((query['moves'] as List).last as List)[0] == 'W';
    final sign = blackToMove ? 1 : -1;
    final visits = query['maxVisits'] as int;
    return {
      'id': query['id'],
      'isDuringSearch': false,
      'turnNumber': moves.length,
      'rootInfo': {'visits': visits, 'winrate': 0.5 + lead / 100, 'scoreLead': lead},
      'moveInfos': [
        for (var i = 0; i < 3 && i < empty.length; i++)
          {
            'move': empty[i],
            'order': i,
            'visits': visits ~/ (i + 2),
            'winrate': 0.5 + (lead - sign * i) / 100,
            'scoreLead': lead - sign * i,
            'prior': 0.5 / (i + 1),
            'pv': [empty[i]],
          },
      ],
      if (query['includeOwnership'] == true) 'ownership': [for (var i = 0; i < sizeX * sizeY; i++) 0.0],
      if (query['includePolicy'] == true)
        'policy': [
          for (var y = sizeY - 1; y >= 0; y--)
            for (var x = 0; x < sizeX; x++)
              occupied.contains(Move(coords: (x, y)).gtp()) ? -1.0 : 1.0 / (sizeX * sizeY),
          0.0,
        ],
    };
  }

  /// Answers queries and lets the app react until it is idle and asks for nothing more.
  Future<void> settle(AppController app) async {
    var quiet = 0;
    for (var i = 0; i < 400; i++) {
      final answered = answerPending();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      quiet = answered == 0 && pending.isEmpty && app.idle ? quiet + 1 : 0;
      if (quiet >= 3) return;
    }
    throw StateError('the app did not settle: ${pending.length} queries pending, idle ${app.idle}');
  }
}

/// An app on [kata] with the default settings changed by [settings] (`section/key` to value), started on a new
/// game of [size].
Future<AppController> startApp(FakeKataGo kata, {int size = 9, Map<String, Object?> settings = const {}}) async {
  final config = defaultConfig();
  (config['game'] as Map)['size'] = size;
  for (final MapEntry(:key, :value) in settings.entries) {
    final [section, name] = key.split('/');
    (config[section] as Map)[name] = value;
  }
  final app = AppController(MemoryConfigStore(config), resourceDir: '.');
  kata.engine = KataGoEngine(app.engineHost, (config['engine'] as Map).cast<String, dynamic>())..connection = kata;
  await app.start(engineWithoutIo: kata.engine);
  await kata.settle(app);
  return app;
}
