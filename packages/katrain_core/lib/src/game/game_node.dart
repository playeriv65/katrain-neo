// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/game_node.py.

import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';

import '../constants.dart';
import '../engine/analysis_engine.dart';
import '../i18n/i18n.dart';
import '../sgf/go_node.dart';
import '../sgf/move.dart';
import '../sgf/parser.dart';
import '../utils/format.dart';
import '../utils/random.dart';
import '../utils/template.dart';
import '../utils/utils.dart';

/// The colour KaTrain uses for clickable PVs in comments (Theme.INFO_PV_COLOR).
const infoPvColor = '#cccc1a';

/// `analysis_dumps`: the KT property values for a node's analysis (gzipped, base64).
List<String> analysisDumps(Map<String, dynamic> analysis) {
  final copy = jsonDecode(jsonEncode(analysis)) as Map<String, dynamic>;
  for (final moveDict in (copy['moves'] as Map<String, dynamic>).values) {
    (moveDict as Map<String, dynamic>).remove('ownership'); // per-move ownership rarely used
  }
  final ownershipData = packFloats(_doubles(copy.remove('ownership')));
  final policyData = packFloats(_doubles(copy.remove('policy')));
  final mainData = utf8.encode(jsonEncode(copy)); // the same text as KaTrain's json.dumps
  // gzip.compress uses level 9; the deflate bytes can still differ between zlib builds, the content does not
  return [
    for (final data in [ownershipData, policyData, mainData]) base64.encode(GZipEncoder().encodeBytes(data, level: 9)),
  ];
}

List<double>? _doubles(Object? values) =>
    values == null ? null : [for (final v in values as List) (v as num).toDouble()];

/// A node of a KaTrain game: moves and setup like any SGF node, plus notes, analysis and teaching state.
class GameNode extends BaseGoNode<GameNode> {
  /// null: not analysed. false: not undone (good move). true: undone (bad move).
  bool? autoUndo;
  bool? playedMistakeSound;
  String aiThoughts = '';
  String note = '';
  int moveNumber = 0;
  double timeUsed = 0;

  /// For fractional undos in teaching mode.
  double undoThreshold;
  String? endState;
  final List<(GameNode, GameNode)> shortcutsTo = [];
  GameNode? shortcutFrom;
  List<String>? analysisFromSgf;
  int analysisVisitsRequested = 0;
  late Map<String, dynamic> analysis;

  static int _nextSerial = 1;
  int? _serial;

  GameNode({super.parent, super.properties, super.move}) : undoThreshold = random.nextDouble() {
    clearAnalysis();
  }

  @override
  GameNode newNode({GameNode? parent, Move? move}) => GameNode(parent: parent, move: move);

  /// Collapses the branch between this node and [toNode].
  void addShortcut(GameNode toNode) {
    final nodes = [toNode];
    while (nodes.last.parent != null && nodes.last != this) {
      nodes.add(nodes.last.parent!);
    }
    if (nodes.last == this && nodes.length > 2) {
      final via = nodes[nodes.length - 2];
      shortcutsTo.add((toNode, via));
      toNode.shortcutFrom = this;
    }
  }

  void removeShortcut() {
    final from = shortcutFrom;
    if (from != null) {
      from.shortcutsTo.removeWhere((s) => s.$1 == this);
      shortcutFrom = null;
    }
  }

  /// Restores analysis saved in the KT property; false when there is none or it cannot be read.
  bool loadAnalysis() {
    final data = analysisFromSgf;
    if (data == null || data.isEmpty) return false;
    try {
      final (szx, szy) = root.boardSize;
      final boardSquares = szx * szy;
      final version = root.getProperty('KTV', analysisFormatVersion)!;
      if (version.compareTo(analysisFormatVersion) > 0) {
        throw FormatException('Can not decode analysis data with version $version, please update $appName');
      }
      final decoded = [for (final d in data) GZipDecoder().decodeBytes(base64.decode(d))];
      final main = jsonDecode(utf8.decode(decoded[2])) as Map<String, dynamic>;
      analysis = {
        ...main,
        'moves': LinkedHashMap<String, dynamic>.of(main['moves'] as Map<String, dynamic>),
        'policy': unpackFloats(decoded[1], boardSquares + 1),
        'ownership': unpackFloats(decoded[0], boardSquares),
      };
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('Error in loading analysis: $e');
      return false;
    }
  }

