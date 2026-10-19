// A game being played or reviewed: navigation, scoring, root properties and saving, analysis requests, insert mode,
// self-play and teaching undo. The board rules are in rules/base_game.dart. A new game's first analysis runs as a
// later event, so the game shows at once.

import 'dart:math' as math;

import '../constants.dart';
import '../engine/analysis_engine.dart';
import '../i18n/i18n.dart';
import '../rules/base_game.dart';
import '../sgf/move.dart';
import '../utils/format.dart';
import '../utils/random.dart';
import '../utils/template.dart';
import '../utils/utils.dart';
import 'game_node.dart';
import 'player.dart';

/// What a game needs from the program around it: settings, players and logging, the status line and move tree, and
/// reacting to a new state.
abstract interface class GameHost {
  /// A setting such as `game/size`, or a whole section such as `trainer`.
  Object? config(String setting, [Object? defaultValue]);

  Map<String, Player> get playersInfo;

  /// The game currently shown; self-play stops once it is no longer this one.
  Game? get game;

  set pondering(bool value);

  void log(String message, int level);

  /// Shows [message] in the status line.
  void setStatus(String message, num statusType, {GameNode? atNode});

  void updateState({bool redrawBoard = false});

  /// The node the move tree marks as the insertion point, null outside insert mode.
  set insertNode(GameNode? node);

  void redrawMoveTree();
}

String _formatGameId(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)} ${two(t.hour)} ${two(t.minute)} '
      '${two(t.second)}';
}

final _filenameUnsafe = RegExp('[​ㅤ\'<>:"/\\\\|?*]');

/// A game with navigation, analysis requests, insert mode, self-play and teaching undo.
class Game extends BaseGame<GameNode> {
  static const Map<String, Object> defaultProperties = {'GM': 1, 'FF': 4};

  final GameHost host;

  /// The engine analysing the positions with each colour to move.
  final Map<String, AnalysisEngine<GameNode>> engines;

  /// The time the game was created, as `YYYY-mm-dd HH MM SS`; part of the default file name.
  String gameId;
  String? sgfFilename;

  /// Not written by KaTrain or KaTrain Neo: its player names are kept as they are.
  bool externalGame = false;
  bool insertMode = false;
  GameNode? insertAfter;

  /// `[xmin, xmax, ymin, ymax]` to restrict analysis to, or null.
  List<int>? regionOfInterest;

  /// Region analysis also sets the node evaluation (set by the tsumego frame).
  bool regionRoot = false;
  double mainTimeUsed = 0;

  /// A game analysed by [engine]: [moveTree] when one was loaded, otherwise a new empty board from the settings.
  Game(
    GameHost host,
    AnalysisEngine<GameNode> engine, {
    GameNode? moveTree,
    bool analyzeFast = false,
    Map<String, Object?>? gameProperties,
    String? sgfFilename,
    DateTime? now,
  }) : this.withEngines(
         host,
         {'B': engine, 'W': engine},
         moveTree: moveTree,
         analyzeFast: analyzeFast,
         gameProperties: gameProperties,
         sgfFilename: sgfFilename,
         now: now,
       );

  /// A game with a different engine for each colour to move.
  Game.withEngines(
    GameHost host,
    Map<String, AnalysisEngine<GameNode>> engines, {
    GameNode? moveTree,
    bool analyzeFast = false,
    Map<String, Object?>? gameProperties,
    String? sgfFilename,
    DateTime? now,
  }) : this._(host, engines, moveTree, analyzeFast, gameProperties, sgfFilename, _formatGameId(now ?? DateTime.now()));

