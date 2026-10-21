// Life-and-death problem mode, built on the tsumego frame and region-of-interest search.
//
// Only problems that come with an answer are practised. The SGF's answer tree is kept aside, never shown unless
// asked for: while the solver's moves follow it, the opponent answers from it, and it says when the problem is
// solved or failed. Once the moves leave it, KataGo answers inside the problem region.

import 'package:collection/collection.dart';

import 'dart:convert';
import 'dart:io';

import '../constants.dart';
import '../engine/io/local_katago.dart' show expandUser;
import '../game/game_node.dart';
import '../game/tsumego_frame.dart' show nearToEdge;
import '../sgf/codecs/decode.dart';
import '../sgf/move.dart';
import '../utils/format.dart';
import 'args.dart';
import 'commands.dart';
import 'model.dart';
import 'overlay.dart';
import 'protocol.dart';
import 'state.dart';

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

/// Whether [text] has a stone played (not only setup stones, nor only passes).
bool _hasMove(String text) => RegExp(r'(?<![A-Za-z\\])[BW]\[[a-zA-Z]{2}\]').hasMatch(text);

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

/// A problem found in a file: the file, which game tree in it, and what its name and comments say; and what the
/// problem set's `index.json` says of it, when the set has one.
class TsumegoProblem {
  final String file;
  final int treeIndex;
  final String set;
  final String name;
  final String? difficulty;
  final String? toPlay;

  /// From the set's index: the title, the level (its scale, e.g. 3 for about 10 kyu) and the kind of problem.
  final String? title;
  final int? level;
  final String? category;

  /// Whether the SGF has an answer (any move after the setup); only such problems are practised.
  final bool hasAnswer;
  const TsumegoProblem({
    required this.file,
    required this.treeIndex,
    required this.set,
    required this.name,
    this.difficulty,
    this.toPlay,
    this.title,
    this.level,
    this.category,
    this.hasAnswer = true,
  });

  /// `live` or `kill` when the index's category says so.
  String? get goal => switch (category) {
    'living' => 'live',
    'killing' => 'kill',
    _ => null,
  };

  TsumegoProblem _withIndex(Map<String, Object?>? entry) => entry == null
      ? this
      : TsumegoProblem(
          file: file,
          treeIndex: treeIndex,
          set: set,
          name: name,
          difficulty: difficulty,
          toPlay: (entry['toPlay'] as String?) ?? toPlay,
          title: entry['title'] as String?,
          level: (entry['level'] as num?)?.toInt(),
          category: entry['category'] as String?,
          hasAnswer: hasAnswer,
        );

  Map<String, Object?> toJson() => {
    'file': file,
    'set': set,
    'name': name,
    'difficulty': difficulty,
    'to_play': toPlay,
    if (title != null) 'title': title,
    if (level != null) 'level': level,
    if (category != null) 'category': category,
    'has_answer': hasAnswer,
  };
}

/// The problem set index next to [dir] or above it (`index.json` with `collections` and `problems`, as frank_go
/// writes them), as entries by `file#tree`; and the index's level scale. Empty when there is none.
(Map<String, Map<String, Object?>>, String?) _readIndex(String dir) {
  final file = _indexFile(dir);
  if (file == null) return (const {}, null);
  final stamp = _stamp(file);
  final cached = _indexes[file.path];
  if (cached != null && cached.stamp == stamp) return cached.index;
  final index = _parseIndex(file);
  _indexes[file.path] = (stamp: stamp, index: index);
  return index;
}

/// The `index.json` in [dir] or the nearest folder above it.
File? _indexFile(String dir) {
  for (var d = Directory(dir); ; d = d.parent) {
    final file = File('${d.path}${Platform.pathSeparator}index.json');
    if (file.existsSync()) return file;
    if (d.parent.path == d.path) return null;
  }
}

/// When and how big [file] is: a file whose stamp is unchanged need not be read again.
String _stamp(File file) {
  final stat = file.statSync();
  return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
}

/// Parsed indexes and scanned sources, kept while their files are unchanged: a practice goes through one set
/// problem after problem, and an index can be megabytes.
final _indexes = <String, ({String stamp, (Map<String, Map<String, Object?>>, String?) index})>{};
final _scans = <String, ({String stamp, List<TsumegoProblem> problems})>{};