  @override
  void addListProperty(String property, List<String> values) {
    if (property == 'KT') {
      analysisFromSgf = values;
    } else if (property == 'C') {
      // strip out all previously auto generated comments; the rest becomes the editable note
      final comments = [
        for (final v in values)
          for (final c in v.split(sgfSeparatorMarker))
            if (c.trim().isNotEmpty && !c.contains(sgfInternalCommentsMarker)) c,
      ];
      note = comments.join().trim();
    } else {
      super.addListProperty(property, values);
    }
  }

  void clearAnalysis() {
    analysisVisitsRequested = 0;
    analysis = {'moves': <String, dynamic>{}, 'root': null, 'ownership': null, 'policy': null, 'completed': false};
  }

  int get _id => _serial ??= _nextSerial++;

  /// Properties to write, with KaTrain's generated comments, marks and analysis when asked for.
  @override
  Map<String, List<String>> sgfProperties([Object? options]) {
    final o = options is SgfSaveOptions ? options : const SgfSaveOptions();
    final properties = super.sgfProperties();
    final noteText = note.trim();
    if (o.saveAnalysis && analysisComplete) {
      try {
        properties['KT'] = analysisDumps(analysis);
      } catch (e) {
        // ignore: avoid_print
        print('Error in saving analysis: $e');
      }
    }
    final lost = pointsLost;
    final bool showClass;
    if (lost != null && lost != 0 && o.saveCommentsClass != null && o.evalThresholds != null) {
      showClass = o.saveCommentsClass![evaluationClass(lost, o.evalThresholds!)];
    } else {
      showClass = false;
    }
    var comments = properties['C'] ?? <String>[];
    final p = parent;
    if (p != null &&
        p.analysisExists &&
        analysisExists &&
        (noteText.isNotEmpty || ((o.saveCommentsPlayer ?? const {})[player] ?? false) && showClass)) {
      if (o.saveMarks) {
        final candidates = p.candidateMoves;
        final topX = Move.fromGtp(candidates[0]['move'] as String).sgf(boardSize);
        final bestSq = [
          for (final d in candidates)
            if ((d['pointsLost'] as num) <= 0.5 && d['move'] != 'pass' && d['order'] != 0)
              Move.fromGtp(d['move'] as String).sgf(boardSize),
        ];
        if (bestSq.isNotEmpty && !properties.containsKey('SQ')) properties['SQ'] = bestSq;
        if (topX.isNotEmpty && !properties.containsKey('MA')) properties['MA'] = [topX];
      }
      comments.add('\n${comment(sgf: true, interactive: false)}$sgfInternalCommentsMarker');
    }
    if (isRoot) {
      if (o.saveMarks) {
        comments = ['${i18n.tr('SGF start message')}$sgfInternalCommentsMarker\n'];
      } else {
        comments = [];
      }
      // KaTrain adds the existing comments a second time here (so the start message appears twice);
      // kept as it is for parity
      comments = [
        ...comments,
        ...comments,
        '\nSGF generated by $appName $appVersion$sgfInternalCommentsMarker\n',
      ];
      properties['CA'] = ['UTF-8'];
      properties['AP'] = ['$appName:$appVersion'];
      properties['KTV'] = [analysisFormatVersion];
    }
    if (shortcutFrom != null) {
      properties['KTSF'] = ['${shortcutFrom!._id}'];
    } else {
      properties.remove('KTSF');
    }
    if (shortcutsTo.isNotEmpty) {
      properties['KTSID'] = ['$_id'];
    } else {
      properties.remove('KTSID');
    }
    if (noteText.isNotEmpty) comments.insert(0, '$note\n');
    if (comments.isNotEmpty) {
      properties['C'] = [_stripNewlines(comments.join(sgfSeparatorMarker))];
    } else {
      properties.remove('C');
    }
    return properties;
  }

  static String _stripNewlines(String s) => s.replaceFirst(RegExp(r'^\n+'), '').replaceFirst(RegExp(r'\n+$'), '');

  /// Analysed, not undone moves first, then the ones not analysed, undone ones last.
  @override
  List<GameNode> orderChildren(List<GameNode> children) {
    final sorted = List.of(children);
    stableSortBy(sorted, (c) => c.autoUndo == null ? 0.5 : (c.autoUndo! ? 1 : 0));
    return sorted;
  }