  Game._(
    this.host,
    this.engines,
    GameNode? moveTree,
    bool analyzeFast,
    Map<String, Object?>? gameProperties,
    this.sgfFilename,
    this.gameId,
  ) : super(
        moveTree ?? _newRoot(host, gameProperties, gameId),
        defaultRules: host.config('game/rules') as String,
        loaded: moveTree != null,
      ) {
    if (moveTree != null) {
      externalGame = !(root.getProperty('AP') ?? '').contains(analysisWriterTag);
    }
    // restore shortcuts
    final shortcutIdToNode = {for (final node in root.nodesInTree) node.getProperty('KTSID'): node};
    for (final node in root.nodesInTree) {
      final shortcutId = node.getProperty('KTSF');
      if (shortcutId != null && shortcutId.isNotEmpty && shortcutIdToNode.containsKey(shortcutId)) {
        shortcutIdToNode[shortcutId]!.addShortcut(node);
      }
    }
    Future(() => analyzeAllNodes(analyzeFast: analyzeFast, evenIfPresent: false)); // return faster
  }

  static GameNode _newRoot(GameHost host, Map<String, Object?>? gameProperties, String gameId) {
    final root = GameNode(
      properties: {
        ...defaultProperties,
        'DT': gameId,
        'SZ': host.config('game/size'),
        'KM': host.config('game/komi'),
        'RU': host.config('game/rules'),
        ...?gameProperties,
      },
    );
    final handicap = host.config('game/handicap') as int?;
    if (handicap != null && handicap != 0) root.placeHandicapStones(handicap);
    return root;
  }

  // -- navigation --

  @override
  void setCurrentNode(GameNode node) {
    if (insertMode) {
      host.setStatus(i18n.tr('finish inserting before navigating'), statusError);
      return;
    }
    super.setCurrentNode(node);
  }

  /// Plays from the root, adding the moves that are not in the tree yet; the current node does not change.
  GameNode syncBranch(List<Move> moves) {
    var node = root;
    for (final move in moves) {
      node = node.play(move);
    }
    return node;
  }

  /// Goes back [nTimes] moves, or to the last branching point (`'branch'`), or back to where this line leaves the
  /// main branch (`'main-branch'`). With [stopOnMistake], stops after undoing a human move that lost at least that
  /// many points. In insert mode, undo deletes the current inserted node.
  void undo([Object nTimes = 1, double? stopOnMistake]) {
    if (insertMode) {
      // in insert mode, undo = delete
      final cn = currentNode;
      if (nTimes == 1 && !insertAfter!.nodesFromRoot.contains(cn)) {
        cn.parent!.children.removeWhere((c) => identical(c, cn));
        currentNode = cn.parent!;
        calculateGroups();
      }
      return;
    }
    var breakOnBranch = false;
    var breakOnMainBranch = false;
    var cn = currentNode;
    var lastBranchingNode = cn;
    final int n;
    if (nTimes == 'branch') {
      n = 9999;
      breakOnBranch = true;
    } else if (nTimes == 'main-branch') {
      n = 9999;
      breakOnMainBranch = true;
    } else {
      n = nTimes as int;
    }
    for (var i = 0; i < n; i++) {
      final lost = cn.pointsLost;
      if (stopOnMistake != null &&
          lost != null &&
          lost >= stopOnMistake &&
          host.playersInfo[cn.player]!.playerType != playerAi) {
        setCurrentNode(cn.parent!);
        return;
      }
      final previous = cn;
      if (cn.shortcutFrom != null) {
        cn = cn.shortcutFrom!;
      } else if (!cn.isRoot) {
        cn = cn.parent!;
      } else {
        break; // root
      }
      if (breakOnBranch && cn.children.length > 1) {
        break;
      } else if (breakOnMainBranch && !identical(cn.orderedChildren[0], previous)) {
        // implies > 1 child
        lastBranchingNode = cn;
      }
    }
    if (breakOnMainBranch) cn = lastBranchingNode;
    if (!identical(cn, currentNode)) setCurrentNode(cn);
  }

