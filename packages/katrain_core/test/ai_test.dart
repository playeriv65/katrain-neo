// Differential tests: the AI strategies, rank estimation and game report run the operation script of
// tools/fixtures/ai_fixtures.py and must produce the same moves, thoughts, log lines and queries as KaTrain.

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'fixtures_util.dart';
import 'game_script.dart';

/// Records requests, and answers the AI's extra queries right away from the current operation's answers.
class AnsweringEngine extends RecordingEngine {
  List<Map<String, dynamic>> answers = [];

  AnsweringEngine(super.host, super.config);

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
    super.requestAnalysis(
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
    );
    if (priority != priorityExtraAiQuery || answers.isEmpty) return;
    final answer = answers.removeAt(0);
    Map<String, dynamic> result() => deepCopy(answer['result']) as Map<String, dynamic>;
    switch (answer['type']) {
      case 'result':
        callback(result(), false);
      case 'partial_then_result':
        callback(result(), true);
        callback(result(), false);
      case 'error':
        errorCallback!(deepCopy(answer['error']) as Map<String, dynamic>);
      case 'discard':
        queryGeneration += 1;
      case 'navigate':
        host.game!.setCurrentNode(analysisNode.parent!);
        callback(result(), false);
      default:
        fail('unknown answer ${answer['type']}');
    }
  }
}

void main() {
  setUpAll(() => i18n.switchLang('en'));
  tearDownAll(() => i18n.switchLang(defaultLanguage));

  test('operation script', () {
    final runner = ScriptRunner(loadFixture('ai.json'), engine: AnsweringEngine.new);
    final engine = runner.engine as AnsweringEngine;
    runner.handlers.addAll({
      'ai': (op) async {
        engine.answers = (deepCopy(op['answers']) as List).cast<Map<String, dynamic>>();
        globalRandom.seed(BigInt.from(op['seed'] as int));
        try {
          final (move, node) = await generateAiMove(
            runner.game!,
            op['mode'] as String,
            deepCopy(op['settings']) as Map<String, dynamic>,
          );
          runner.host.events.add(['ai_result', move == null ? null : '${move.player}${move.gtp()}', nodePath(node)]);
        } finally {
          engine.answers = [];
        }
      },
      'rank': (op) async {
        runner.host.events.add([
          'rank',
          aiRankEstimation(op['strategy'] as String, op['settings'] as Map<String, dynamic>),
        ]);
      },
      'report': (op) async {
        final (sumStats, histogram, playerPtloss) = gameReport(
          runner.game!,
          (op['thresholds'] as List).cast<num>(),
          depthFilter: (op['depth_filter'] as List?)?.cast<num>(),
        );
        runner.host.events.add(['report', sumStats, histogram, playerPtloss]);
      },
    });
    return runner.check();
  });
}
