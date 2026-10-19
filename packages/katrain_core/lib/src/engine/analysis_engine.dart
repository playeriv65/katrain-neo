// The part of KaTrain's KataGoEngine (katrain/core/engine.py) that nodes and games call.

import '../sgf/move.dart';

/// A KataGo analysis result (one JSON line), and whether more results for the same query follow.
typedef AnalysisCallback = void Function(Map<String, dynamic> result, bool partialResult);

typedef AnalysisErrorCallback = void Function(Map<String, dynamic> result);

/// Something that can analyse positions with KataGo: a local process, a remote server, or a test double.
abstract interface class AnalysisEngine<N> {
  /// The engine settings (KaTrain's `engine` config section), e.g. `max_visits` and `fast_visits`.
  Map<String, dynamic> get config;

  /// Drops queued and running queries, all of them or only those for [onlyForNode].
  void terminateQueries({N? onlyForNode});

  void stopPondering();

  void requestAnalysis(
    N analysisNode, {
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
  });
}