  /// Goes forward [nTimes] moves along the first child, through shortcuts. With [stopOnMistake], stops before a
  /// human move after the first that lost at least that many points; the position does not change at all when no
  /// such move is found.
  void redo([int nTimes = 1, double? stopOnMistake]) {
    if (insertMode) return;
    var cn = currentNode;
    for (var move = 0; move < nTimes; move++) {
      if (cn.children.isNotEmpty) {
        var child = cn.orderedChildren[0];
        // are we about to go to a shortcut node?
        final shortcutTo = [
          for (final (m, v) in cn.shortcutsTo)
            if (identical(child, v)) m,
        ];
        if (shortcutTo.isNotEmpty) child = shortcutTo[0];
        cn = child;
      }
      final lost = cn.pointsLost;
      if (move > 0 &&
          stopOnMistake != null &&
          lost != null &&
          lost >= stopOnMistake &&
          host.playersInfo[cn.player]!.playerType != playerAi) {
        setCurrentNode(cn.parent!);
        return;
      }
    }
    if (stopOnMistake == null) setCurrentNode(cn);
  }

  // -- results --

  /// The result once the game is over: resigned or timed out, or the score after two passes.
  String? get endResult {
    final cn = currentNode;
    final endState = cn.endState;
    if (endState != null && endState.isNotEmpty) return endState;
    if (cn.parent != null && cn.isPass && cn.parent!.isPass) {
      return manualScore ?? i18n.tr('board-game-end');
    }
    return null;
  }

  /// A score estimate after two passes: counted from ownership under japanese rules, KataGo's score otherwise.
  String? get manualScore {
    final r = rules;
    final cn = currentNode;
    final parent = cn.parent;
    final japanese = r is String && (r.toLowerCase() == 'jp' || r.toLowerCase() == 'japanese');
    if ((cn.ownership?.isEmpty ?? true) || !japanese || parent == null || (parent.ownership?.isEmpty ?? true)) {
      final score = cn.score;
      if (score == null || score == 0) return null;
      return '${cn.formatScore((2 * score).round() / 2)}?';
    }
    final (sizeX, sizeY) = boardSize;
    final own = cn.ownership!;
    final parentOwn = parent.ownership!;
    final meanOwnership = [
      for (var i = 0; i < math.min(own.length, parentOwn.length); i++) (own[i] + parentOwn[i]) / 2,
    ];
    final ownershipGrid = varToGrid(meanOwnership, (sizeX, sizeY));
    final stoneOwners = {for (final m in stones) m.coords!: m.player};
    const loThreshold = 0.15;
    const hiThreshold = 0.85;
    const maxUnknown = 10;
    final maxDame = 4 * (sizeX + sizeY);

    num japaneseScoreSquare((int, int) square, double owner) {
      final player = stoneOwners[square];
      if ((player == 'B' && owner > hiThreshold) ||
          (player == 'W' && owner < -hiThreshold) ||
          owner.abs() < loThreshold) {
        return 0; // dame or own stones
      }
      if (player == null && owner.abs() >= hiThreshold) {
        return (owner).round(); // surrounded empty intersection
      }
      if ((player == 'B' && owner < -hiThreshold) || (player == 'W' && owner > hiThreshold)) {
        return 2 * (owner).round(); // captured stone
      }
      return double.nan; // unknown!
    }

    final scoredSquares = [
      for (var y = 0; y < sizeY; y++)
        for (var x = 0; x < sizeX; x++) japaneseScoreSquare((x, y), ownershipGrid[y][x]),
    ];
    final numSq = {
      for (final t in const [-2, -1, 0, 1, 2]) t: scoredSquares.where((s) => s == t).length,
    };
    final numUnknown = scoredSquares.where((s) => s.isNaN).length;
    final prisoners = prisonerCount;
    var squareTotal = 0;
    numSq.forEach((t, n) => squareTotal += t * n);
    final score = squareTotal + prisoners['W']! - prisoners['B']! - komi;
    final numSqRepr = '{${[for (final e in numSq.entries) '${e.key}: ${e.value}'].join(', ')}}';
    final prisonersRepr = "{'B': ${prisoners['B']}, 'W': ${prisoners['W']}}";
    host.log(
      'Manual Scoring: $numSqRepr score by square with $numUnknown unknown, $prisonersRepr captures, and '
      '$komi komi -> score = $score',
      outputDebug,
    );
    if (numUnknown > maxUnknown || (numSq[0]! - stoneOwners.length) > maxDame) return null;
    return cn.formatScore(score);
  }

