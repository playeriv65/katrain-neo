// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/api/tsumego.py:
// life-and-death problem mode built on KaTrain's tsumego frame and region-of-interest search.
//
// The solver may play any legal move; KataGo answers inside the problem region instead of following a fixed answer
// tree. The SGF's own solution tree, when present, is kept aside as a reference and never shown unless asked for.

import 'dart:convert';
import 'dart:io';

import '../engine/io/local_katago.dart' show expandUser;
import '../game/game_node.dart';
import '../game/tsumego_frame.dart' show nearToEdge;
import '../sgf/codecs/py_codecs.dart';
import '../sgf/move.dart';
import '../utils/py_format.dart';
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

/// Python's `str.lstrip()`.
String _lstrip(String s) => s.replaceFirst(RegExp(r'^\s+'), '');

/// Text of the first node of a '(;...)' tree.
String _firstNode(String tree) {
  final body = _lstrip(tree.substring(1, tree.length - 1));
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
        final childBody = _lstrip(child.substring(1, child.length - 1));
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

/// Sorts 'p-2' before 'p-10' (Python's `re.split(r"(\d+)")` with digit runs compared as numbers).
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

/// `os.path.abspath(os.path.expanduser(path))`.
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

/// `os.path.splitext(path)[0]`.
String _withoutExtension(String path) {
  final slash = path.lastIndexOf('/');
  final dot = path.lastIndexOf('.');
  return dot > slash + 1 ? path.substring(0, dot) : path;
}

/// All problems in a file or folder, as metadata (in a stable order).
List<Map<String, Object?>> scanProblems(String source) {
  final src = absPath(source);
  final sep = Platform.pathSeparator;
  List<String> files;
  String base;
  if (Directory(src).existsSync()) {
    files = [
      for (final e in Directory(src).listSync(recursive: true, followLinks: true))
        if (e is File && e.path.toLowerCase().endsWith('.sgf')) e.path,
    ];
    mergeSortBy(files, (f) => _SortKey(_naturalKey(f)));
    base = src;
  } else if (File(src).existsSync()) {
    files = [src];
    base = src.substring(0, src.lastIndexOf(sep));
  } else {
    throw ApiError('not_found', '$src does not exist');
  }
  final problems = <Map<String, Object?>>[];
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
      problems.add({
        'file': path,
        'tree_index': j,
        // a multi-problem file is a set of its own; single-problem files are grouped by folder
        'set': collection ? _withoutExtension(rel) : (dir.isNotEmpty ? dir : stem),
        'name': name == null || name.isEmpty ? stem : name,
        'difficulty': _difficulty(tree, rel, header),
        'to_play': pl != null && pl.isNotEmpty ? pl : _firstMoveColor(tree),
      });
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

List<Map<String, Object?>> filterProblems(List<Map<String, Object?>> problems, Object? setFilter, Object? difficulty) {
  var out = problems;
  if (truthy(setFilter)) {
    final want = pyStr(setFilter).toLowerCase();
    out = [
      for (final p in out)
        if ('${p['set']}/${p['name']}'.toLowerCase().contains(want)) p,
    ];
  }
  if (truthy(difficulty)) {
    final want = pyStr(difficulty).toLowerCase();
    out = [
      for (final p in out)
        if (truthy(p['difficulty']) && (p['difficulty'] as String).toLowerCase() == want) p,
    ];
  }
  return out;
}

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

class TsumegoState {
  final Map<String, Object?> meta;
  final GameNode solutionRoot; // full SGF tree incl. answer branches (hidden)
  final GameNode problemRoot;
  final GameNode start;
  List<int>? region;
  final String toPlay;
  String? goal;
  (int, int)? group; // coords of a stone in the target group
  Map<GameNode, Map<String, Object?>> evals = Map.identity(); // node -> summarised KataGo result
  int attempts = 0;

  /// The frame node (child of the problem root) holds only the frame's stones.
  final Set<(int, int)> frameCoords;
  final List<int> viewRegion;

  TsumegoState(this.meta, this.solutionRoot, this.problemRoot, this.start, this.region, this.toPlay)
    : frameCoords = identical(start, problemRoot) ? {} : {for (final m in start.placements) m.coords!},
      viewRegion = problemViewRegion(problemRoot) {
    goal = _goalFromText(
      [_comment(solutionRoot), ...?solutionRoot.properties['GC'], ...?solutionRoot.properties['GN']].join(' '),
    );
  }

  Map<String, Object?> summary() => {
    'problem': {
      for (final MapEntry(:key, :value) in meta.entries)
        if (key != 'tree_index') key: value,
    },
    'start': nodeRef(start),
    'to_play': toPlay,
    'goal': goal,
    'target_group': group != null ? gtp(group) : null,
    'frame': !identical(start, problemRoot),
    'region': regionJson(region),
    'has_reference_solution': solutionRoot.children.isNotEmpty,
    'attempts': attempts,
    'view': regionJson(viewRegion),
  };
}

TsumegoState _ts(CommandHandler h) {
  final ts = h.state.tsumego;
  if (ts == null) {
    throw ApiError('no_tsumego', 'no problem loaded', {'hint': 'katrain-neo tsumego load <file-or-folder>'});
  }
  if (!identical(h.game.root, ts.problemRoot)) {
    h.state.tsumego = null;
    throw ApiError('no_tsumego', 'the problem was replaced by another game');
  }
  return ts;
}

// -- evaluation

List<Move>? _targetChain(GameNode node, (int, int) coords) {
  final g = boardAt(node);
  final cid = g.board[coords.$2][coords.$1];
  return cid < 0 ? null : g.chains[cid];
}

/// Largest chain inside the region that the goal is about.
(int, int)? _defaultGroup(TsumegoState ts, GameNode node) {
  if (ts.goal == null) return null;
  final color = ts.goal == 'live' ? ts.toPlay : Move.opponentPlayer(ts.toPlay);
  final g = boardAt(node);
  final r = ts.region ?? [0, node.boardSize.$1 - 1, 0, node.boardSize.$2 - 1];
  final [xmin, xmax, ymin, ymax] = r;
  final chains = [
    for (final c in g.chains)
      if (c.isNotEmpty &&
          c[0].player == color &&
          c.any((m) => xmin <= m.coords!.$1 && m.coords!.$1 <= xmax && ymin <= m.coords!.$2 && m.coords!.$2 <= ymax))
        c,
  ];
  if (chains.isEmpty) return null;
  var best = chains[0];
  for (final c in chains.skip(1)) {
    if (c.length > best.length) best = c;
  }
  return best[0].coords;
}

Map<String, Object?> _summarise(Map<String, dynamic> result, GameNode node) {
  final root = result['rootInfo'] as Map<String, dynamic>;
  final moves = [for (final m in (result['moveInfos'] as List? ?? const [])) m as Map<String, dynamic>];
  mergeSortBy(moves, (m) => (m['order'] as num?) ?? 99);
  return {
    'black_winrate': root['winrate'],
    'black_score': root['scoreLead'],
    'visits': root['visits'],
    'ownership': result['ownership'],
    'moves': [
      for (final m in moves)
        {
          'move': m['move'],
          'visits': m['visits'],
          'black_winrate': m['winrate'],
          'black_score': m['scoreLead'],
          'pv': m['pv'] ?? const [],
        },
    ],
    'to_move': node.nextPlayer,
  };
}

Future<Map<String, Object?>> _evaluate(
  CommandHandler h,
  TsumegoState ts,
  GameNode node,
  int visits,
  int timeout,
) async {
  final cached = ts.evals[node];
  if (cached != null && (cached['visits'] as num) >= visits * 0.9) return cached;
  final engine = h.engineFor(node);
  final raw = await h.search(
    node,
    engine,
    visits,
    region: ts.region,
    timeout: timeout,
    ownership: true,
    regionRoot: true,
  );
  return ts.evals[node] = _summarise(raw, node);
}

Map<String, Object?>? _groupStatus(TsumegoState ts, GameNode node, Map<String, Object?> ev) {
  final group = ts.group;
  if (group == null) return null;
  final chain = _targetChain(node, group);
  if (chain == null) return {'status': 'captured', 'stones': 0};
  final color = chain[0].player;
  final sign = color == 'B' ? 1 : -1;
  final own = ev['ownership'] as List?;
  if (own == null || own.isEmpty) return {'status': 'unknown', 'stones': chain.length};
  final ownership = [for (final v in own) (v as num).toDouble()];
  final avg = pySum([for (final m in chain) sign * ownershipAt(ownership, m.coords!, node.boardSize)]) / chain.length;
  final status = avg >= alive
      ? 'alive'
      : avg <= dead
      ? 'dead'
      : 'unsettled';
  return {'status': status, 'color': color, 'stones': chain.length, 'ownership': pyRoundValue(avg, 2)};
}

(Object?, Object?) _solverView(TsumegoState ts, Map<String, Object?> ev) {
  final black = ts.toPlay == 'B';
  final bwr = (ev['black_winrate'] as num).toDouble();
  final wr = black ? bwr : 1 - bwr;
  return (pyRoundValue(wr, 4), pyRoundValue((black ? 1 : -1) * (ev['black_score'] as num), 2));
}

bool? _goalMet(TsumegoState ts, Map<String, Object?>? status) {
  if (status == null || ts.goal == null) return null;
  if (ts.goal == 'kill') return status['status'] == 'dead' || status['status'] == 'captured';
  return status['status'] == 'alive';
}

const mistake = (0.10, 3.0); // winrate lost, points lost
const inaccuracy = (0.03, 1.0);

/// best / ok / inaccuracy / mistake. Score counts as much as winrate: when the frame leaves one side far ahead or
/// behind, winrates sit near 0 or 1 and barely move even for losing moves.
String _verdict(bool wasBest, double winrateLost, double scoreLost) {
  if (wasBest) return 'best';
  if (winrateLost >= mistake.$1 || scoreLost >= mistake.$2) return 'mistake';
  if (winrateLost >= inaccuracy.$1 || scoreLost >= inaccuracy.$2) return 'inaccuracy';
  return 'ok';
}

List<Map<String, Object?>> _candidates(TsumegoState ts, Map<String, Object?> ev, [int n = 5]) {
  final black = ev['to_move'] == 'B';
  return [
    for (final m in (ev['moves'] as List).take(n).cast<Map<String, Object?>>())
      {
        'move': m['move'],
        'visits': m['visits'],
        'winrate': pyRoundValue(black ? m['black_winrate'] : 1 - (m['black_winrate'] as num), 4),
        'pv': localPv(m['pv'] as List, ts.region).take(12).toList(),
      },
  ];
}

// -- commands

int _visits(CommandHandler h, ApiArgs a) =>
    apiInt(a, 'visits', defaultValue: ((h.host.config('engine') as Map)['max_visits'] as int?) ?? 500, minimum: 1)!;

Object? _cmdTsumegoList(CommandHandler h, ApiArgs a) {
  final problems = filterProblems(
    scanProblems(pyStr(truthy(a['source']) ? a['source'] : '')),
    a['set'],
    a['difficulty'],
  );
  final limit = apiInt(a, 'limit', defaultValue: 200, minimum: 1)!;
  final sets = <String, int>{}, levels = <String, int>{};
  for (final p in problems) {
    sets[p['set'] as String] = (sets[p['set']] ?? 0) + 1;
    final level = pyStr(p['difficulty']);
    levels[level] = (levels[level] ?? 0) + 1;
  }
  return {
    'total': problems.length,
    'sets': sets,
    'difficulties': levels,
    'problems': [
      for (var i = 0; i < problems.length && i < limit; i++)
        {
          'index': i,
          for (final MapEntry(:key, :value) in problems[i].entries)
            if (key != 'tree_index') key: value,
        },
    ],
  };
}

Object? _cmdTsumegoLoad(CommandHandler h, ApiArgs a) {
  final problems = filterProblems(
    scanProblems(pyStr(truthy(a['source']) ? a['source'] : '')),
    a['set'],
    a['difficulty'],
  );
  final index = apiInt(a, 'index', defaultValue: 0, minimum: 0)!;
  if (index >= problems.length) {
    throw ApiError('not_found', 'problem index $index out of range (${problems.length} problems)');
  }
  final meta = problems[index];
  final text = _read(meta['file'] as String)!;
  final GameNode solutionRoot;
  try {
    solutionRoot = gameParser.parseSgf(problemTexts(text)[meta['tree_index'] as int].$2);
  } on Object catch (e) {
    throw ApiError('sgf_parse_error', '${meta['file']}: $e');
  }
  final toPlay = solutionRoot.initialPlayer;
  final props = <String, Object?>{
    for (final MapEntry(:key, :value) in solutionRoot.properties.entries)
      if (key != 'C') key: List.of(value), // comments often spoil the answer
  };
  props['PL'] = [toPlay];
  final problemRoot = GameNode(properties: props);
  if (problemRoot.placements.isEmpty) throw ApiError('bad_problem', 'problem has no setup stones');
  final backup = loadTree(h, problemRoot);
  final game = h.game;
  final framed = apiBool(a['frame'], !isCenterProblem(game.root));
  if (framed) {
    h.host.tsumegoFrame(apiBool(a['ko']), apiInt(a, 'margin', defaultValue: 4, minimum: 1)!);
  } else {
    // center problems: KaTrain's frame would wall the group in; keep the open board, search locally
    game.setRegionOfInterest(problemViewRegion(game.root));
    game.regionRoot = true;
    final root = game.root;
    root.analyze(game.engines[root.nextPlayer]!, regionOfInterest: game.regionOfInterest, regionRoot: true);
  }
  final start = game.currentNode;
  final ts = TsumegoState(
    {...meta, 'index': index, 'source': a['source']},
    solutionRoot,
    game.root,
    start,
    game.regionOfInterest,
    toPlay,
  );
  h.state.tsumego = ts;
  if (ts.goal != null) ts.group = _defaultGroup(ts, start);
  if (apiBool(a['zoom'], true)) h.host.setZoom(ts.viewRegion, ts.frameCoords);
  h.refresh();
  return {...ts.summary(), 'previous_game_backup': backup};
}

Object? _cmdTsumegoTarget(CommandHandler h, ApiArgs a) {
  final ts = _ts(h);
  final size = ts.start.boardSize;
  if (truthy(a['goal'])) {
    if (a['goal'] != 'kill' && a['goal'] != 'live') throw ApiError('bad_argument', 'goal must be kill or live');
    ts.goal = a['goal'] as String;
  }
  if (truthy(a['region'])) {
    ts.region = parseRegion(a['region'], size);
    h.game.setRegionOfInterest(List.of(ts.region!));
    ts.evals.clear();
  }
  if (truthy(a['group'])) {
    final coords = parseCoords(a['group'], size);
    if (coords == null || _targetChain(ts.start, coords) == null) {
      throw ApiError('bad_argument', 'no stone at ${pyStr(a['group'])} in the starting position');
    }
    ts.group = coords;
  } else if (truthy(a['goal']) && ts.group == null) {
    ts.group = _defaultGroup(ts, ts.start);
  }
  h.refresh(false);
  return ts.summary();
}

Future<Object?> _cmdTsumegoEval(CommandHandler h, ApiArgs a) async {
  final ts = _ts(h);
  final node = h.game.currentNode;
  final ev = await _evaluate(h, ts, node, _visits(h, a), apiInt(a, 'timeout', defaultValue: 300)!);
  final status = _groupStatus(ts, node, ev);
  final (wr, score) = _solverView(ts, ev);
  return {
    'node': nodeRef(node),
    'to_move': node.nextPlayer,
    'solver': ts.toPlay,
    'solver_winrate': wr,
    'solver_score': score,
    'target': status,
    'goal_met': _goalMet(ts, status),
    'best_moves': _candidates(ts, ev),
  };
}

Future<Object?> _cmdTsumegoTry(CommandHandler h, ApiArgs a) async {
  final timeout = apiInt(a, 'timeout', defaultValue: 300)!;
  final ts = _ts(h);
  final cn = h.game.currentNode;
  if (!identical(ts.start, cn) && !cn.nodesFromRoot.any((n) => identical(n, ts.start))) {
    throw ApiError('outside_problem', 'current position is not part of the problem', {'hint': 'tsumego reset'});
  }
  final move = Move(coords: parseCoords(truthy(a['move']) ? a['move'] : '', cn.boardSize), player: cn.nextPlayer);
  checkMovesLegal(cn, [move]);
  final visits = _visits(h, a);
  final before = await _evaluate(h, ts, cn, visits, timeout);
  final node = _play(h, cn, move);
  final after = await _evaluate(h, ts, node, visits, timeout);
  ts.attempts += 1;

  final moverBlack = move.player == 'B';
  final bBefore = (before['black_winrate'] as num).toDouble(), bAfter = (after['black_winrate'] as num).toDouble();
  final wrBefore = moverBlack ? bBefore : 1 - bBefore;
  final wrAfter = moverBlack ? bAfter : 1 - bAfter;
  final beforeMoves = (before['moves'] as List).cast<Map<String, Object?>>();
  final afterMoves = (after['moves'] as List).cast<Map<String, Object?>>();
  final best = beforeMoves.isNotEmpty ? beforeMoves[0] : null;
  final status = _groupStatus(ts, node, after);
  final winrateLost = wrBefore - wrAfter;
  final scoreLost =
      (moverBlack ? 1 : -1) * ((before['black_score'] as num).toDouble() - (after['black_score'] as num).toDouble());
  final wasBest = best != null && best['move'] == move.gtp();
  final result = <String, Object?>{
    'move': '${move.player}:${move.gtp()}',
    'node': nodeRef(node),
    'mover_winrate_before': pyRoundValue(wrBefore, 4),
    'mover_winrate_after': pyRoundValue(wrAfter, 4),
    'winrate_lost': pyRoundValue(winrateLost, 4),
    'score_lost': pyRoundValue(scoreLost, 2),
    'best_move': best?['move'],
    'was_best_move': wasBest,
    'verdict': _verdict(wasBest, winrateLost, scoreLost),
    'target': status,
    'goal_met': move.player == ts.toPlay ? _goalMet(ts, status) : null,
    'better_moves': _candidates(ts, before, 3),
    'refutation_pv': afterMoves.isNotEmpty ? localPv(afterMoves[0]['pv'] as List, ts.region).take(12).toList() : [],
  };
  if (apiBool(a['reply'], true) && afterMoves.isNotEmpty) {
    final reply = Move.fromGtp(afterMoves[0]['move'] as String, player: node.nextPlayer);
    if (!reply.isPass) {
      final replyNode = _play(h, node, reply, analyze: true);
      result['reply'] = {'move': '${reply.player}:${reply.gtp()}', 'node': nodeRef(replyNode)};
    } else {
      result['reply'] = {'move': '${reply.player}:pass', 'node': null};
    }
  }
  return result;
}

GameNode _play(CommandHandler h, GameNode parent, Move move, {bool analyze = false}) {
  final (nodes, _) = h.addNodes(parent, [move], analyze: 'none');
  final node = nodes[0];
  if (analyze) {
    final ts = h.state.tsumego;
    node.analyze(h.game.engines[node.nextPlayer]!, regionOfInterest: ts?.region, regionRoot: ts != null);
  }
  h.goto(node);
  return node;
}

Object? _cmdTsumegoReset(CommandHandler h, ApiArgs a) {
  final ts = _ts(h);
  for (final child in List.of(ts.start.children)) {
    if (child.nodesInTree.every(h.state.created.contains)) ts.start.children.removeWhere((c) => identical(c, child));
  }
  h.goto(ts.start);
  ts.evals = Map.identity()
    ..addAll({
      for (final e in ts.evals.entries)
        if (identical(e.key, ts.start)) e.key: e.value,
    });
  ts.attempts = 0;
  h.state.marks = [];
  return ts.summary();
}

Future<Object?> _cmdTsumegoSolution(CommandHandler h, ApiArgs a) async {
  final ts = _ts(h);
  final lines = <Map<String, Object?>>[];
  for (final child in ts.solutionRoot.children) {
    final nodes = [child, ..._firstLine(child)];
    lines.add({
      'moves': [
        for (final n in nodes)
          if (n.move != null) '${n.move!.player}:${n.move!.gtp()}',
      ],
      'label': _lineLabel(child),
    });
  }
  final ev = await _evaluate(h, ts, ts.start, _visits(h, a), apiInt(a, 'timeout', defaultValue: 300)!);
  final evMoves = (ev['moves'] as List).cast<Map<String, Object?>>();
  final katagoLine = evMoves.isNotEmpty ? localPv(evMoves[0]['pv'] as List, ts.region).take(16).toList() : <String>[];
  final out = <String, Object?>{'reference_lines': lines, 'katago_line': katagoLine, 'start': nodeRef(ts.start)};
  if (apiBool(a['show'])) {
    Map<String, Object?>? preferred;
    for (final ln in lines) {
      if (ln['label'] == 'correct') {
        preferred = ln;
        break;
      }
    }
    preferred ??= lines.isNotEmpty ? lines[0] : null;
    final moves = preferred != null
        ? [for (final m in preferred['moves'] as List<String>) m.split(':')[1]]
        : katagoLine;
    try {
      h.goto(ts.start);
      final parsed = parseMoves(moves, ts.start.boardSize, ts.start.nextPlayer);
      out['shown'] = showPv(h, ts.start, parsed);
    } on ApiError catch (e) {
      out['show_error'] = e.toJson();
    }
  }
  return out;
}

Object? _cmdTsumegoStatus(CommandHandler h, ApiArgs a) {
  if (h.state.tsumego == null) return {'active': false};
  return {'active': true, ..._ts(h).summary(), 'current': nodeRef(h.game.currentNode)};
}

final Map<String, ApiCommand> tsumegoCommands = {
  'tsumego.list': const ApiCommand(
    _cmdTsumegoList,
    'List problems in an SGF file/folder, optionally filtered by set and difficulty.',
    waitsForEngine: true,
  ),
  'tsumego.load': const ApiCommand(
    _cmdTsumegoLoad,
    "Load problem #index (after filters), hide its answer tree, add KaTrain's tsumego frame and local region.",
  ),
  'tsumego.target': const ApiCommand(
    _cmdTsumegoTarget,
    'Set goal (kill/live, for the player to move), target group stone and local search region.',
  ),
  'tsumego.eval': const ApiCommand(
    _cmdTsumegoEval,
    'Local KataGo evaluation of the current problem position: target status and best local moves.',
    waitsForEngine: true,
  ),
  'tsumego.try': const ApiCommand(
    _cmdTsumegoTry,
    'Play a move in the problem; KataGo evaluates it and (reply=true) answers with its best local move.',
    waitsForEngine: true,
  ),
  'tsumego.reset': const ApiCommand(_cmdTsumegoReset, 'Back to the starting position; attempt moves are removed.'),
  'tsumego.solution': const ApiCommand(
    _cmdTsumegoSolution,
    "Reference answer lines from the SGF (labelled correct/wrong when marked) plus KataGo's local line.",
    waitsForEngine: true,
  ),
  'tsumego.status': const ApiCommand(_cmdTsumegoStatus, 'Current problem, goal, target and attempts.'),
};