  /// Asks [engine] to analyse this node; results are merged into [analysis] as they arrive.
  void analyze(
    AnalysisEngine<GameNode> engine, {
    int priority = priorityDefault,
    int? visits,
    bool ponder = false,
    bool timeLimit = true,
    Move? refineMove,
    bool analyzeFast = false,
    bool findAlternatives = false,
    List<int>? regionOfInterest,
    double? reportEvery = 1.0, // REPORT_DT
    bool regionRoot = false,
  }) {
    // regionRoot (KaTrain Neo, from the playeriv65/katrain fork): the region-limited result is also the node's
    // evaluation (tsumego frame: the best move outside the region is frame noise, so the local best move should
    // show no loss)
    engine.requestAnalysis(
      this,
      callback: (result, partial) =>
          setAnalysis(result, refineMove, findAlternatives, regionRoot ? null : regionOfInterest, partial),
      priority: priority,
      visits: visits,
      ponder: ponder,
      analyzeFast: analyzeFast,
      timeLimit: timeLimit,
      nextMove: refineMove,
      findAlternatives: findAlternatives,
      regionOfInterest: regionOfInterest,
      reportEvery: reportEvery,
    );
  }

  Map<String, dynamic> get _moves => analysis['moves'] as Map<String, dynamic>;

  void updateMoveAnalysis(Map<String, dynamic> moveAnalysis, String moveGtp) {
    final cur = _moves[moveGtp] as Map<String, dynamic>?;
    if (cur == null) {
      // some default values for keys missing in rootInfo
      _moves[moveGtp] = {'move': moveGtp, 'order': additionalMoveOrder, ...moveAnalysis};
    } else {
      // parent arriving after child
      cur['order'] = math.min(cur['order'] as int, (moveAnalysis['order'] ?? additionalMoveOrder) as int);
      if ((cur['visits'] as num) < (moveAnalysis['visits'] as num)) {
        cur.addAll(moveAnalysis);
      } else {
        // prior etc only
        for (final e in moveAnalysis.entries) {
          cur.putIfAbsent(e.key, () => e.value);
        }
      }
    }
  }

  void setAnalysis(
    Map<String, dynamic> analysisJson,
    Move? refineMove,
    bool additionalMoves,
    List<int>? regionOfInterest,
    bool partialResult,
  ) {
    final moveInfos = (analysisJson['moveInfos'] as List).cast<Map<String, dynamic>>();
    final rootInfo = analysisJson['rootInfo'] as Map<String, dynamic>;
    if (refineMove != null) {
      final pvTail = moveInfos.isNotEmpty ? (moveInfos[0]['pv'] as List).cast<String>() : <String>[];
      updateMoveAnalysis({
        'pv': [refineMove.gtp(), ...pvTail],
        ...rootInfo,
      }, refineMove.gtp());
    } else {
      if (additionalMoves) {
        // additional moves: old order matters, ignore new order
        for (final m in moveInfos) {
          m.remove('order');
        }
      } else {
        // normal update: old moves to end, new order matters. also for region?
        for (final moveDict in _moves.values) {
          (moveDict as Map<String, dynamic>)['order'] = additionalMoveOrder;
        }
      }
      for (final moveAnalysis in moveInfos) {
        updateMoveAnalysis(moveAnalysis, moveAnalysis['move'] as String);
      }
      // stored as doubles once here, since the board reads them on every redraw
      analysis['ownership'] = _doubles(analysisJson['ownership']);
      analysis['policy'] = _doubles(analysisJson['policy']);
      if (!additionalMoves && regionOfInterest == null) {
        analysis['root'] = rootInfo;
        final p = parent;
        final m = move;
        if (p != null && m != null) {
          rootInfo['pv'] = [m.gtp(), if (moveInfos.isNotEmpty) ...(moveInfos[0]['pv'] as List).cast<String>()];
          p.updateMoveAnalysis(rootInfo, m.gtp()); // update analysis in parent for consistency
        }
      }
      final isNormalQuery = !additionalMoves; // refineMove is null here
      analysis['completed'] = (analysis['completed'] as bool) || (isNormalQuery && !partialResult);
    }
  }

  List<double>? get ownership => analysis['ownership'] as List<double>?;

  List<double>? get policy => analysis['policy'] as List<double>?;

  bool get analysisExists => analysis['root'] != null;

  bool get analysisComplete => (analysis['completed'] as bool) && analysis['root'] != null;

  int get rootVisits => ((analysis['root'] as Map<String, dynamic>?)?['visits'] ?? 0) as int;

  Map<String, dynamic>? get _root => analysis['root'] as Map<String, dynamic>?;

  double? get score => (_root?['scoreLead'] as num?)?.toDouble();

  double? get winrate => (_root?['winrate'] as num?)?.toDouble();