  // -- saving --

  /// Writes the player names, AI ranks and result into the root.
  void updateRootProperties() {
    String playerName(Player info) {
      if (info.name.isNotEmpty && info.playerType == playerHuman) return info.name;
      return '${i18n.tr(info.playerType)} (${i18n.tr(info.playerSubtype)})$sgfInternalCommentsMarker';
    }

    final xProperties = <String, String>{};
    for (final bw in const ['B', 'W']) {
      if (!externalGame) {
        final info = host.playersInfo[bw]!;
        xProperties['P$bw'] = playerName(info);
        if (info.playerType == playerAi) xProperties['${bw}R'] = rankLabel(info.calculatedRank);
      }
    }
    final result = endResult;
    if (result != null && result.contains('+')) xProperties['RE'] = result;
    xProperties.forEach(root.setProperty);
  }

  /// `KaTrain Neo_<black> vs <white> <game id>.sgf`, without characters file systems do not allow.
  String generateFilename() {
    updateRootProperties();
    final names = {
      for (final bw in const ['B', 'W']) bw: (root.getProperty('P$bw', bw) ?? '').replaceAll(_filenameUnsafe, ''),
    };
    return '${appName}_${names['B']} vs ${names['W']} $gameId.sgf';
  }

  /// The SGF to save, with feedback comments, marks and analysis as the trainer settings ask.
  /// Writing it to a file is in the io library (`writeSgf`).
  String sgfToSave([Map<String, dynamic>? trainerConfig]) {
    trainerConfig ??= (host.config('trainer', <String, dynamic>{}) as Map).cast<String, dynamic>();
    final saveFeedback = trainerConfig['save_feedback'];
    final evalThresholds = (trainerConfig['eval_thresholds'] as List).cast<num>();
    final saveAnalysis = (trainerConfig['save_analysis'] ?? false) as bool;
    final saveMarks = (trainerConfig['save_marks'] ?? false) as bool;
    updateRootProperties();
    final showDotsFor = {
      for (final bw in const ['B', 'W'])
        bw: ((trainerConfig['eval_show_ai'] ?? true) as bool) || host.playersInfo[bw]!.human,
    };
    return root.sgf(
      SgfSaveOptions(
        saveCommentsPlayer: showDotsFor,
        // no setting: feedback for every class
        saveCommentsClass: saveFeedback is List ? saveFeedback.cast<bool>() : null,
        evalThresholds: evalThresholds,
        saveAnalysis: saveAnalysis,
        saveMarks: saveMarks,
      ),
    );
  }

  // -- analysis --

  void analyzeAllNodes({int priority = priorityGameAnalysis, bool analyzeFast = false, bool evenIfPresent = true}) {
    for (final node in root.nodesInTree) {
      // forced, or neither analysed already nor loaded from the file
      if (evenIfPresent || !(node.analysisExists || node.loadAnalysis())) {
        node.clearAnalysis();
        node.analyze(engines[node.nextPlayer]!, priority: priority, analyzeFast: analyzeFast);
      }
    }
  }

  void resetCurrentAnalysis() {
    final cn = currentNode;
    final engine = engines[cn.nextPlayer]!;
    engine.terminateQueries(onlyForNode: cn);
    cn.clearAnalysis();
    cn.analyze(engine);
  }

