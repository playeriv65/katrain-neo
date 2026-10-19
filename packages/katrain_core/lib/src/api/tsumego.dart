// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/api/tsumego.py:
// life-and-death problem mode built on KaTrain's tsumego frame and region-of-interest search.
//
// The solver may play any legal move; KataGo answers inside the problem region instead of following a fixed answer
// tree. The SGF's own solution tree, when present, is kept aside as a reference and never shown unless asked for.

import 'package:collection/collection.dart';

import 'dart:convert';
import 'dart:io';

import '../engine/io/local_katago.dart' show expandUser;
import '../game/game_node.dart';
import '../game/tsumego_frame.dart' show nearToEdge;
import '../sgf/codecs/py_codecs.dart';
import '../sgf/move.dart';
import '../utils/format.dart';
import 'args.dart';
import 'commands.dart';
import 'model.dart';
import 'protocol.dart';

const levelWords = [
  'elementary',
  'beginner',
  'easy',
  'intermediate',
  'medium',
  'advanced',
  'hard',
  'expert',
  '入门',
  '初级',
  '中级',
  '高级',
  '初段',
  '有段',
];
const alive = 0.5, dead = -0.5;

// -- problem collections

/// (start, end) of every top-level '(...)' group in SGF text, skipping property values.
List<(int, int)> _groupSpans(String text) {
  final spans = <(int, int)>[];
  var depth = 0;
  int? start;
  var inValue = false, escape = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inValue) {
      if (escape) {
        escape = false;
      } else if (ch == r'\') {
        escape = true;
      } else if (ch == ']') {
        inValue = false;
      }
    } else if (ch == '[') {
      inValue = true;
    } else if (ch == '(') {
      if (depth == 0) start = i;
      depth += 1;
    } else if (ch == ')') {
      depth -= 1;
      if (depth == 0 && start != null) {
        spans.add((start, i));
        start = null;
      }
    }
  }
  return spans;
}

/// Splits an SGF collection '(;...)(;...)' into its top-level game trees.
List<String> splitCollection(String text) => [for (final (s, e) in _groupSpans(text)) text.substring(s, e + 1)];

String? _prop(String text, String name) => RegExp(
  '(?<![A-Z])$name'
  r'\[((?:[^\]\\]|\\.)*)\]',
).firstMatch(text)?[1];

String _stripProp(String text, String name) => text.replaceAll(
  RegExp(
    '(?<![A-Z])$name'
    r'(\[(?:[^\]\\]|\\.)*\])+',
  ),
  '',
);

bool _hasStones(String text) => _prop(text, 'AB') != null || _prop(text, 'AW') != null;

/// Text of the first node of a '(;...)' tree.
String _firstNode(String tree) {
  final body = tree.substring(1, tree.length - 1).trimLeft();
  final spans = _groupSpans(body);
  final seq = spans.isNotEmpty ? body.substring(0, spans[0].$1) : body;
  return seq.contains(';') ? seq.split(';')[1] : seq; // values with ';' only cut the text we search, harmless
}

/// Every problem in an SGF file as (header comment, problem SGF).
///
/// Handles single problems, collections of game trees '(;...)(;...)', and collections stored as variations of one
/// stone-less root, one problem per variation. Variation problems get the root's properties (SZ etc.) merged into
/// their own first node.
List<(String?, String)> problemTexts(String text) {
  final problems = <(String?, String)>[];
  final trees = splitCollection(text);
  for (final tree in trees.isEmpty ? [text] : trees) {
    final stripped = tree.trim();
    final body = stripped.substring(1, stripped.length - 1);
    final spans = _groupSpans(body);
    final head = spans.isNotEmpty ? body.substring(0, spans[0].$1) : body;
    final children = [for (final (s, e) in spans) body.substring(s, e + 1)];
    if (_hasStones(head) || children.where((c) => _hasStones(_firstNode(c))).length < 2) {
      problems.add((null, tree));
      continue;
    }
    final header = (_prop(head, 'C') ?? '').trim().split('\n')[0];
    final rootProps = _stripProp(_stripProp(head.trim(), 'C'), 'GN').replaceFirst(RegExp(r'^;+'), '');
    for (final child in children) {
      if (_hasStones(_firstNode(child))) {
        final childBody = child.substring(1, child.length - 1).trimLeft();
        problems.add((header, '(;$rootProps${childBody.substring(1)})'));
      }
    }
  }
  return problems;
}