(Map<String, Map<String, Object?>>, String?) _parseIndex(File file) {
  final sep = Platform.pathSeparator;
  final d = file.parent;
  final Object? json;
  try {
    json = jsonDecode(file.readAsStringSync());
  } on FormatException {
    return (const {}, null);
  }
  if (json is! Map || json['collections'] is! Map || json['problems'] is! List) return (const {}, null);
  final collections = (json['collections'] as Map).cast<String, Object?>();
  final byKey = <String, Map<String, Object?>>{};
  final folders = <String, List<String>>{};
  for (final entry in (json['problems'] as List).whereType<Map>()) {
    final e = entry.cast<String, Object?>();
    final where = (collections[e['collection']] as Map?)?['file'] as String?;
    final n = (e['n'] as num?)?.toInt();
    if (where == null || n == null || n < 1) continue;
    final path = '${d.path}$sep${where.replaceAll('/', sep)}';
    if (where.toLowerCase().endsWith('.sgf')) {
      byKey['${File(path).absolute.path}#${n - 1}'] = e; // the n-th tree of a collection file
    } else {
      // the n-th file of a folder of problems
      final files = folders.putIfAbsent(path, () {
        final dir = Directory(path);
        if (!dir.existsSync()) return const [];
        final found = [
          for (final f in dir.listSync())
            if (f is File && f.path.toLowerCase().endsWith('.sgf')) f.absolute.path,
        ];
        stableSortBy(found, (f) => _SortKey(_naturalKey(f)));
        return found;
      });
      if (n <= files.length) byKey['${files[n - 1]}#0'] = e;
    }
  }
  return (byKey, json['levelScale'] as String?);
}

/// All problems in a file or folder (in a stable order); read again only when a file in it or its index changed.
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
  final indexDir = Directory(src).existsSync() ? src : base;
  final indexFile = _indexFile(indexDir);
  final stamp = [for (final f in files) '$f=${_stamp(File(f))}', if (indexFile != null) _stamp(indexFile)].join('|');
  final cached = _scans[src];
  if (cached != null && cached.stamp == stamp) return cached.problems;
  final (index, _) = _readIndex(indexDir);
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
          hasAnswer: _hasMove(tree),
        )._withIndex(index['${File(path).absolute.path}#$j']),
      );
    }
  }
  final scanned = List<TsumegoProblem>.unmodifiable(problems);
  _scans[src] = (stamp: stamp, problems: scanned);
  return scanned;
}

class _SortKey implements Comparable<_SortKey> {
  final List<(int, int, String)> key;
  _SortKey(this.key);
  @override
  int compareTo(_SortKey other) => _compareKeys(key, other.key);
}

/// The problems in [set] (a part of the set or name), of [difficulty], and with a [level] in `lo-hi` (or one level),
/// as the set's index gives it; with [answered], only those that come with an answer.
List<TsumegoProblem> filterProblems(
  List<TsumegoProblem> problems, {
  String? set,
  String? difficulty,
  (int, int)? level,
  bool answered = false,
}) => [
  for (final p in problems)
    if ((set == null || '${p.set}/${p.name}'.toLowerCase().contains(set.toLowerCase())) &&
        (difficulty == null || p.difficulty?.toLowerCase() == difficulty.toLowerCase()) &&
        (level == null || (p.level != null && p.level! >= level.$1 && p.level! <= level.$2)) &&
        (!answered || p.hasAnswer))
      p,
];

/// A level filter, `3` or `2-4`.
(int, int)? parseLevel(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  final m = RegExp(r'^\s*(\d+)\s*(?:-\s*(\d+))?\s*$').firstMatch(text);
  if (m == null) throw ApiError('bad_argument', 'level must be a number or a range like 2-4, not $text');
  final lo = int.parse(m[1]!);
  return (lo, m[2] == null ? lo : int.parse(m[2]!));
}

String? _goalFromText(String? text) {
  final t = (text ?? '').toLowerCase();
  if (const ['kill', '杀', '净死'].any(t.contains)) return 'kill';
  if (const ['live', '活', 'make life'].any(t.contains)) return 'live';
  return null;
}

/// Loading moves SGF C[] comments into the note, so read both.
String _comment(GameNode node) => [node.note, ...?node.properties['C']].join(' ');