  /// `B+3.5` style; like KaTrain, a score of exactly 0 given as argument falls back to this node's score.
  String? formatScore([double? scoreArg]) {
    final s = (scoreArg != null && scoreArg != 0) ? scoreArg : score;
    if (s == null) return null;
    final leading = s >= 0 ? 'B' : 'W';
    return '${i18n.tr('short color $leading')}+${formatFixed(s.abs(), 1)}';
  }

  /// `B 63.2%` style; a win rate of exactly 0 given as argument falls back to this node's, as in KaTrain.
  String? formatWinrate([double? winRateArg]) {
    final w = (winRateArg != null && winRateArg != 0) ? winRateArg : winrate;
    if (w == null) return null;
    final leading = w > 0.5 ? 'B' : 'W';
    return '${i18n.tr('short color $leading')} ${formatPercent(math.max(w, 1 - w), 1)}';
  }

  /// Rank of this move in the parent's policy (1-based), its probability, and the whole ranking.
  (int?, double, List<(double, Move)>) movePolicyStats() {
    final single = move;
    final p = parent;
    if (single != null && p != null) {
      final ranking = p.policyRanking;
      if (ranking != null) {
        for (var ix = 0; ix < ranking.length; ix++) {
          if (ranking[ix].$2 == single) return (ix + 1, ranking[ix].$1, ranking);
        }
      }
    }
    return (null, 0.0, []);
  }

  String makePv(String player, List<String> pv, bool interactive) {
    final text = '$player${pv.join(' ')}';
    if (interactive) return '[u][ref=$text][color=$infoPvColor]$text[/color][/ref][/u]';
    return text;
  }

  /// The info text KaTrain shows for a node (and writes into SGF comments).
  String comment({bool sgf = false, bool teach = false, bool details = false, bool interactive = true}) {
    final single = move;
    final p = parent;
    if (p == null || single == null) {
      // root
      // KaTrain looks up even JSON rules lowercased; with no translation they show as they are, lowercased
      final rules = i18n.tr(getProperty('RU', 'Japanese')!.toLowerCase());
      return '${i18n.tr('komi')}: ${formatFixed(komi, 1)}\n${i18n.tr('ruleset')}: $rules\n';
    }
    var text = '${fillTemplate(i18n.tr('move'), {'number': depth})}: ${single.player} ${single.gtp()}\n';
    if (analysisExists) {
      final s = score;
      if (sgf) {
        text += '${fillTemplate(i18n.tr('Info:score'), {'score': formatScore(s)})}\n';
        text += '${fillTemplate(i18n.tr('Info:winrate'), {'winrate': formatWinrate()})}\n';
      }
      if (p.analysisExists) {
        final previousTopMove = p.candidateMoves[0];
        if (sgf || details) {
          if (previousTopMove['move'] != single.gtp()) {
            final lost = pointsLost!;
            if (sgf && lost > 0.5) {
              text += '${fillTemplate(i18n.tr('Info:point loss'), {'points_lost': lost})}\n';
            }
            final topMove = previousTopMove['move'];
            final topScore = formatScore((previousTopMove['scoreLead'] as num).toDouble());
            text += '${fillTemplate(i18n.tr('Info:top move'), {'top_move': topMove, 'score': topScore})}\n';
          } else {
            text += '${i18n.tr('Info:best move')}\n';
          }
          final pv = previousTopMove['pv'] as List?;
          if (pv != null && pv.isNotEmpty && (sgf || details)) {
            final pvText = makePv(single.player, pv.cast<String>(), interactive);
            text += '${fillTemplate(i18n.tr('Info:PV'), {'pv': pvText})}\n';
          }
        }
        if (sgf || details || teach) {
          final (rank, probability, ranking) = movePolicyStats();
          if (rank != null) {
            text += '${fillTemplate(i18n.tr('Info:policy rank'), {'rank': rank, 'probability': probability})}\n';
          }
          if (rank != 1 && ranking.isNotEmpty && (sgf || details)) {
            final (polProb, polMove) = ranking[0];
            text += '${fillTemplate(i18n.tr('Info:policy best'), {'move': polMove.gtp(), 'probability': polProb})}\n';
          }
        }
      }
      if ((autoUndo ?? false) && sgf) {
        text += '${i18n.tr('Info:teaching undo')}\n';
        final topPv = analysisExists ? candidateMoves[0]['pv'] as List? : null;
        if (topPv != null && topPv.isNotEmpty) {
          final pvText = '$nextPlayer${topPv.cast<String>().join(' ')}';
          text += '${fillTemplate(i18n.tr('Info:undo predicted PV'), {'pv': pvText})}\n';
        }
      }
    } else {
      text = sgf ? i18n.tr('No analysis available') : i18n.tr('Analyzing move...');
    }
    if (aiThoughts.isNotEmpty && (sgf || details)) {
      text += '\n${fillTemplate(i18n.tr('Info:AI thoughts'), {'thoughts': aiThoughts})}';
    }
    final c = properties['C'];
    if (c != null) {
      text += '\n[u]SGF Comments:[/u]\n${c.join('\n')}';
    }
    return text;
  }