String? _firstMoveColor(String text) => RegExp(r'(?<![A-Za-z\\])([BW])\[[a-zA-Z]{0,2}\]').firstMatch(text)?[1];

String _firstCommentLine(String tree) => (_prop(_firstNode(tree), 'C') ?? '').trim().split('\n')[0].trim();

String? _read(String path) {
  final raw = File(path).readAsBytesSync();
  for (final codec in const ['utf_8', 'gb18030']) {
    final (text, errors) = decodeWith(codec, raw);
    if (errors == 0) return text;
  }
  return latin1.decode(raw);
}

String? _difficulty(String text, String path, [String? header]) {
  final di = _prop(text, 'DI');
  if (di != null && di.isNotEmpty) return di;
  final hay = '$path ${_prop(text, 'GN') ?? ''} ${_prop(text, 'GC') ?? ''} ${header ?? ''}'.toLowerCase();
  final m = RegExp(r'(\d{1,2}\s?[kd])(?![a-z])').firstMatch(hay);
  if (m != null) return m[1]!.replaceAll(' ', '');
  for (final w in levelWords) {
    if (hay.contains(w)) return w;
  }
  return null;
}

/// Sorts 'p-2' before 'p-10': runs of digits compare as numbers, the rest as lower case text.
List<(int, int, String)> _naturalKey(String path) {
  final out = <(int, int, String)>[];
  var last = 0;
  void text(String t) => out.add(RegExp(r'^\d+$').hasMatch(t) ? (0, int.parse(t), '') : (1, 0, t.toLowerCase()));
  for (final m in RegExp(r'\d+').allMatches(path)) {
    text(path.substring(last, m.start));
    out.add((0, int.parse(m[0]!), ''));
    last = m.end;
  }
  text(path.substring(last));
  return out;
}

int _compareKeys(List<(int, int, String)> a, List<(int, int, String)> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    final (a1, a2, a3) = a[i];
    final (b1, b2, b3) = b[i];
    final c = a1 != b1 ? a1.compareTo(b1) : (a2 != b2 ? a2.compareTo(b2) : a3.compareTo(b3));
    if (c != 0) return c;
  }
  return a.length.compareTo(b.length);
}

