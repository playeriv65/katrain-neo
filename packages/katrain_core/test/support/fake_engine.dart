// A stand-in for KataGo: records the analysis requests and lets the test answer them, plus builders for results in
// KataGo's analysis format.

import 'package:katrain_core/katrain_core.dart';

/// One call of [AnalysisEngine.requestAnalysis], with its arguments.
class AnalysisRequest {
  final GameNode node;
  final AnalysisCallback callback;
  final AnalysisErrorCallback? errorCallback;
  final int? visits;
  final bool analyzeFast;
  final bool timeLimit;
  final bool findAlternatives;
  final List<int>? regionOfInterest;
  final int priority;
  final bool ponder;
  final bool? ownership;
  final Move? nextMove;
  final Map<String, dynamic>? extraSettings;
  final bool includePolicy;
  final double? reportEvery;

  AnalysisRequest(
    this.node, {
    required this.callback,
    this.errorCallback,
    this.visits,
    this.analyzeFast = false,
    this.timeLimit = true,
    this.findAlternatives = false,
    this.regionOfInterest,
    this.priority = 0,
    this.ponder = false,
    this.ownership,
    this.nextMove,
    this.extraSettings,
    this.includePolicy = true,
    this.reportEvery,
  });

  /// Delivers [result] (see [analysisResult]) to whoever asked; [partial] when more results would follow.
  void answer(Map<String, dynamic> result, {bool partial = false}) => callback(result, partial);

  @override
  String toString() => 'AnalysisRequest(depth ${node.depth}, visits $visits, priority $priority, next $nextMove)';
}

/// An [AnalysisEngine] that answers nothing by itself: tests look at [requests] and answer them.
class FakeEngine implements AnalysisEngine<GameNode> {
  @override
  final Map<String, dynamic> config;

  /// Every request so far, oldest first.
  final List<AnalysisRequest> requests = [];

  /// The `onlyForNode` of each [terminateQueries] call; null for "all queries".
  final List<GameNode?> terminations = [];
  int ponderingStops = 0;

  @override
  int queryGeneration = 0;

  /// [config] defaults to 500 visits, 25 for fast analysis.
  FakeEngine([Map<String, dynamic>? config]) : config = config ?? {'max_visits': 500, 'fast_visits': 25};

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
    requests.add(
      AnalysisRequest(
        analysisNode,
        callback: callback,
        errorCallback: errorCallback,
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
      ),
    );
    // like the real engine, remember on the node how many visits were asked for
    final maxVisits = visits ?? (analyzeFast ? config['fast_visits'] : config['max_visits']) as int;
    if (maxVisits > analysisNode.analysisVisitsRequested) analysisNode.analysisVisitsRequested = maxVisits;
  }

  @override
  void terminateQueries({GameNode? onlyForNode}) => terminations.add(onlyForNode);

  @override
  void stopPondering() => ponderingStops += 1;

  /// The requests made while [action] runs.
  List<AnalysisRequest> requestsDuring(void Function() action) {
    final before = requests.length;
    action();
    return requests.sublist(before);
  }

  /// The requests for [node], oldest first.
  List<AnalysisRequest> requestsFor(GameNode node) => [
    for (final r in requests)
      if (identical(r.node, node)) r,
  ];

  /// The last request to analyse [node] itself (not a refinement of one of its moves).
  AnalysisRequest lastRequestFor(GameNode node) =>
      requests.lastWhere((r) => identical(r.node, node) && r.nextMove == null);
}

/// One candidate move in a KataGo result.
Map<String, dynamic> moveInfo(
  String move, {
  double scoreLead = 0,
  double winrate = 0.5,
  int visits = 10,
  int? order,
  List<String>? pv,
  double prior = 0.1,
}) => {
  'move': move,
  'scoreLead': scoreLead,
  'winrate': winrate,
  'visits': visits,
  'order': ?order,
  'pv': pv ?? [move],
  'prior': prior,
};

/// A KataGo analysis result: the position is worth [scoreLead] for Black; [moves] are the candidates, best first
/// (their `order` is their position in the list unless they have one).
Map<String, dynamic> analysisResult({
  double scoreLead = 0,
  double winrate = 0.5,
  int visits = 100,
  List<Map<String, dynamic>> moves = const [],
  List<double>? ownership,
  List<double>? policy,
}) => {
  'rootInfo': <String, dynamic>{'scoreLead': scoreLead, 'winrate': winrate, 'visits': visits},
  'moveInfos': [
    for (var i = 0; i < moves.length; i++) {'order': i, ...moves[i]},
  ],
  'ownership': ?ownership,
  'policy': ?policy,
};