  /// Points this move lost against the parent's evaluation (positive is a loss).
  double? get pointsLost {
    final single = move;
    final p = parent;
    if (single != null && p != null && analysisExists && p.analysisExists) {
      return playerSign(single.player) * (p.score! - score!);
    }
    return null;
  }

  double? get parentRealizedPointsLost {
    final single = move;
    final pp = parent?.parent;
    if (single != null && pp != null && analysisExists && pp.analysisExists) {
      return playerSign(single.player) * (score! - pp.score!);
    }
    return null;
  }

  static int playerSign(String? player) => switch (player) {
    'B' => 1,
    'W' => -1,
    null => 0,
    _ => throw ArgumentError('KeyError: $player'),
  };

  /// The engine's candidate moves with points and win rate lost, best first.
  List<Map<String, dynamic>> get candidateMoves {
    if (!analysisExists) return [];
    final root = _root!;
    if (_moves.isEmpty) {
      final polMoves = policyRanking;
      final top = (polMoves != null && polMoves.isNotEmpty) ? polMoves[0].$2 : const Move(); // no info: pass
      return [
        {
          ...root,
          'pointsLost': 0,
          'winrateLost': 0,
          'order': 0,
          'move': top.gtp(),
          'pv': [top.gtp()],
        },
      ];
    }
    final rootScore = (root['scoreLead'] as num).toDouble();
    final rootWinrate = (root['winrate'] as num).toDouble();
    final moveDicts = [for (final d in _moves.values) d as Map<String, dynamic>];
    final topMove = [
      for (final d in moveDicts)
        if (d['order'] == 0) d,
    ];
    final topScoreLead = topMove.isNotEmpty ? (topMove[0]['scoreLead'] as num).toDouble() : rootScore;
    final sign = playerSign(nextPlayer);
    final result = [
      for (final d in moveDicts)
        {
          'pointsLost': sign * (rootScore - (d['scoreLead'] as num)),
          'relativePointsLost': sign * (topScoreLead - (d['scoreLead'] as num)),
          'winrateLost': sign * (rootWinrate - (d['winrate'] as num)),
          ...d,
        },
    ];
    final indexed = [for (var i = 0; i < result.length; i++) (i, result[i])];
    indexed.sort((a, b) {
      final c = (a.$2['order'] as int).compareTo(b.$2['order'] as int);
      if (c != 0) return c;
      final d = (a.$2['pointsLost'] as num).compareTo(b.$2['pointsLost'] as num);
      return d != 0 ? d : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// Moves from the highest policy value to the lowest, pass last among equals.
  List<(double, Move)>? get policyRanking {
    final pol = policy;
    if (pol == null || pol.isEmpty) return null;
    final (szx, szy) = boardSize;
    final grid = varToGrid(pol, (szx, szy));
    final moves = <(double, Move)>[
      for (var x = 0; x < szx; x++)
        for (var y = 0; y < szy; y++) (grid[y][x], Move(coords: (x, y), player: nextPlayer)),
      (pol.last, Move(player: nextPlayer)),
    ];
    stableSortBy(moves, (mp) => -mp.$1);
    return moves;
  }
}

/// What to include when writing a game to SGF (KaTrain's sgf_properties arguments).
class SgfSaveOptions {
  /// Players whose moves get generated comments, by colour.
  final Map<String, bool>? saveCommentsPlayer;

  /// For each evaluation class, whether moves of that class get generated comments.
  final List<bool>? saveCommentsClass;
  final List<num>? evalThresholds;
  final bool saveAnalysis;
  final bool saveMarks;

  const SgfSaveOptions({
    this.saveCommentsPlayer,
    this.saveCommentsClass,
    this.evalThresholds,
    this.saveAnalysis = false,
    this.saveMarks = false,
  });
}

/// Parser for KaTrain game trees.
final gameParser = SgfParser<GameNode>(({GameNode? parent}) => GameNode(parent: parent));
