// Differential tests: GameNode analysis merging, candidate moves, comments, SGF writing and KT data must match
// KaTrain (fixtures from tools/fixtures/game_node_fixtures.py).

import 'dart:convert';

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'fixtures_util.dart';

Iterable<GameNode> preorder(GameNode root) sync* {
  final stack = [root];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    yield node;
    stack.addAll(node.children.reversed);
  }
}

Object? asJson(Object? value) => jsonDecode(jsonEncode(value));

void main() {
  final data = loadFixture('game_node.json');
  late GameNode root;
  late List<GameNode> nodes;

  setUpAll(() {
    i18n.switchLang('en');
    root = gameParser.parseSgf(data['tree_sgf'] as String);
    nodes = preorder(root).toList();
    for (final call in (data['calls'] as List).cast<Map<String, dynamic>>()) {
      final node = nodes[call['node'] as int];
      final refine = call['refine_move'] == null
          ? null
          : Move.fromGtp(call['refine_move'] as String, player: call['refine_player'] as String);
      final json = asJson(call['json']) as Map<String, dynamic>;
      node.setAnalysis(
        json,
        refine,
        call['additional'] as bool,
        (call['region'] as List?)?.cast<int>(),
        call['partial'] as bool,
      );
    }
    for (final extra in (data['extras'] as List).cast<Map<String, dynamic>>()) {
      final node = nodes[extra['node'] as int];
      node.autoUndo = extra['auto_undo'] as bool?;
      node.aiThoughts = extra['ai_thoughts'] as String;
      node.note = extra['note'] as String;
    }
  });

  tearDownAll(() => i18n.switchLang(defaultLanguage));

  test('tree', () {
    expect(nodes.length, (data['nodes'] as List).length);
    // a fresh parse, before analyses and notes were added: KaTrain wrote this SGF from the same tree
    expect(gameParser.parseSgf(data['tree_sgf'] as String).sgf(), data['tree_sgf']);
  });

  test('analysis, candidate moves and evaluations per node', () {
    final expected = (data['nodes'] as List).cast<Map<String, dynamic>>();
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      final e = expected[i];
      final reason = 'node $i';
      expect(asJson(node.analysis), e['analysis'], reason: '$reason analysis');
      expect(asJson(node.candidateMoves), e['candidate_moves'], reason: '$reason candidate moves');
      expect(node.pointsLost, e['points_lost'], reason: '$reason points lost');
      expect(node.parentRealizedPointsLost, e['parent_realized_points_lost'], reason: reason);
      final ranking = node.policyRanking ?? [];
      expect(
        [
          for (final (p, m) in ranking.take(15)) [p, m.gtp()],
        ],
        e['policy_ranking'],
        reason: '$reason policy',
      );
      final (rank, probability, _) = node.movePolicyStats();
      expect([rank, probability], e['move_policy_stats'], reason: '$reason policy stats');
      expect(node.formatScore(), e['format_score'], reason: reason);
      expect(node.formatWinrate(), e['format_winrate'], reason: reason);
      expect([for (final c in node.orderedChildren) nodes.indexOf(c)], e['ordered_children'], reason: reason);
    }
  });

  test('comments in English and Chinese', () {
    final expected = (data['nodes'] as List).cast<Map<String, dynamic>>();
    try {
      for (final lang in ['en', 'cn']) {
        i18n.switchLang(lang);
        for (var i = 0; i < nodes.length; i++) {
          final node = nodes[i];
          final e = (expected[i]['comments'] as Map<String, dynamic>)[lang] as Map<String, dynamic>;
          final reason = '$lang node $i';
          expect(node.comment(), e['default'], reason: '$reason default');
          expect(node.comment(sgf: true, interactive: false), e['sgf'], reason: '$reason sgf');
          expect(node.comment(details: true), e['details'], reason: '$reason details');
          expect(node.comment(teach: true), e['teach'], reason: '$reason teach');
        }
      }
    } finally {
      i18n.switchLang('en');
    }
  });

  test('SGF written with KaTrain\'s save options', () {
    const thresholds = [12, 6, 3, 1.5, 0.5, 0];
    final options = {
      'default': const SgfSaveOptions(),
      'comments': SgfSaveOptions(
        saveCommentsPlayer: {'B': true, 'W': true},
        saveCommentsClass: List.filled(6, true),
        evalThresholds: thresholds,
      ),
      'comments_some': const SgfSaveOptions(
        saveCommentsPlayer: {'B': true, 'W': false},
        saveCommentsClass: [true, true, false, false, false, false],
        evalThresholds: thresholds,
      ),
      'marks': SgfSaveOptions(
        saveCommentsPlayer: {'B': true, 'W': true},
        saveCommentsClass: List.filled(6, true),
        evalThresholds: thresholds,
        saveMarks: true,
      ),
    };
    final expected = data['sgf'] as Map<String, dynamic>;
    for (final MapEntry(key: name, value: o) in options.entries) {
      expect(root.sgf(o), expected[name], reason: name);
    }
  });

  test('KT analysis data: reads KaTrain\'s, and reads back its own', () {
    for (final kt in (data['kt'] as List).cast<Map<String, dynamic>>()) {
      final probe = GameNode(properties: {'SZ': 9});
      probe.analysisFromSgf = (kt['values'] as List).cast<String>();
      expect(probe.loadAnalysis(), isTrue);
      expect(asJson(probe.analysis), kt['loaded'], reason: 'node ${kt['node']} from KaTrain');

      final again = GameNode(properties: {'SZ': 9});
      again.analysisFromSgf = analysisDumps(nodes[kt['node'] as int].analysis);
      expect(again.loadAnalysis(), isTrue);
      expect(asJson(again.analysis), kt['loaded'], reason: 'node ${kt['node']} round trip');
    }
  });

  test('notes and KT are read from SGF, generated comments are dropped', () {
    final parsed = gameParser.parseSgf(
      '(;SZ[9]KT[a][b][c];B[cc]C[my note${sgfSeparatorMarker}generated$sgfInternalCommentsMarker])',
    );
    expect(parsed.analysisFromSgf, ['a', 'b', 'c']);
    expect(parsed.properties.containsKey('KT'), isFalse);
    expect(parsed.children[0].note, 'my note');
    expect(parsed.children[0].properties.containsKey('C'), isFalse);
  });

  test('shortcuts are written with matching ids', () {
    final r = gameParser.parseSgf('(;SZ[9];B[aa];W[bb];B[cc];W[dd])');
    final from = r.children[0];
    final to = from.children[0].children[0].children[0];
    from.addShortcut(to);
    final sgf = r.sgf();
    final sid = RegExp(r'KTSID\[(\d+)\]').firstMatch(sgf)![1];
    final sf = RegExp(r'KTSF\[(\d+)\]').firstMatch(sgf)![1];
    expect(sid, sf);
    to.removeShortcut();
    expect(r.sgf().contains('KTSF'), isFalse);
  });
}