final _wrongWords = RegExp(r'\b(wrong|incorrect|failure)\b|失败|错误');
final _correctWords = RegExp(r'\b(right|correct)\b|正解|正确');

/// RIGHT/WRONG mark of one answer node, from common SGF conventions: its comment, or a TE/BM property.
String? _nodeLabel(GameNode n) {
  final text = _comment(n).toLowerCase();
  if (n.properties.containsKey('BM') || _wrongWords.hasMatch(text)) return 'wrong';
  if (n.properties.containsKey('TE') || _correctWords.hasMatch(text)) return 'correct';
  return null;
}

/// RIGHT/WRONG label of a solution line: the first mark along its first variation.
String? _lineLabel(GameNode node) {
  for (final n in [node, ..._firstLine(node)]) {
    final label = _nodeLabel(n);
    if (label != null) return label;
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

// -- following the answer

/// How the solver stands against the problem's answer: where the position shown is in the answer tree (null once
/// the moves left it; KataGo answers then), and whether the answer says the problem is solved or failed there.
class TsumegoProgress {
  final GameNode? book;

  /// `solved`, `failed`, or null while the problem goes on.
  final String? result;

  /// The answer's comment where the line ended.
  final String? comment;
  const TsumegoProgress(this.book, [this.result, this.comment]);
  static const offBook = TsumegoProgress(null);

  Map<String, Object?> toJson() => {'on_book': book != null, 'result': result, 'comment': ?comment};
}

/// Follows the moves from the problem's start to [node] through the answer tree: a node marked correct solves the
/// problem; a line ending anywhere else, after the answer's refutation, fails it.
TsumegoProgress tsumegoProgress(TsumegoState ts, GameNode node) {
  final path = node.nodesFromRoot;
  final from = path.indexWhere((n) => identical(n, ts.start));
  if (from < 0) return TsumegoProgress.offBook;
  var book = ts.solutionRoot;
  for (final n in path.skip(from + 1)) {
    final next = book.children.firstWhereOrNull((c) => c.move != null && c.move == n.move);
    if (next == null) return TsumegoProgress.offBook;
    book = next;
  }
  if (identical(book, ts.solutionRoot)) return TsumegoProgress(book);
  final text = _comment(book).trim();
  final comment = text.isEmpty ? null : text;
  if (ts._isCorrect(book)) return TsumegoProgress(book, 'solved', comment);
  if (book.children.isEmpty) return TsumegoProgress(book, 'failed', comment);
  return TsumegoProgress(book);
}

/// The answer's next move for the solver at [node]: the first of the answer's moves there that leads on to a correct
/// end. Null when the opponent is to move, off the answer, once the problem is over, or when every answer line from
/// here is wrong.
Move? answerHint(TsumegoState ts, GameNode node) {
  if (node.nextPlayer != ts.toPlay) return null;
  final progress = tsumegoProgress(ts, node);
  if (progress.result != null) return null;
  return progress.book?.children
      .firstWhereOrNull((c) => c.move?.player == ts.toPlay && c.nodesInTree.any(ts._isCorrect))
      ?.move;
}

/// The answer's move for the opponent to move at [node], from the answer tree's main line; null when the solver is
/// to move, off the tree, or once the problem is over.
Move? bookReply(TsumegoState ts, GameNode node) {
  if (node.nextPlayer == ts.toPlay) return null;
  final progress = tsumegoProgress(ts, node);
  if (progress.result != null) return null;
  return progress.book?.children.map((c) => c.move).firstWhereOrNull((m) => m?.player == node.nextPlayer);
}

const viewMargin = 2; // lines of empty board shown around the problem stones
const viewMinSpan = 7;

/// Rectangle around the problem's own stones (not the frame) for the zoomed diagram view.
List<int> problemViewRegion(GameNode problemRoot) => viewRegion([
  for (final m in problemRoot.placements)
    if (m.coords != null) m.coords!,
], problemRoot.boardSize);

/// `[xmin, xmax, ymin, ymax]` to show for a problem with stones at [coords]: their bounding box plus a margin,
/// widened towards the board's center to at least [viewMinSpan] lines.
List<int> viewRegion(List<(int, int)> coords, (int, int) boardSize) {
  final (szx, szy) = boardSize;
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

/// No problem stone near any edge (the same 'near' as the tsumego frame).
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

  /// The problem's place in [source]'s problems at [level] (the filter it was loaded with), for going on.
  final int index;
  final String? source;
  String? level;
  final GameNode solutionRoot; // the whole SGF tree with its answer branches (hidden)
  final GameNode problemRoot;
  final GameNode start;
  List<int>? region;
  final String toPlay;
  String? goal;
  (int, int)? group; // a stone of the target group
  final Map<GameNode, _Evaluation> _evals = Map.identity();
  int attempts = 0;

  /// The hints given since the problem's start, and the marks showing the last one.
  int hints = 0;
  List<int> _hintMarks = const [];

  /// The frame node (child of the problem root) holds only the frame's stones.
  final Set<(int, int)> frameCoords;
  final List<int> viewRegion;

  /// Whether the answer marks its correct lines; when it marks none, the end of its main line is the answer.
  late final bool _marked = solutionRoot.nodesInTree.any((n) => _nodeLabel(n) == 'correct');
  late final GameNode _mainLineEnd = [solutionRoot, ..._firstLine(solutionRoot)].last;
  bool _isCorrect(GameNode n) => _marked ? _nodeLabel(n) == 'correct' : identical(n, _mainLineEnd);

  TsumegoState(this.problem, this.index, this.source, this.solutionRoot, this.problemRoot, this.start, this.region)
    : toPlay = problemRoot.initialPlayer,
      frameCoords = identical(start, problemRoot) ? {} : {for (final m in start.placements) m.coords!},
      viewRegion = problemViewRegion(problemRoot),
      goal =
          problem.goal ??
          _goalFromText(
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
    'hints': hints,
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
  level: parseLevel(a.text('level')),
  answered: a.flag('answered', orElse: true), // a problem without an answer cannot be judged
);

Object? _list(CommandHandler h, ApiArgs a) {
  final problems = _problems(a);
  final sets = <String, int>{}, difficulties = <String, int>{}, levels = <String, int>{};
  for (final p in problems) {
    sets[p.set] = (sets[p.set] ?? 0) + 1;
    final difficulty = p.difficulty ?? 'unknown';
    difficulties[difficulty] = (difficulties[difficulty] ?? 0) + 1;
    if (p.level != null) levels['${p.level}'] = (levels['${p.level}'] ?? 0) + 1;
  }
  final source = absPath(a.text('source', orElse: '')!);
  return {
    'total': problems.length,
    'sets': sets,
    'difficulties': difficulties,
    if (levels.isNotEmpty) 'levels': levels,
    'level_scale': ?_readIndex(Directory(source).existsSync() ? source : File(source).parent.path).$2,
    'problems': [
      for (final (i, p) in problems.take(a.integer('limit', orElse: 200, min: 1)!).indexed) {'index': i, ...p.toJson()},
    ],
  };
}

/// The display toggles that would show the answer: hints, policy, territory, evaluation dots, next moves.
const spoilers = ['hints', 'policy', 'ownership', 'eval', 'show_children'];

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
  // The problem without its answer tree and comments (they often give the answer away), under Tromp-Taylor
  // rules: dead stones count until they are captured, so after a wrong move KataGo plays the kill out instead of
  // passing over a group it already sees as dead, and the solver sees why the move failed.
  final problemRoot = GameNode(
    properties: {
      for (final MapEntry(:key, :value) in solutionRoot.properties.entries)
        if (key != 'C') key: List.of(value),
      'PL': [solutionRoot.initialPlayer],
      'RU': ['tromp-taylor'],
    },
  );
  if (problemRoot.placements.isEmpty) throw ApiError('bad_problem', 'problem has no setup stones');
  final backup = loadTree(h, problemRoot);
  final game = h.game;
  if (a.flag('frame', orElse: !isCenterProblem(game.root))) {
    h.host.tsumegoFrame(a.flag('ko'), a.integer('margin', orElse: 4, min: 1)!);
  } else {
    // center problems: a frame would wall the group in; keep the open board, search locally
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
  h.state.tsumego = ts..level = a.text('level');
  ts.group = _defaultGroup(ts, ts.start);
  // The solver plays the side to move, against KataGo at full strength, which answers inside the problem's region;
  // in play mode, without the engine's answer on the board. This comes last: loading a game and framing it change
  // the mode, and a mode brings back its own toggles.
  final solver = ts.start.nextPlayer;
  h.host.setPlayer(solver, playerHuman, playingNormal);
  h.host.setPlayer(solver == 'B' ? 'W' : 'B', playerAi, aiDefault);
  h.host.selectMode(modePlay);
  for (final key in spoilers) {
    h.host.setAnalysisControl(key, false);
  }
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
  ts.hints = 0;
  h.state.marks = [];
  return ts.summary();
}

/// A hint for the solver's move: [level] 1 marks a 4x4 area holding it, 2 the point. The move is the answer's while
/// the moves follow it, otherwise KataGo's best local move. The mark is on this position only, so the next move
/// takes it away.
Future<Object?> _hint(CommandHandler h, ApiArgs a) async {
  final ts = _ts(h);
  final node = h.game.currentNode;
  if (node.nextPlayer != ts.toPlay) throw ApiError('not_your_move', 'the opponent is to move');
  final level = a.integer('level', orElse: 2, min: 1)!;
  if (level > 2) throw ApiError('bad_argument', 'level must be 1 (an area) or 2 (the point)');
  var move = answerHint(ts, node);
  var source = 'answer';
  if (move == null) {
    final ev = await _evaluate(h, ts, node, _visits(h, a), a.integer('timeout', orElse: 300, min: 1)!);
    final best = ev.moves.firstOrNull?.move;
    if (best == null) throw ApiError('no_hint', 'KataGo has no move here');
    move = Move.fromGtp(best, player: ts.toPlay);
    source = 'katago';
  }
  ts.hints += 1;
  final c = move.coords;
  final out = <String, Object?>{'level': level, 'source': source, 'hints': ts.hints};
  if (c == null) return {...out, 'move': 'pass'}; // nothing to mark
  final scope = nodeId(node);
  final mark = level == 1
      ? Mark(
          id: h.state.nextMarkId(),
          type: 'area',
          region: _hintArea(c, node.boardSize),
          rgb: parseMarkColor('yellow')!,
          color: 'yellow',
          nodeId: scope,
        )
      : Mark(
          id: h.state.nextMarkId(),
          type: 'circle',
          point: c,
          rgb: parseMarkColor('green')!,
          color: 'green',
          nodeId: scope,
        );
  final old = ts._hintMarks.toSet();
  h.state.marks = [
    for (final m in h.state.marks)
      if (!old.contains(m.id)) m,
    mark,
  ];
  ts._hintMarks = [mark.id];
  h.host.redrawOverlay();
  return {...out, if (level == 2) 'move': gtp(c), if (level == 1) 'area': regionJson(mark.region)};
}

/// A 4x4 area on the board holding [c], with [c] placed in it by where it is (so the area does not give it away).
List<int> _hintArea((int, int) c, (int, int) boardSize) {
  const side = 4;
  int start(int v, int offset, int size) => (v - offset).clamp(0, size - side);
  final (x, y) = c;
  final xmin = start(x, (x * 3 + y) % side, boardSize.$1);
  final ymin = start(y, (x + y * 3) % side, boardSize.$2);
  return [xmin, xmin + side - 1, ymin, ymin + side - 1];
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
    : {
        'active': true,
        ..._ts(h).summary(),
        'current': nodeRef(h.game.currentNode),
        'progress': tsumegoProgress(_ts(h), h.game.currentNode).toJson(),
      };

final Map<String, ApiCommand> tsumegoCommands = {
  'tsumego.list': const ApiCommand(
    _list,
    'List problems in an SGF file/folder, optionally filtered by set and difficulty.',
    waitsForEngine: true,
  ),
  'tsumego.load': const ApiCommand(
    _load,
    "Load problem #index (after filters), hide its answer tree, add a tsumego frame and local region.",
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
  'tsumego.hint': const ApiCommand(
    _hint,
    "A hint for the solver's move (level=1 an area, 2 the point): the answer's, or KataGo's best local move.",
    waitsForEngine: true,
  ),
  'tsumego.solution': const ApiCommand(
    _solution,
    "Reference answer lines from the SGF (labelled correct/wrong when marked) plus KataGo's local line.",
    waitsForEngine: true,
  ),
  'tsumego.status': const ApiCommand(_status, 'Current problem, goal, target and attempts.'),
};