  /// Plays [move] and, unless [analyze] is false, asks for its analysis (fast first, then within the region of
  /// interest, when one is set).
  @override
  GameNode? play(Move move, {bool ignoreKo = false, GameNode? expectedNode, bool analyze = true}) {
    final played = super.play(move, ignoreKo: ignoreKo, expectedNode: expectedNode);
    if (played == null) return null;
    if (analyze) {
      final engine = engines[played.nextPlayer]!;
      if (regionOfInterest != null && regionRoot) {
        played.analyze(engine, regionOfInterest: regionOfInterest, regionRoot: true);
      } else if (regionOfInterest != null) {
        played.analyze(engine, analyzeFast: true);
        played.analyze(engine, regionOfInterest: regionOfInterest);
      } else {
        played.analyze(engine);
      }
    }
    return played;
  }

  /// Sets the region from two corners `[x1, x2, y1, y2]`; a single point or the whole board clears it.
  void setRegionOfInterest(List<int> region) {
    final [x1, x2, y1, y2] = region;
    final xmin = math.min(x1, x2), xmax = math.max(x1, x2);
    final ymin = math.min(y1, y2), ymax = math.max(y1, y2);
    final (sizeX, sizeY) = boardSize;
    if (!(xmin == xmax && ymin == ymax) && !(xmax - xmin + 1 >= sizeX && ymax - ymin + 1 >= sizeY)) {
      regionOfInterest = [xmin, xmax, ymin, ymax];
    } else {
      regionOfInterest = null;
    }
    host.setStatus('', outputInfo);
  }