/// [path] as an absolute, normalised path (`~` expanded, `.` and `..` resolved).
String absPath(String path) {
  final sep = Platform.pathSeparator;
  var p = File(expandUser(path.isEmpty ? '.' : path)).absolute.path;
  if (Platform.isWindows) p = p.replaceAll('/', r'\');
  final prefixEnd = Platform.isWindows && RegExp(r'^[A-Za-z]:').hasMatch(p) ? 2 : 0;
  final parts = <String>[];
  for (final part in p.substring(prefixEnd).split(sep)) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return '${p.substring(0, prefixEnd)}$sep${parts.join(sep)}';
}

String _stem(String path) {
  final base = path.split(RegExp(r'[/\\]')).last;
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

/// [path] without its file extension.
String _withoutExtension(String path) {
  final slash = path.lastIndexOf('/');
  final dot = path.lastIndexOf('.');
  return dot > slash + 1 ? path.substring(0, dot) : path;
}

/// A problem found in a file: the file, which game tree in it, and what its name and comments say.
class TsumegoProblem {
  final String file;
  final int treeIndex;
  final String set;
  final String name;
  final String? difficulty;
  final String? toPlay;
  const TsumegoProblem({
    required this.file,
    required this.treeIndex,
    required this.set,
    required this.name,
    this.difficulty,
    this.toPlay,
  });

  Map<String, Object?> toJson() => {
    'file': file,
    'set': set,
    'name': name,
    'difficulty': difficulty,
    'to_play': toPlay,
  };
}

/// All problems in a file or folder (in a stable order).
List<TsumegoProblem> scanProblems(String source) {
  final src = absPath(source);
  final sep = Platform.pathSeparator;
  List<String> files;
  String base;
  if (Directory(src).existsSync()) {
    files = [
      for (final e in Directory(src).listSync(recursive: true, followLinks: true))
        if (e is File && e.path.toLowerCase().endsWith('.sgf')) e.path,
    ];
    stableSortBy(files, (f) => _SortKey(_naturalKey(f)));
    base = src;
  } else if (File(src).existsSync()) {
    files = [src];
    base = src.substring(0, src.lastIndexOf(sep));
  } else {
    throw ApiError('not_found', '$src does not exist');
  }
  final problems = <TsumegoProblem>[];
  for (final path in files) {
    final text = _read(path);
    if (text == null) continue;
    final rel = path.substring(base.length + 1).replaceAll(sep, '/');
    final stem = _stem(path);
    final trees = problemTexts(text);
    final collection = trees.length > 1;
    for (var j = 0; j < trees.length; j++) {
      final (header, tree) = trees[j];
      var name = _prop(tree, 'GN');
      if ((name == null || name.isEmpty) && collection) {
        final title = _firstCommentLine(tree);
        name = '$stem#${j + 1}${title.isNotEmpty && title.length <= 40 ? ' ($title)' : ''}';
      }
      final dir = rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '';
      final pl = _prop(tree, 'PL');
      problems.add(
        TsumegoProblem(
          file: path,
          treeIndex: j,
          // a multi-problem file is a set of its own; single-problem files are grouped by folder
          set: collection ? _withoutExtension(rel) : (dir.isNotEmpty ? dir : stem),
          name: name == null || name.isEmpty ? stem : name,
          difficulty: _difficulty(tree, rel, header),
          toPlay: pl != null && pl.isNotEmpty ? pl : _firstMoveColor(tree),
        ),
      );
    }
  }
  return problems;
}

class _SortKey implements Comparable<_SortKey> {
  final List<(int, int, String)> key;
  _SortKey(this.key);
  @override
  int compareTo(_SortKey other) => _compareKeys(key, other.key);
}

List<TsumegoProblem> filterProblems(List<TsumegoProblem> problems, {String? set, String? difficulty}) => [
  for (final p in problems)
    if ((set == null || '${p.set}/${p.name}'.toLowerCase().contains(set.toLowerCase())) &&
        (difficulty == null || p.difficulty?.toLowerCase() == difficulty.toLowerCase()))
      p,
];

String? _goalFromText(String? text) {
  final t = (text ?? '').toLowerCase();
  if (const ['kill', '杀', '净死'].any(t.contains)) return 'kill';
  if (const ['live', '活', 'make life'].any(t.contains)) return 'live';
  return null;
}

/// KaTrain moves SGF C[] comments into the note, so read both.
String _comment(GameNode node) => [node.note, ...?node.properties['C']].join(' ');

/// RIGHT/WRONG label of a solution line, from common SGF conventions.
String? _lineLabel(GameNode node) {
  for (final n in [node, ..._firstLine(node)]) {
    final text = _comment(n).toLowerCase();
    if (n.properties.containsKey('BM') || const ['wrong', 'incorrect', '失败', '错误'].any(text.contains)) {
      return 'wrong';
    }
    if (n.properties.containsKey('TE') || const ['right', 'correct', '正解', '正确'].any(text.contains)) {
      return 'correct';
    }
  }
  return null;
}

/// Cuts a PV at the first move outside the problem region (later moves are usually frame noise).
List<String> localPv(List pv, List<int>? region) {
  if (region == null || region.isEmpty) return [for (final m in pv) m as String];
  final [xmin, xmax, ymin, ymax] = region;
  final out = <String>[];
  for (final move in pv.cast<String>()) {
    final coords = Move.fromGtp(move).coords;
    if (coords != null && !(xmin <= coords.$1 && coords.$1 <= xmax && ymin <= coords.$2 && coords.$2 <= ymax)) break;
    out.add(move);
  }
  while (out.length >= 2 && out.last == 'pass' && out[out.length - 2] == 'pass') {
    out.removeLast();
  }
  return out;
}

List<GameNode> _firstLine(GameNode node) {
  final line = <GameNode>[];
  var n = node;
  while (n.children.isNotEmpty) {
    n = n.children[0];
    line.add(n);
  }
  return line;
}

const viewMargin = 2; // lines of empty board shown around the problem stones
const viewMinSpan = 7;

/// Rectangle around the problem's own stones (not the frame) for the zoomed diagram view.
List<int> problemViewRegion(GameNode problemRoot) {
  final (szx, szy) = problemRoot.boardSize;
  final coords = [
    for (final m in problemRoot.placements)
      if (m.coords != null) m.coords!,
  ];
  if (coords.isEmpty) return [0, szx - 1, 0, szy - 1];

  (int, int) span(int lo, int hi, int size) {
    lo = lo - viewMargin < 0 ? 0 : lo - viewMargin;
    hi = hi + viewMargin > size - 1 ? size - 1 : hi + viewMargin;
    final minSpan = viewMinSpan < size ? viewMinSpan : size;
    while (hi - lo + 1 < minSpan) {
      // grow towards the board center
      if (lo > 0 && (hi == size - 1 || lo > size - 1 - hi)) {
        lo -= 1;
      } else {
        hi += 1;
      }
    }
    return (lo, hi);
  }

  int minOf(Iterable<int> v) => v.reduce((a, b) => a < b ? a : b);
  int maxOf(Iterable<int> v) => v.reduce((a, b) => a > b ? a : b);
  final xs = coords.map((c) => c.$1), ys = coords.map((c) => c.$2);
  final (xmin, xmax) = span(minOf(xs), maxOf(xs), szx);
  final (ymin, ymax) = span(minOf(ys), maxOf(ys), szy);
  return [xmin, xmax, ymin, ymax];
}

/// No problem stone near any edge (same 'near' as KaTrain's tsumego frame).
bool isCenterProblem(GameNode problemRoot) {
  final (szx, szy) = problemRoot.boardSize;
  final coords = [
    for (final m in problemRoot.placements)
      if (m.coords != null) m.coords!,
  ];
  if (coords.isEmpty) return false;
  final xs = [for (final c in coords) c.$1], ys = [for (final c in coords) c.$2];
  int minOf(List<int> v) => v.reduce((a, b) => a < b ? a : b);
  int maxOf(List<int> v) => v.reduce((a, b) => a > b ? a : b);
  return minOf(xs) > nearToEdge &&
      minOf(ys) > nearToEdge &&
      maxOf(xs) < szx - 1 - nearToEdge &&
      maxOf(ys) < szy - 1 - nearToEdge;
}

/// A KataGo result for a problem position, kept to compare positions without searching again.
class _Evaluation {
  final double blackWinrate;
  final double blackScore;
  final int visits;
  final List<double>? ownership;
  final List<({String move, int visits, double blackWinrate, List<String> pv})> moves; // best first
  final String toMove;

  _Evaluation(Map<String, dynamic> result, GameNode node)
    : blackWinrate = (result['rootInfo']['winrate'] as num).toDouble(),
      blackScore = (result['rootInfo']['scoreLead'] as num).toDouble(),
      visits = result['rootInfo']['visits'] as int,
      ownership = (result['ownership'] as List?)?.map((v) => (v as num).toDouble()).toList(),
      moves = _sortedMoves(result['moveInfos'] as List? ?? const []),
      toMove = node.nextPlayer;

  static List<({String move, int visits, double blackWinrate, List<String> pv})> _sortedMoves(List infos) {
    final moves = infos.cast<Map<String, dynamic>>().toList();
    stableSortBy(moves, (m) => (m['order'] as num?) ?? 99);
    return [
      for (final m in moves)
        (
          move: m['move'] as String,
          visits: m['visits'] as int,
          blackWinrate: (m['winrate'] as num).toDouble(),
          pv: [...?(m['pv'] as List?)?.cast<String>()],
        ),
    ];
  }

  double winrateFor(String player) => player == 'B' ? blackWinrate : 1 - blackWinrate;
  double scoreFor(String player) => player == 'B' ? blackScore : -blackScore;
}

class TsumegoState {
  final TsumegoProblem problem;
  final int index;
  final String? source;
  final GameNode solutionRoot; // the whole SGF tree with its answer branches (hidden)
  final GameNode problemRoot;
  final GameNode start;
  List<int>? region;
  final String toPlay;
  String? goal;
  (int, int)? group; // a stone of the target group
  final Map<GameNode, _Evaluation> _evals = Map.identity();
  int attempts = 0;

  /// The frame node (child of the problem root) holds only the frame's stones.
  final Set<(int, int)> frameCoords;
  final List<int> viewRegion;

  TsumegoState(this.problem, this.index, this.source, this.solutionRoot, this.problemRoot, this.start, this.region)
    : toPlay = problemRoot.initialPlayer,
      frameCoords = identical(start, problemRoot) ? {} : {for (final m in start.placements) m.coords!},
      viewRegion = problemViewRegion(problemRoot),
      goal = _goalFromText(
        [_comment(solutionRoot), ...?solutionRoot.properties['GC'], ...?solutionRoot.properties['GN']].join(' '),
      );

  Map<String, Object?> summary() => {
    'problem': {...problem.toJson(), 'index': index, 'source': source},
    'start': nodeRef(start),
    'to_play': toPlay,
    'goal': goal,
    'target_group': group == null ? null : gtp(group),
    'frame': !identical(start, problemRoot),
    'region': regionJson(region),
    'has_reference_solution': solutionRoot.children.isNotEmpty,
    'attempts': attempts,
    'view': regionJson(viewRegion),
  };
}

TsumegoState _ts(CommandHandler h) {
  final ts =
      h.state.tsumego ??
      (throw ApiError('no_tsumego', 'no problem loaded', {'hint': 'katrain-neo tsumego load <file-or-folder>'}));
  if (!identical(h.game.root, ts.problemRoot)) {
    h.state.tsumego = null;
    throw ApiError('no_tsumego', 'the problem was replaced by another game');
  }
  return ts;
}

// -- evaluation

List<Move>? _chainAt(GameNode node, (int, int) coords) {
  final g = boardAt(node);
  final cid = g.board[coords.$2][coords.$1];
  return cid < 0 ? null : g.chains[cid];
}

/// The largest chain in the region that the goal is about: the solver's to live, the opponent's to kill.
(int, int)? _defaultGroup(TsumegoState ts, GameNode node) {
  if (ts.goal == null) return null;
  final color = ts.goal == 'live' ? ts.toPlay : Move.opponentPlayer(ts.toPlay);
  final [xmin, xmax, ymin, ymax] = ts.region ?? [0, node.boardSize.$1 - 1, 0, node.boardSize.$2 - 1];
  bool inRegion(Move m) => xmin <= m.coords!.$1 && m.coords!.$1 <= xmax && ymin <= m.coords!.$2 && m.coords!.$2 <= ymax;
  List<Move>? best;
  for (final c in boardAt(node).chains) {
    if (c.isNotEmpty && c[0].player == color && c.any(inRegion) && c.length > (best?.length ?? 0)) best = c;
  }
  return best?[0].coords;
}

Future<_Evaluation> _evaluate(CommandHandler h, TsumegoState ts, GameNode node, int visits, int timeout) async {
  final cached = ts._evals[node];
  if (cached != null && cached.visits >= visits * 0.9) return cached;
  final raw = await h.search(
    node,
    h.engineFor(node),
    visits,
    region: ts.region,
    timeout: timeout,
    ownership: true,
    regionRoot: true,
  );
  return ts._evals[node] = _Evaluation(raw, node);
}

/// Whether the target group lives: by KataGo's average ownership of its stones.
Map<String, Object?>? _groupStatus(TsumegoState ts, GameNode node, _Evaluation ev) {
  final group = ts.group;
  if (group == null) return null;
  final chain = _chainAt(node, group);
  if (chain == null) return {'status': 'captured', 'stones': 0};
  final own = ev.ownership;
  if (own == null || own.isEmpty) return {'status': 'unknown', 'stones': chain.length};
  final color = chain[0].player;
  final sign = color == 'B' ? 1 : -1;
  final avg = chain.fold(0.0, (sum, m) => sum + sign * ownershipAt(own, m.coords!, node.boardSize)) / chain.length;
  final status = avg >= alive
      ? 'alive'
      : avg <= dead
      ? 'dead'
      : 'unsettled';
  return {'status': status, 'color': color, 'stones': chain.length, 'ownership': rounded(avg, 2)};
}

bool? _goalMet(TsumegoState ts, Map<String, Object?>? status) {
  final s = status?['status'];
  if (ts.goal == null || s == null) return null;
  return ts.goal == 'kill' ? s == 'dead' || s == 'captured' : s == 'alive';
}

const mistake = (winrate: 0.10, points: 3.0);
const inaccuracy = (winrate: 0.03, points: 1.0);

/// best / ok / inaccuracy / mistake. Score counts as much as winrate: when the frame leaves one side far ahead or
/// behind, winrates sit near 0 or 1 and barely move even for losing moves.
String _verdict(bool wasBest, double winrateLost, double scoreLost) {
  if (wasBest) return 'best';
  if (winrateLost >= mistake.winrate || scoreLost >= mistake.points) return 'mistake';
  if (winrateLost >= inaccuracy.winrate || scoreLost >= inaccuracy.points) return 'inaccuracy';
  return 'ok';
}

List<Map<String, Object?>> _candidates(TsumegoState ts, _Evaluation ev, [int n = 5]) => [
  for (final m in ev.moves.take(n))
    {
      'move': m.move,
      'visits': m.visits,
      'winrate': rounded(ev.toMove == 'B' ? m.blackWinrate : 1 - m.blackWinrate, 4),
      'pv': localPv(m.pv, ts.region).take(12).toList(),
    },
];

// -- commands

int _visits(CommandHandler h, ApiArgs a) =>
    a.integer('visits', orElse: ((h.host.config('engine') as Map)['max_visits'] as int?) ?? 500, min: 1)!;

List<TsumegoProblem> _problems(ApiArgs a) => filterProblems(
  scanProblems(a.text('source', orElse: '')!),
  set: a.text('set'),
  difficulty: a.text('difficulty'),
);

Object? _list(CommandHandler h, ApiArgs a) {
  final problems = _problems(a);
  final sets = <String, int>{}, levels = <String, int>{};
  for (final p in problems) {
    sets[p.set] = (sets[p.set] ?? 0) + 1;
    final level = p.difficulty ?? 'unknown';
    levels[level] = (levels[level] ?? 0) + 1;
  }
  return {
    'total': problems.length,
    'sets': sets,
    'difficulties': levels,
    'problems': [
      for (final (i, p) in problems.take(a.integer('limit', orElse: 200, min: 1)!).indexed) {'index': i, ...p.toJson()},
    ],
  };
}

Object? _load(CommandHandler h, ApiArgs a) {
  final problems = _problems(a);
  final index = a.integer('index', orElse: 0, min: 0)!;
  if (index >= problems.length) {
    throw ApiError('not_found', 'problem index $index out of range (${problems.length} problems)');
  }
  final problem = problems[index];
  final GameNode solutionRoot;
  try {
    solutionRoot = gameParser.parseSgf(problemTexts(_read(problem.file)!)[problem.treeIndex].$2);
  } on Object catch (e) {
    throw ApiError('sgf_parse_error', '${problem.file}: $e');
  }
  // the problem without its answer tree and comments (they often give the answer away)
  final problemRoot = GameNode(
    properties: {
      for (final MapEntry(:key, :value) in solutionRoot.properties.entries)
        if (key != 'C') key: List.of(value),
      'PL': [solutionRoot.initialPlayer],
    },
  );
  if (problemRoot.placements.isEmpty) throw ApiError('bad_problem', 'problem has no setup stones');
  final backup = loadTree(h, problemRoot);
  final game = h.game;
  if (a.flag('frame', orElse: !isCenterProblem(game.root))) {
    h.host.tsumegoFrame(a.flag('ko'), a.integer('margin', orElse: 4, min: 1)!);
  } else {
    // center problems: KaTrain's frame would wall the group in; keep the open board, search locally
    game.setRegionOfInterest(problemViewRegion(game.root));
    game.regionRoot = true;
    game.root.analyze(game.engines[game.root.nextPlayer]!, regionOfInterest: game.regionOfInterest, regionRoot: true);
  }
  final ts = TsumegoState(
    problem,
    index,
    a.text('source'),
    solutionRoot,
    game.root,
    game.currentNode,
    game.regionOfInterest,
  );
  h.state.tsumego = ts;
  ts.group = _defaultGroup(ts, ts.start);
  if (a.flag('zoom', orElse: true)) h.host.setZoom(ts.viewRegion, ts.frameCoords);
  h.refresh();
  return {...ts.summary(), 'previous_game_backup': backup};
}

Object? _target(CommandHandler h, ApiArgs a) {
  final ts = _ts(h);
  final size = ts.start.boardSize;
  final goal = a.text('goal');
  if (goal != null) {
    if (goal != 'kill' && goal != 'live') throw ApiError('bad_argument', 'goal must be kill or live');
    ts.goal = goal;
  }
  final region = a.text('region');
  if (region != null) {
    ts.region = parseRegion(region, size);
    h.game.setRegionOfInterest(List.of(ts.region!));
    ts._evals.clear();
  }
  final group = a.text('group');
  if (group != null) {
    final coords = parseCoords(group, size);
    if (coords == null || _chainAt(ts.start, coords) == null) {
      throw ApiError('bad_argument', 'no stone at $group in the starting position');
    }
    ts.group = coords;
  } else if (goal != null) {
    ts.group ??= _defaultGroup(ts, ts.start);
  }
  h.refresh(false);
  return ts.summary();
}

Future<Object?> _eval(CommandHandler h, ApiArgs a) async {
  final ts = _ts(h);
  final node = h.game.currentNode;
  final ev = await _evaluate(h, ts, node, _visits(h, a), a.integer('timeout', orElse: 300, min: 1)!);
  final status = _groupStatus(ts, node, ev);
  return {
    'node': nodeRef(node),
    'to_move': node.nextPlayer,
    'solver': ts.toPlay,
    'solver_winrate': rounded(ev.winrateFor(ts.toPlay), 4),
    'solver_score': rounded(ev.scoreFor(ts.toPlay), 2),
    'target': status,
    'goal_met': _goalMet(ts, status),
    'best_moves': _candidates(ts, ev),
  };
}

Future<Object?> _try(CommandHandler h, ApiArgs a) async {
  final timeout = a.integer('timeout', orElse: 300, min: 1)!;
  final ts = _ts(h);
  final cn = h.game.currentNode;
  if (!cn.nodesFromRoot.any((n) => identical(n, ts.start))) {
    throw ApiError('outside_problem', 'current position is not part of the problem', {'hint': 'tsumego reset'});
  }
  final move = Move(
    coords: parseCoords(a.text('move', orElse: '')!, cn.boardSize),
    player: cn.nextPlayer,
  );
  checkMovesLegal(cn, [move]);
  final visits = _visits(h, a);
  final before = await _evaluate(h, ts, cn, visits, timeout);
  final node = _play(h, cn, move);
  final after = await _evaluate(h, ts, node, visits, timeout);
  ts.attempts += 1;

  final winrateLost = before.winrateFor(move.player) - after.winrateFor(move.player);
  final scoreLost = before.scoreFor(move.player) - after.scoreFor(move.player);
  final best = before.moves.firstOrNull?.move;
  final wasBest = best == move.gtp();
  final status = _groupStatus(ts, node, after);
  final reply = after.moves.firstOrNull;
  final result = <String, Object?>{
    'move': '${move.player}:${move.gtp()}',
    'node': nodeRef(node),
    'mover_winrate_before': rounded(before.winrateFor(move.player), 4),
    'mover_winrate_after': rounded(after.winrateFor(move.player), 4),
    'winrate_lost': rounded(winrateLost, 4),
    'score_lost': rounded(scoreLost, 2),
    'best_move': best,
    'was_best_move': wasBest,
    'verdict': _verdict(wasBest, winrateLost, scoreLost),
    'target': status,
    'goal_met': move.player == ts.toPlay ? _goalMet(ts, status) : null,
    'better_moves': _candidates(ts, before, 3),
    'refutation_pv': reply == null ? <String>[] : localPv(reply.pv, ts.region).take(12).toList(),
  };
  if (a.flag('reply', orElse: true) && reply != null) {
    final answer = Move.fromGtp(reply.move, player: node.nextPlayer);
    result['reply'] = answer.isPass
        ? {'move': '${answer.player}:pass', 'node': null}
        : {'move': '${answer.player}:${answer.gtp()}', 'node': nodeRef(_play(h, node, answer, analyze: true))};
  }
  return result;
}

/// Plays [move] below [parent] and shows it; with [analyze], analysed locally like the problem.
GameNode _play(CommandHandler h, GameNode parent, Move move, {bool analyze = false}) {
  final node = h.addNodes(parent, [move], analyze: 'none').$1.single;
  if (analyze) {
    final ts = h.state.tsumego;
    node.analyze(h.game.engines[node.nextPlayer]!, regionOfInterest: ts?.region, regionRoot: ts != null);
  }
  h.goto(node);
  return node;
}

Object? _reset(CommandHandler h, ApiArgs a) {
  final ts = _ts(h);
  for (final child in List.of(ts.start.children)) {
    if (child.nodesInTree.every(h.state.created.contains)) h.removeSubtree(child);
  }
  h.goto(ts.start);
  ts._evals.removeWhere((node, _) => !identical(node, ts.start));
  ts.attempts = 0;
  h.state.marks = [];
  return ts.summary();
}

Future<Object?> _solution(CommandHandler h, ApiArgs a) async {
  final ts = _ts(h);
  final lines = [
    for (final child in ts.solutionRoot.children)
      (
        moves: [
          for (final n in [child, ..._firstLine(child)]) ?n.move,
        ],
        label: _lineLabel(child),
      ),
  ];
  final ev = await _evaluate(h, ts, ts.start, _visits(h, a), a.integer('timeout', orElse: 300, min: 1)!);
  final katagoLine = ev.moves.isEmpty ? <String>[] : localPv(ev.moves.first.pv, ts.region).take(16).toList();
  final out = <String, Object?>{
    'reference_lines': [
      for (final line in lines) {'moves': _colored(line.moves), 'label': line.label},
    ],
    'katago_line': katagoLine,
    'start': nodeRef(ts.start),
  };
  if (a.flag('show')) {
    final preferred = lines.where((l) => l.label == 'correct').firstOrNull ?? lines.firstOrNull;
    try {
      h.goto(ts.start);
      final moves = preferred?.moves ?? parseMoves(katagoLine, ts.start.boardSize, ts.start.nextPlayer);
      out['shown'] = showPv(h, ts.start, moves);
    } on ApiError catch (e) {
      out['show_error'] = e.toJson();
    }
  }
  return out;
}

List<String> _colored(List<Move> moves) => [for (final m in moves) '${m.player}:${m.gtp()}'];

Object? _status(CommandHandler h, ApiArgs a) => h.state.tsumego == null
    ? {'active': false}
    : {'active': true, ..._ts(h).summary(), 'current': nodeRef(h.game.currentNode)};

final Map<String, ApiCommand> tsumegoCommands = {
  'tsumego.list': const ApiCommand(
    _list,
    'List problems in an SGF file/folder, optionally filtered by set and difficulty.',
    waitsForEngine: true,
  ),
  'tsumego.load': const ApiCommand(
    _load,
    "Load problem #index (after filters), hide its answer tree, add KaTrain's tsumego frame and local region.",
  ),
  'tsumego.target': const ApiCommand(
    _target,
    'Set goal (kill/live, for the player to move), target group stone and local search region.',
  ),
  'tsumego.eval': const ApiCommand(
    _eval,
    'Local KataGo evaluation of the current problem position: target status and best local moves.',
    waitsForEngine: true,
  ),
  'tsumego.try': const ApiCommand(
    _try,
    'Play a move in the problem; KataGo evaluates it and (reply=true) answers with its best local move.',
    waitsForEngine: true,
  ),
  'tsumego.reset': const ApiCommand(_reset, 'Back to the starting position; attempt moves are removed.'),
  'tsumego.solution': const ApiCommand(
    _solution,
    "Reference answer lines from the SGF (labelled correct/wrong when marked) plus KataGo's local line.",
    waitsForEngine: true,
  ),
  'tsumego.status': const ApiCommand(_status, 'Current problem, goal, target and attempts.'),
};
