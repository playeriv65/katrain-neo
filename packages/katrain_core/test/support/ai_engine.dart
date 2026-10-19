// A host and an engine for testing the AI: the engine records every query and answers it the way a test tells it to,
// plus builders for KataGo-style analysis results.

import 'dart:convert';

import 'package:katrain_core/katrain_core.dart';

/// A program around the game that keeps its settings and log in memory.
class AiHost implements GameHost {
  final Map<String, dynamic> settings;
  final List<(String, int)> logs = [];
  @override
  final Map<String, Player> playersInfo = {'B': Player('B'), 'W': Player('W')};
  @override
  Game? game;

  AiHost({int size = 9, double komi = 6.5, int handicap = 0})
    : settings = {
        'game': {'size': size, 'komi': komi, 'rules': 'japanese', 'handicap': handicap},
        'engine': {'max_visits': 100, 'fast_visits': 10},
      };

  @override
  Object? config(String setting, [Object? defaultValue]) {
    final [section, ...key] = setting.split('/');
    final value = settings[section];
    if (key.isEmpty) return value ?? defaultValue;
    return (value as Map<String, dynamic>?)?[key.single] ?? defaultValue;
  }

  /// Log messages at [level] (e.g. [outputError]).
  List<String> logged(int level) => [
    for (final (message, l) in logs)
      if (l == level) message,
  ];

  @override
  void log(String message, int level) => logs.add((message, level));

  @override
  set pondering(bool value) {}

  @override
  void setStatus(String message, num statusType, {GameNode? atNode}) {}

  @override
  void updateState({bool redrawBoard = false}) {}

  @override
  set insertNode(GameNode? node) {}

  @override
  void redrawMoveTree() {}
}

/// One analysis request, which the test can answer at any time.
class AiQuery {
  final GameNode node;
  final int priority;
  final Map<String, dynamic>? extraSettings;
  final bool? ownership;
  final bool includePolicy;
  final AnalysisCallback _callback;
  final AnalysisErrorCallback? _errorCallback;

  AiQuery(
    this.node,
    this._callback,
    this._errorCallback, {
    required this.priority,
    required this.extraSettings,
    required this.ownership,
    required this.includePolicy,
  });

  /// An extra query of the AI, as opposed to the regular analysis of a position.
  bool get isExtra => priority == priorityExtraAiQuery;

  void answer(Map<String, dynamic> result, {bool partial = false}) => _callback(_copy(result), partial);

  void fail([Map<String, dynamic> error = const {'error': 'test failure'}]) => _errorCallback!(_copy(error));
}

Map<String, dynamic> _copy(Map<String, dynamic> json) => jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

/// An engine that records the queries and answers them through [positions] and [onExtraQuery].
class AiEngine implements AnalysisEngine<GameNode> {
  @override
  final Map<String, dynamic> config = {'max_visits': 100, 'fast_visits': 10};
  @override
  int queryGeneration = 0;
  final List<AiQuery> queries = [];

  /// The regular analysis of a position, given right away; null (or no function) leaves the query unanswered.
  Map<String, dynamic>? Function(GameNode node)? positions;

  /// Called for each extra query of the AI as it comes in; it may answer, fail, or leave it unanswered.
  void Function(AiQuery query)? onExtraQuery;

  List<AiQuery> get extraQueries => [
    for (final q in queries)
      if (q.isExtra) q,
  ];

  /// The latest regular query for [node].
  AiQuery regularQueryFor(GameNode node) => queries.lastWhere((q) => !q.isExtra && identical(q.node, node));

  /// What a new game or an engine restart does: outstanding queries will never be answered.
  void discardQueries() => queryGeneration += 1;

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
    final query = AiQuery(
      analysisNode,
      callback,
      errorCallback,
      priority: priority,
      extraSettings: extraSettings,
      ownership: ownership,
      includePolicy: includePolicy,
    );
    queries.add(query);
    if (query.isExtra) {
      onExtraQuery?.call(query);
    } else {
      final result = positions?.call(analysisNode);
      if (result != null) query.answer(result);
    }
  }

  @override
  void terminateQueries({GameNode? onlyForNode}) {}

  @override
  void stopPondering() {}
}