  /// The extra analysis modes: `stop`, `ponder`, `extra` (more visits), `game` (re-analyse the whole game or
  /// [moveRange], optionally only around mistakes), `sweep` (every move), `equalize`, `alternative` and `local`.
  void analyzeExtra(String mode, {bool mistakesOnly = false, List<int>? moveRange, int? visits}) {
    final stoneCoords = {for (final s in stones) s.coords};
    final cn = currentNode;

    if (mode == 'stop') {
      host.pondering = false;
      for (final e in engines.values.toSet()) {
        e.stopPondering();
        e.terminateQueries();
      }
      return;
    }

    final engine = engines[cn.nextPlayer]!;
    final maxVisits = engine.config['max_visits'] as int;
    final fastVisits = engine.config['fast_visits'] as int;

    if (mode == 'ponder') {
      cn.analyze(
        engine,
        ponder: true,
        priority: priorityExtraAnalysis,
        regionOfInterest: regionOfInterest,
        regionRoot: regionRoot,
        timeLimit: false,
      );
      return;
    }

    if (mode == 'extra') {
      final extraVisits = cn.analysisVisitsRequested + maxVisits;
      host.setStatus(fillTemplate(i18n.tr('extra analysis'), {'visits': extraVisits}), statusAnalysis);
      cn.analyze(
        engine,
        visits: extraVisits,
        priority: priorityExtraAnalysis,
        regionOfInterest: regionOfInterest,
        regionRoot: regionRoot,
        timeLimit: false,
      );
      return;
    }

    if (mode == 'game') {
      final nodes = root.nodesInTree;
      var range = (moveRange == null || moveRange.isEmpty) ? null : moveRange;
      if (range != null && range[1] < range[0]) {
        range = [range[1], range[0]];
      }
      final threshold = (host.config('trainer/eval_thresholds') as List).cast<num>();
      final mistakeThreshold = threshold[threshold.length - 4];
      final gameVisits = visits ?? nodes.map((n) => n.analysisVisitsRequested).reduce(math.min) + maxVisits;
      for (final node in nodes) {
        final maxPointLoss = [node, ...node.children].map((c) => c.pointsLost ?? 0).reduce(math.max);
        if (mistakesOnly && maxPointLoss <= mistakeThreshold) continue;
        if (range != null && !(range[0] <= node.depth && node.depth <= range[1])) continue;
        node.analyze(engine, visits: gameVisits, priority: -1000000, timeLimit: false, reportEvery: null);
      }
      if (range == null) {
        host.setStatus(fillTemplate(i18n.tr('game re-analysis'), {'visits': gameVisits}), statusAnalysis);
      } else {
        host.setStatus(
          fillTemplate(i18n.tr('move range analysis'), {
            'start_move': range[0],
            'end_move': range[1],
            'visits': gameVisits,
          }),
          statusAnalysis,
        );
      }
      return;
    }

    final List<Move> analyzeMoves;
    final int moveVisits;
    final int priority;
    if (mode == 'sweep') {
      final (sizeX, sizeY) = boardSize;
      final policy = cn.policy;
      // without a policy, sweep all empty points
      if (cn.analysisExists && policy != null) {
        final policyGrid = varToGrid(policy, (sizeX, sizeY));
        analyzeMoves = [
          for (var x = 0; x < sizeX; x++)
            for (var y = 0; y < sizeY; y++)
              if (policyGrid[y][x] >= 0) Move(coords: (x, y), player: cn.nextPlayer),
        ];
        stableSortBy(analyzeMoves, (mv) => -policyGrid[mv.coords!.$2][mv.coords!.$1]);
      } else {
        analyzeMoves = [
          for (var x = 0; x < sizeX; x++)
            for (var y = 0; y < sizeY; y++)
              if (!stoneCoords.contains((x, y))) Move(coords: (x, y), player: cn.nextPlayer),
        ];
      }
      moveVisits = fastVisits;
      host.setStatus(fillTemplate(i18n.tr('sweep analysis'), {'visits': moveVisits}), statusAnalysis);
      priority = prioritySweep;
    } else if (mode == 'equalize' || mode == 'alternative' || mode == 'local') {
      if (!cn.analysisComplete && mode != 'local') {
        host.setStatus(i18n.tr('wait-before-extra-analysis'), statusInfo, atNode: currentNode);
        return;
      }
      final moves = cn.analysis['moves'] as Map<String, dynamic>;
      if (mode == 'alternative') {
        // also do a quick update on current candidates so it doesn't look too weird
        host.setStatus(i18n.tr('alternative analysis'), statusAnalysis);
        cn.analyze(engine, priority: priorityAlternatives, timeLimit: false, findAlternatives: true);
        moveVisits = fastVisits;
      } else {
        // equalize
        moveVisits = moves.values.map((d) => (d as Map<String, dynamic>)['visits'] as int).reduce(math.max);
        host.setStatus(fillTemplate(i18n.tr('equalizing analysis'), {'visits': moveVisits}), statusAnalysis);
      }
      priority = priorityEqualize;
      analyzeMoves = [for (final gtp in moves.keys) Move.fromGtp(gtp, player: cn.nextPlayer)];
    } else {
      throw ArgumentError('Invalid analysis mode');
    }

    for (final move in analyzeMoves) {
      final current = (cn.analysis['moves'] as Map<String, dynamic>)[move.gtp()] as Map<String, dynamic>?;
      if (((current?['visits'] ?? 0) as int) < moveVisits) {
        // explicitly requested so take as long as you need
        cn.analyze(engine, priority: priority, visits: moveVisits, refineMove: move, timeLimit: false);
      }
    }
  }

  /// Lets the AI play from the current node: to the end of the game (`untilMove == 'end'`, added as a shortcut), or
  /// up to move [untilMove] steering the score towards [targetBAdvantage] (to set up a position).
  void selfplay(Object untilMove, {double? targetBAdvantage}) {
    final cn = currentNode;
    final setup = untilMove != 'end' && targetBAdvantage != null;
    int? visits;
    Map<String, dynamic> engineSettings = {};
    if (targetBAdvantage != null) {
      visits = math.max(25, host.config('engine/fast_visits') as int);
      engineSettings = {'wideRootNoise': 0.03};
    }

    late void Function(GameNode) analyzeAndPlay;

    void requestAnalysisForNode(GameNode node) {
      engines[node.player]!.requestAnalysis(
        node,
        callback: (result, _) {
          node.setAnalysis(result, null, false, null, false);
          analyzeAndPlay(node);
        },
        priority: priorityDefault,
        analyzeFast: true,
        extraSettings: engineSettings,
        visits: visits,
      );
    }

    analyzeAndPlay = (GameNode node) {
      final candidates = node.candidateMoves;
      if (!identical(host.game, this)) return; // a new game happened
      var aiThoughts = 'Move generated by AI self-play\n';
      final Move move;
      if (setup) {
        final until = untilMove as int;
        if (node.depth >= until || candidates[0]['move'] == 'pass') {
          setCurrentNode(node);
          return;
        }
        final cnScore = cn.score!;
        final nodeScore = node.score!;
        final targetScore = cnScore + (node.depth - cn.depth + 1) * (targetBAdvantage - cnScore) / (until - cn.depth);
        const maxLoss = 5;
        final spread = 0.5 + (until - node.depth) * 0.15;
        final stddev = math.min(spread, 3.0);
        aiThoughts +=
            'Selecting moves aiming at score ${formatFixed(targetScore, 1)} +/- ${formatFixed(stddev.toDouble(), 2)} '
            'with < $maxLoss points lost\n';
        Map<String, dynamic> moveInfo;
        double lead(Map<String, dynamic> m) => (m['scoreLead'] as num).toDouble();
        double lost(Map<String, dynamic> m) => (m['pointsLost'] as num).toDouble();
        if ((nodeScore - targetScore).abs() < 3 * stddev) {
          final weightedCands = [
            for (var i = 0; i < candidates.length; i++)
              if (lost(candidates[i]) < maxLoss || i == 0)
                (
                  candidates[i],
                  math.exp(-0.5 * math.pow((lead(candidates[i]) - targetScore).abs() / stddev, 2)) *
                      math.exp(-0.5 * math.pow(math.min(0, lost(candidates[i])) / maxLoss, 2)),
                ),
          ];
          moveInfo = weightedSelectionWithoutReplacement(weightedCands, 1, (c) => c.$2, random)[0].$1;
          for (final (cand, wt) in weightedCands) {
            host.log(
              '${identical(moveInfo, cand) ? '* ' : '  '} ${cand['move']} ${cand['scoreLead']} $wt',
              outputExtraDebug,
            );
            aiThoughts +=
                'Move option: ${cand['move']} score ${formatFixed(lead(cand), 2)} loss ${formatFixed(lost(cand), 2)} '
                'weight ${(wt).toStringAsExponential(3)}\n';
          }
        } else {
          // we're a bit lost, far away from target, just push it closer
          moveInfo = candidates.first;
          for (final c in candidates.skip(1)) {
            if ((lead(c) - targetScore).abs() < (lead(moveInfo) - targetScore).abs()) moveInfo = c;
          }
          host.log(
            '* Played ${moveInfo['move']} ${moveInfo['scoreLead']} because score deviation between current '
            'score $nodeScore and target score $targetScore > ${3 * stddev}',
            outputExtraDebug,
          );
          aiThoughts +=
              'Move played to close difference between score ${formatFixed(nodeScore, 1)} and target '
              '${formatFixed(targetScore, 1)} quickly.';
        }
        host.log(
          'Self-play until $until target $targetBAdvantage: ${candidates.length} candidates -> move '
          '${moveInfo['move']} score ${moveInfo['scoreLead']} point loss ${moveInfo['pointsLost']}',
          outputDebug,
        );
        move = Move.fromGtp(moveInfo['move'] as String, player: node.nextPlayer);
      } else if (candidates.isNotEmpty) {
        // just selfplay to end
        move = Move.fromGtp(candidates[0]['move'] as String, player: node.nextPlayer);
      } else {
        // 1 visit etc
        final polmoves = node.policyRanking;
        move = (polmoves != null && polmoves.isNotEmpty) ? polmoves[0].$2 : Move();
      }
      if (move.isPass) {
        if (identical(currentNode, cn)) setCurrentNode(node);
        return;
      }
      final newNode = GameNode(parent: node, move: move);
      newNode.aiThoughts = aiThoughts;
      if (setup) {
        setCurrentNode(newNode);
        host.setStatus(
          fillTemplate(i18n.tr('setup game status message'), {'move': newNode.depth, 'until_move': untilMove}),
          statusInfo,
        );
      } else {
        if (!identical(node, cn)) node.removeShortcut();
        cn.addShortcut(newNode);
      }
      host.redrawMoveTree();
      requestAnalysisForNode(newNode);
    };

    requestAnalysisForNode(cn);
  }