/// A game on an empty board (or [sgf]) with its host and engine; [positions] answers the regular analyses.
(Game, AiHost, AiEngine) newGame({
  int size = 9,
  double komi = 6.5,
  int handicap = 0,
  String? sgf,
  Map<String, dynamic>? Function(GameNode node)? positions,
}) {
  final host = AiHost(size: size, komi: komi, handicap: handicap);
  final engine = AiEngine()..positions = positions;
  final game = Game(host, engine, moveTree: sgf == null ? null : gameParser.parseSgf(sgf));
  host.game = game;
  return (game, host, engine);
}

/// Plays [moves] (GTP coordinates, alternating from the player to move).
void playMoves(Game game, List<String> moves) {
  for (final gtp in moves) {
    game.play(Move.fromGtp(gtp, player: game.currentNode.nextPlayer));
  }
}

/// A candidate move in an analysis result: [scoreLead] is from Black's point of view, as KataGo is asked to report it.
class Cand {
  final String move;
  final double scoreLead;
  final double winrate;
  final int visits;
  final double prior;
  final List<double>? ownership;

  const Cand(this.move, this.scoreLead, {this.winrate = 0.5, this.visits = 50, this.prior = 0.1, this.ownership});
}

/// A KataGo analysis result with [moves] in engine order; the root score is the first move's unless given.
Map<String, dynamic> analysisResult(
  List<Cand> moves, {
  double? rootScore,
  double rootWinrate = 0.5,
  List<double>? policy,
  List<double>? ownership,
  List<double>? humanPolicy,
}) => {
  'id': 'QUERY',
  'rootInfo': {
    'visits': moves.fold<int>(0, (sum, c) => sum + c.visits) + 1,
    'winrate': rootWinrate,
    'scoreLead': rootScore ?? (moves.isEmpty ? 0.0 : moves.first.scoreLead),
  },
  'moveInfos': [
    for (var i = 0; i < moves.length; i++)
      {
        'move': moves[i].move,
        'order': i,
        'visits': moves[i].visits,
        'winrate': moves[i].winrate,
        'scoreLead': moves[i].scoreLead,
        'prior': moves[i].prior,
        'pv': [moves[i].move],
        if (moves[i].ownership != null) 'ownership': moves[i].ownership,
      },
  ],
  'ownership': ?ownership,
  'policy': ?policy,
  'humanPolicy': ?humanPolicy,
};

/// The index of a point (or pass, the last one) in KataGo's policy and ownership arrays: top row first.
int policyIndex(String gtp, int size) {
  final move = Move.fromGtp(gtp);
  if (move.isPass) return size * size;
  final (x, y) = move.coords!;
  return (size - 1 - y) * size + x;
}

/// A policy like KataGo's for the current position of [game]: -1 on occupied points, the given [values] (by GTP
/// coordinates, `pass` included), and the remaining probability spread evenly over the other empty points.
List<double> boardPolicy(Game game, Map<String, double> values) {
  final (size, _) = game.boardSize;
  final policy = List.filled(size * size + 1, 0.0);
  final occupied = {for (final s in game.stones) policyIndex(s.gtp(), size)};
  final given = {for (final e in values.entries) policyIndex(e.key, size): e.value};
  final rest = [
    for (var i = 0; i < size * size; i++)
      if (!occupied.contains(i) && !given.containsKey(i)) i,
  ];
  final remaining = 1 - values.values.fold(0.0, (a, b) => a + b);
  for (final i in occupied) {
    policy[i] = -1;
  }
  for (final i in rest) {
    policy[i] = remaining / rest.length;
  }
  given.forEach((i, v) => policy[i] = v);
  return policy;
}

/// An ownership array for a [size] board: [values] by GTP coordinates, [rest] elsewhere.
List<double> ownershipOf(int size, Map<String, double> values, {double rest = 0}) {
  final ownership = List.filled(size * size, rest);
  values.forEach((gtp, v) => ownership[policyIndex(gtp, size)] = v);
  return ownership;
}

/// Lets queued events (the game's first analysis request, timers of the AI's polling) run.
Future<void> pump([int milliseconds = 0]) => Future<void>.delayed(Duration(milliseconds: milliseconds));