  /// Teaching mode: undoes the move at [node] when it lost enough points, as the trainer settings say.
  void analyzeUndo(GameNode node) {
    final trainConfig = (host.config('trainer') as Map).cast<String, dynamic>();
    final move = node.move;
    if (!identical(node, currentNode) || node.autoUndo != null || !node.analysisComplete || move == null) return;
    final pointsLost = node.pointsLost!;
    final thresholds = (trainConfig['eval_thresholds'] as List).cast<num>();
    final numUndoPrompts = (trainConfig['num_undo_prompts'] as List).cast<num>();
    var i = 0;
    while (i < thresholds.length && pointsLost < thresholds[i]) {
      i += 1;
    }
    final num numUndos = i < numUndoPrompts.length ? numUndoPrompts[i] : 0;
    final bool doUndo;
    if (numUndos == 0) {
      doUndo = false;
    } else if (numUndos < 1) {
      // probability
      doUndo = node.undoThreshold < numUndos && node.parent!.children.length == 1;
    } else {
      doUndo = node.parent!.children.length <= numUndos;
    }
    node.autoUndo = doUndo;
    if (doUndo) {
      undo(1);
      host.setStatus(
        fillTemplate(i18n.tr('teaching undo message'), {'move': move.gtp(), 'points_lost': pointsLost}),
        statusTeaching,
      );
      host.updateState();
    }
  }

  // -- insert mode --

  /// Starts (true), ends (false) or toggles (`'toggle'`) insert mode. Moves played while inserting go before the
  /// current line; ending copies the rest of the line after them, up to the first move that became illegal.
  void setInsertMode(Object mode) {
    final on = mode == 'toggle' ? !insertMode : mode as bool;
    if (on == insertMode) return;
    insertMode = on;
    if (on) {
      final children = currentNode.orderedChildren;
      if (children.isEmpty) {
        insertMode = false;
      } else {
        insertAfter = currentNode.orderedChildren[0];
        host.setStatus(i18n.tr('starting insert mode'), statusInfo);
      }
    } else {
      var copyFromNode = insertAfter!;
      var copyToNode = currentNode;
      var numCopied = 0;
      if (!identical(copyToNode, insertAfter!.parent)) {
        final aboveInsertionRoot = insertAfter!.parent!.nodesFromRoot;
        final alreadyInsertedMoves = [
          for (final n in copyToNode.nodesFromRoot)
            if (!aboveInsertionRoot.contains(n) && n.move != null) n.move!,
        ];
        try {
          while (true) {
            for (final m in copyFromNode.moveWithPlacements) {
              if (!alreadyInsertedMoves.contains(m)) {
                validateMoveAndUpdateChains(m, true);
                // this inserts (one copy of the node per move or placement)
                copyToNode = GameNode(
                  parent: copyToNode,
                  properties: {for (final e in copyFromNode.properties.entries) e.key: List.of(e.value)},
                );
                numCopied += 1;
              }
            }
            if (copyFromNode.children.isEmpty) break;
            copyFromNode = copyFromNode.orderedChildren[0];
          }
        } on IllegalMoveException {
          // illegal move = stop
        }
        calculateGroups(); // recalculate groups
        host.setStatus(fillTemplate(i18n.tr('ending insert mode'), {'num_copied': numCopied}), statusInfo);
        analyzeAllNodes(analyzeFast: true, evenIfPresent: false);
      } else {
        host.setStatus('', statusInfo);
      }
    }
    host.insertNode = insertMode ? insertAfter : null;
    host.redrawMoveTree();
    host.updateState(redrawBoard: true);
  }
}
