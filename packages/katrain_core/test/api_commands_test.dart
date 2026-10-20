// What the API's commands do, as agents see it: their JSON results and errors, on a game with an engine that
// answers at once.

import 'dart:convert';
import 'dart:io';

import 'package:katrain_core/api.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'support/api_host.dart';
import 'support/fake_engine.dart';

const game =
    '(;GM[1]FF[4]SZ[19]KM[6.5]PB[Shin]PW[Iyama];B[pd]C[first];W[dp];B[pq];W[dd];B[fq]'
    '(;W[cn];B[jp];W[qf])(;W[hq];B[cq]))';

void main() {
  late Directory tmp;
  late TestHost host;
  late CommandHandler api;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('katrain_neo_api');
    (host, api) = apiSetup(tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// The result as JSON (what the server sends).
  Future<dynamic> run(String command, [Map<String, Object?> args = const {}]) async =>
      jsonDecode(jsonEncode(await api.dispatch(command, Map.of(args))));

  Future<ApiError> fails(String command, [Map<String, Object?> args = const {}]) async {
    try {
      await api.dispatch(command, Map.of(args));
    } on ApiError catch (e) {
      return e;
    }
    fail('$command $args did not fail');
  }

  Future<void> load([String sgf = game]) async {
    await run('sgf.import', {'content': sgf});
    await Future<void>.delayed(Duration.zero); // the game's first analysis
  }

  group('arguments', () {
    test('flags take true/1/yes/on, values any non-empty text', () async {
      await load();
      expect((await run('history', {'future': 'yes'}))['nodes'], hasLength(9));
      expect((await run('history', {'future': 'no'}))['nodes'], hasLength(1));
      final exported = await run('sgf.export', {'path': '${tmp.path}/a.sgf'});
      expect(exported['path'], endsWith('a.sgf'));
      expect(File('${tmp.path}/a.sgf').existsSync(), isTrue);
    });

    test('integers are checked', () async {
      expect((await fails('nav.next', {'n': 'two'})).code, 'bad_argument');
      expect((await fails('nav.next', {'n': 0})).message, 'n must be at least 1');
      await load();
      expect((await run('nav.next', {'n': '2'}))['current']['move_number'], 2);
    });
  });

  group('reading', () {
    test('status', () async {
      await load();
      final status = await run('status');
      expect(status['game']['players']['B']['name'], 'Shin');
      expect(status['game']['main_line_moves'], 8);
      expect(status['game']['nodes'], 11);
      expect(status['current']['move_number'], 0);
      expect(status['mode'], modeAnalyze);
      expect(status['engine']['alive'], isTrue);
    });

    test('node references', () async {
      await load();
      expect((await run('node', {'node': '3'}))['move'], {'player': 'B', 'move': 'Q3'});
      expect((await run('node', {'node': 'main:8'}))['move']['move'], 'R14');
      expect((await run('node', {'node': 'end'}))['move_number'], 8);
      final id = (await run('node', {'node': '2'}))['id'];
      expect((await run('node', {'node': id}))['move_number'], 2);
      expect((await run('node', {'node': '#${(id as String).substring(1)}'}))['move_number'], 2);
      expect((await fails('node', {'node': 'abc'})).code, 'bad_node_ref');
      expect((await fails('node', {'node': '99'})).message, 'move 99 not on the current line (it has 8 moves)');
      expect((await fails('node', {'node': 'n9999'})).code, 'node_not_found');
    });

    test('node details', () async {
      await load();
      final node = await run('node', {'node': '1'});
      expect(node['note'], 'first');
      expect(node['on_main_line'], isTrue);
      expect(node['properties']['B'], ['pd']);
      expect((node['child_ids'] as List), hasLength(1));
    });

    test('board', () async {
      await load();
      final board = await run('board', {'node': '2'});
      expect(board['black_stones'], ['Q16']);
      expect(board['white_stones'], ['D4']);
      expect(board['last_move'], 'D4');
      expect(board['rows'][0], '...................');
      final ascii = (board['ascii'] as String).split('\n');
      expect(ascii[0], '    A B C D E F G H J K L M N O P Q R S T');
      expect(ascii[4], ' 16 . . . . . . . . . . . . . . . X . . .');
      expect(ascii[16], '  4 . . . o . . . . . . . . . . . . . . .'); // last move lowercase
      expect((await run('board', {'ascii': 'off'})).containsKey('ascii'), isFalse);
    });

    test('history, tree and variations', () async {
      await load();
      await run('nav.goto', {'node': '5'});
      final history = await run('history');
      expect((history['nodes'] as List).last['current'], isTrue);
      expect((history['nodes'] as List).last['variations'], 2);
      final tree = await run('tree');
      expect(tree['tree']['moves'], ['-', 'B:Q16', 'W:D4', 'B:Q3', 'W:D16', 'B:F3']);
      expect(
        [for (final v in tree['tree']['variations']) v['moves']],
        [
          ['W:C6', 'B:K4', 'W:R14'],
          ['W:H3', 'B:C3'],
        ],
      );
      expect((await run('tree', {'max_depth': 3}))['tree']['truncated'], isTrue);
      final variations = await run('variations');
      expect(
        [for (final c in variations['children']) c['moves']],
        [
          ['C6', 'K4', 'R14'],
          ['H3', 'C3'],
        ],
      );
      expect((await run('variations', {'max_len': 1}))['children'][0]['moves'], ['C6']);
    });
  });

  group('SGF and games', () {
    test('import keeps a backup of the game it replaces', () async {
      await load();
      final second = await run('sgf.import', {'content': '(;GM[1]SZ[9];B[ee])', 'at_end': true});
      final backup = second['previous_game_backup'] as String;
      expect(File(backup).readAsStringSync(), contains('PB[Shin]'));
      expect(second['current']['move_number'], 1);
      expect(second['loaded'], '<content>');
      expect((await fails('sgf.import')).code, 'bad_argument');
      expect((await fails('sgf.import', {'content': '(;GM[1]SZ[19];B[pd'})).code, 'sgf_parse_error');
    });

    test('import from a file', () async {
      File('${tmp.path}/g.sgf').writeAsStringSync(game);
      final loaded = await run('sgf.import', {'path': '${tmp.path}/g.sgf'});
      expect(loaded['game']['sgf_filename'], loaded['loaded']);
      expect(File(loaded['loaded'] as String).isAbsolute, isTrue);
    });

    test('export never overwrites unless asked', () async {
      await load();
      expect((await run('sgf.export'))['sgf'], startsWith('(;GM[1]'));
      final path = '${tmp.path}/out/x.sgf';
      expect((await run('sgf.export', {'path': path}))['bytes'], greaterThan(50));
      expect((await fails('sgf.export', {'path': path})).code, 'file_exists');
      expect((await run('sgf.export', {'path': path, 'overwrite': true}))['path'], isNotNull);
    });

    test('new game', () async {
      final status = await run('game.new', {'size': 9, 'komi': 0.5, 'rules': 'chinese', 'handicap': 2});
      expect(status['game']['board_size'], [9, 9]);
      expect(status['game']['komi'], 0.5);
      expect(status['game']['handicap'], 2);
      expect((status['current']['placements']['B'] as List).toSet(), {'G7', 'C3'});
    });
  });

  group('analysis', () {
    test('get, run and reuse', () async {
      await load();
      final got = await run('analysis.get', {'top': 2});
      expect(got['available'], isTrue);
      expect(got['candidates'], hasLength(2));
      expect(got['root']['score_lead'], 1.5); // Black to move
      final reused = await run('analysis.run', {'visits': 50});
      expect(reused['reused_existing'], isTrue);
      final searched = await run('analysis.run', {'visits': 300, 'pv': false});
      expect(searched['reused_existing'], isFalse);
      expect(searched['root']['visits'], 300);
      expect(searched['candidates'][0].containsKey('pv'), isFalse);
      final forced = await run('analysis.run', {'visits': 300, 'force': 'true'});
      expect(forced['reused_existing'], isFalse);
      final queued = await run('analysis.run', {'node': '2', 'visits': 999, 'wait': false});
      expect(queued['queued'], isTrue);
      expect(
        (await run('analysis.get', {
          'node': '3',
          'moves': ['zz'],
        }))['candidates'],
        isEmpty,
      );
    });

    test('region search', () async {
      await load();
      final r = await run('analysis.run', {'region': 'C3:G7', 'visits': 60});
      expect(r['region'], {'from': 'C3', 'to': 'G7'});
      expect((await fails('analysis.run', {'region': 'C3'})).code, 'bad_region');
    });

    test('ownership and policy', () async {
      await load();
      final r = await run('analysis.get', {'ownership': true, 'policy': true, 'pv_limit': 1});
      expect(r['ownership'], hasLength(19));
      expect((r['ownership'] as List)[0], hasLength(19));
      expect(r['policy_top'], hasLength(10));
      expect(r['candidates'][0]['pv'], hasLength(1));
    });

    test('comparing moves sorts them by points lost', () async {
      await load();
      final r = await run('analysis.moves', {'moves': 'K10, C3', 'visits': 50});
      expect([for (final c in r['candidates']) c['move']], ['C3', 'K10']);
      expect(r['compared_visits'], 50);
      expect((await fails('analysis.moves', {'moves': []})).code, 'bad_argument');
      await run('nav.goto', {'node': '1'});
      expect(
        (await fails('analysis.moves', {
          'moves': ['Q16'],
        })).code,
        'illegal_move',
      );
    });

    test('game analysis, waiting, pondering', () async {
      await load();
      final queued = await run('analysis.game', {'visits': 30, 'move_range': '2:6', 'mistakes_only': true});
      expect(queued['move_range'], [2, 6]);
      expect(queued['mistakes_only'], isTrue);
      expect((await run('analysis.wait'))['idle'], isTrue);
      expect((await run('analysis.ponder', {'on': 'on'}))['pondering'], isTrue);
      expect((await fails('analysis.wait')).code, 'pondering');
      expect((await run('analysis.ponder', {'on': false}))['pondering'], isFalse);
      expect((await run('analysis.stop'))['stopped'], isTrue);
    });

    test('engine settings', () async {
      final changed = await run('engine.set', {'max_visits': '300', 'wide_root_noise': 0.02, 'save': true});
      expect(changed['changed'], {'max_visits': 300, 'wide_root_noise': 0.02});
      expect(changed['max_visits'], 300);
      expect(host.saved, ['engine']);
      expect((await run('engine.get'))['wide_root_noise'], 0.02);
      expect((await fails('engine.set', {'fast_visits': -1})).code, 'bad_argument');
      expect((await fails('engine.set', {'max_time': 'abc'})).code, 'bad_argument');
      final nothing = await fails('engine.set');
      expect(nothing.message, contains('max_visits'));
    });
  });

  group('navigation and editing', () {
    test('goto, next, prev, branch', () async {
      await load();
      expect((await run('nav.goto', {'node': '5', 'board': true}))['board']['last_move'], 'F3');
      expect((await run('nav.next'))['current']['move']['move'], 'C6');
      expect((await run('nav.prev', {'n': 3}))['current']['move_number'], 3);
      await run('nav.goto', {'node': '6'});
      final branched = await run('nav.branch', {'direction': 1});
      expect(branched['current']['move']['move'], 'H3');
      expect(branched['sibling_index'], 1);
      expect((await fails('nav.branch', {'index': 9})).code, 'no_variation');
      await run('nav.goto', {'node': 'root'});
      expect((await fails('nav.branch')).code, 'no_variation');
    });

    test('play', () async {
      await load();
      await run('nav.goto', {'node': '8'});
      final played = await run('play', {'moves': 'A1 B:B1 pass'});
      expect(played['played'], ['A1', 'B1', 'pass']);
      expect(played['current']['move']['player'], 'W'); // B1 forced black, so white passes
      expect(played['game_modified'], isTrue);
      expect(played['hint'], contains('demo start'));
      expect(
        (await fails('play', {
          'moves': ['A1'],
        })).code,
        'illegal_move',
      );
      expect((await fails('play', {'moves': 'Z99'})).code, 'bad_coordinate');
      expect((await fails('play', {'moves': 'D4', 'color': 'green'})).code, 'bad_color');
      expect((await fails('play')).code, 'bad_argument');
      final again = await run('play', {
        'moves': ['C1'],
        'color': 'white',
      });
      expect(again['current']['move'], {'player': 'W', 'move': 'C1'});
    });

    test('variations: add, delete, promote', () async {
      await load();
      final added = await run('variation.add', {
        'from': '3',
        'moves': ['E3', 'F3'],
      });
      expect(added['nodes'], hasLength(2));
      expect((await run('status'))['current']['move_number'], 0); // the board did not move
      final ownId = added['end'] as String;
      expect((await fails('variation.delete', {'node': '2'})).code, 'protected');
      expect((await run('variation.delete', {'node': ownId}))['deleted_nodes'], 1);
      final h3 = (await run('variations', {'node': '5'}))['children'][1]['start'];
      final promoted = await run('variation.promote', {'node': h3});
      expect(promoted['on_main_line'], isTrue);
      expect((await run('node', {'node': 'main:6'}))['move']['move'], 'H3');
      expect((await run('variation.delete', {'node': '6', 'force': true}))['deleted_nodes'], 2);
      expect((await fails('variation.delete', {'node': 'root'})).code, 'bad_argument');
    });

    test('registered variations', () async {
      await load();
      final v = await run('variation.register', {'from': '4', 'moves': 'C17 C16', 'label': 'idea'});
      expect(v['id'], 'v1');
      expect(v['moves'], ['B:C17', 'W:C16']);
      expect((await run('variation.list'))[0]['current_game'], isTrue);
      final shown = await run('variation.show', {'id': 'v1', 'step': 1});
      expect(shown['shown_moves'], 1);
      expect(shown['animated'], isFalse);
      final branch = await run('variation.show', {'id': 'v1', 'as': 'branch'});
      expect(branch['current']['move']['move'], 'C16');
      expect((await fails('variation.show', {'id': 'v9'})).code, 'not_found');
    });
  });

  group('board display', () {
    test('variations shown as numbered stones', () async {
      await load();
      final shown = await run('pv.show', {'candidate': (await run('analysis.get'))['candidates'][0]['move']});
      expect(shown['animated'], isTrue);
      expect(host.pv!.pinned, isTrue);
      expect((await run('pv.step', {'index': 1}))['shown_moves'], 1);
      expect((await run('pv.step'))['shown_moves'], 2);
      expect((await run('pv.step', {'delta': -5}))['shown_moves'], 1);
      expect((await run('pv.step', {'index': 99}))['shown_moves'], 3);
      expect((await run('status'))['pv_shown'], isTrue);
      await run('pv.hide');
      expect(host.pv, isNull);
      expect((await fails('pv.step')).code, 'no_pv');
      expect((await fails('pv.show', {'candidate': 'A19'})).code, 'not_found');
      expect((await fails('pv.show', {'moves': 'B:C3 B:C4'})).code, 'bad_argument');
      expect((await fails('pv.show')).code, 'bad_argument');
    });

    test('marks', () async {
      await load();
      final labels = await run('mark.add', {'points': 'C3 D4', 'type': 'label'});
      expect([for (final m in labels['added']) m['text']], ['A', 'B']);
      expect(labels['added'][0]['point'], 'C3');
      final texts = await run('mark.add', {
        'points': ['E5', 'F6'],
        'type': 'label',
        'text': 'x y',
      });
      expect([for (final m in texts['added']) m['text']], ['x', 'y']);
      final one = await run('mark.add', {'points': 'G7', 'type': 'label', 'text': 'two words', 'scope': 'global'});
      expect(one['added'][0]['text'], 'two words');
      expect(one['added'][0]['node'], isNull);
      await run('mark.add', {'points': 'C3', 'type': 'circle', 'color': '#10ff20'}); // replaces the label at C3
      final area = await run('mark.area', {'region': 'B2:F6', 'text': 'weak'});
      expect(area['added'][0]['region'], {'from': 'B2', 'to': 'F6'});
      expect(area['added'][0]['color'], 'yellow');
      final list = await run('mark.list') as List;
      expect(list, hasLength(6));
      expect([for (final m in list) m['id']], [2, 3, 4, 5, 6, 7]);
      expect((await fails('mark.add', {'points': 'H8', 'color': 'mauve'})).code, 'bad_argument');
      expect((await fails('mark.add', {'points': 'H8', 'type': 'area'})).code, 'bad_argument');
      expect((await fails('mark.add', {'points': 'pass'})).code, 'bad_coordinate');
      expect((await fails('mark.add', {'points': []})).code, 'bad_argument');
      expect(await run('mark.clear', {'ids': '#2 3'}), {'removed': 2, 'remaining': 4});
      expect(await run('mark.clear', {'points': 'F6'}), {'removed': 1, 'remaining': 3});
      expect(visibleMarks(api.state.marks, host.game!.root), hasLength(3));
      await run('nav.next');
      expect(visibleMarks(api.state.marks, host.game!.currentNode), hasLength(1)); // the global one
      expect(await run('mark.clear'), {'removed': 3, 'remaining': 0});
    });

    test('region, view and mode', () async {
      await load();
      expect((await run('region.set', {'region': 'D4,K10'}))['region_of_interest'], {'from': 'D4', 'to': 'K10'});
      expect((await run('region.set', {'region': 'A1:T19'}))['region_of_interest'], isNull); // the whole board
      expect((await fails('region.set', {'region': 'pass:D4'})).code, 'bad_region');
      expect((await run('region.clear'))['region_of_interest'], isNull);
      final view = await run('view.set', {'hints': true, 'ownership': 'on', 'children': 1, 'move_numbers': true});
      expect(view['changed'], {'hints': true, 'ownership': true, 'children': true, 'move_numbers': true});
      expect(view['view']['policy'], isFalse);
      expect(host.controls['show_children'], isTrue);
      final zoomed = await run('view.set', {'zoom': 'C3:G7'});
      expect(zoomed['view']['zoom'], {'from': 'C3', 'to': 'G7'});
      expect(host.zoomRegion, [2, 6, 2, 6]);
      expect((await fails('view.set', {'zoom': 'auto'})).code, 'no_tsumego');
      expect((await run('view.set', {'zoom': 'off'}))['view']['zoom'], isNull);
      expect((await run('mode.set', {'mode': 'play'}))['mode'], 'play');
      expect((await fails('mode.set', {'mode': 'bogus'})).code, 'bad_argument');
      final message = await run('message', {'text': 'x' * 400});
      expect((message['shown'] as String).length, 300);
      expect(host.statusMessage, message['shown']);
    });
  });

  group('states and demos', () {
    test('saved states', () async {
      await load();
      await run('nav.goto', {'node': '4'});
      await run('mark.add', {'points': 'K10'});
      await run('pv.show', {'moves': 'C3 C4', 'step': 1});
      final saved = await run('state.save', {'name': 'before / test'});
      expect(saved['link'], 'katrain://state/before%20%2F%20test');
      expect(saved['marks'], 1);
      expect(saved['pv'], ['C3', 'C4']);
      await run('nav.goto', {'node': 'end'});
      await run('mark.clear');
      final restored = await run('state.restore', {'name': 'before / test'});
      expect(restored['current']['move_number'], 4);
      expect(api.state.marks, hasLength(1));
      expect(host.pv!.moves, ['C3', 'C4']);
      expect((await run('state.list') as List).single['name'], 'before / test');
      expect((await fails('state.restore', {'name': 'nope'})).code, 'not_found');
    });

    test('demos leave the record as it was', () async {
      await load();
      await run('nav.goto', {'node': '8'});
      final started = await run('demo.start', {'label': 'why'});
      expect(started['label'], 'why');
      expect(host.mode, modeAnalyze);
      expect((await fails('demo.start')).code, 'demo_active');
      final played = await run('play', {'moves': 'S1 S2'});
      expect(played['in_demo'], isTrue);
      expect((await run('demo.status'))['added_nodes'], 2);
      final ended = await run('demo.end');
      expect(ended['removed_nodes'], 2);
      expect(ended['current']['move_number'], 8);
      expect((await fails('demo.end')).code, 'no_demo');
      await run('demo.start');
      await run('play', {'moves': 'S1'});
      expect((await run('demo.end', {'keep': true}))['removed_nodes'], 0);
      expect((await run('status'))['game']['nodes'], 12);
    });
  });

  group('sandboxes', () {
    test('explore without moving the board', () async {
      await load();
      final sb = await run('sandbox.new', {'from': '4'});
      expect(sb['id'], startsWith('s'));
      final id = sb['id'];
      final played = await run('sandbox.play', {'id': id, 'moves': 'K10 K11 L10'});
      expect(played['moves'], ['B:K10', 'W:K11', 'B:L10']);
      expect(played['created_nodes'], 3);
      expect((await run('status'))['current']['move_number'], 0);
      expect((await run('sandbox.back', {'id': id, 'n': 9}))['move_number'], 4); // not past the start
      await run('sandbox.play', {'id': id, 'moves': 'K10'}); // reuses the node
      final analysed = await run('sandbox.analyze', {'id': id, 'visits': 70});
      expect(analysed['reused_existing'], isFalse);
      expect((await run('sandbox.analyze', {'id': id, 'visits': 60}))['reused_existing'], isTrue);
      final compared = await run('sandbox.analyze', {'id': id, 'moves': 'N10 B2', 'visits': 30});
      expect([for (final c in compared['candidates']) c['move']], ['B2', 'N10']);
      expect((await run('sandbox.show', {'id': id, 'step': 1}))['shown'], 'pv');
      expect((await run('sandbox.show', {'id': id, 'as': 'goto'}))['current']['move_number'], 5);
      expect((await run('sandbox.list') as List), hasLength(1));
      await run('nav.goto', {'node': 'root'});
      expect(await run('sandbox.drop', {'id': id, 'prune': true}), {'dropped': 1, 'pruned_nodes': 3});
      expect((await fails('sandbox.drop', {'id': id})).code, 'not_found');
      await run('sandbox.new', {'name': 'mine'});
      expect((await fails('sandbox.new', {'name': 'mine'})).code, 'exists');
      expect((await fails('sandbox.show', {'id': 'mine'})).code, 'bad_argument');
    });
  });

  group('tsumego', () {
    late String folder;
    setUp(() {
      folder = '${tmp.path}/problems';
      Directory('$folder/cho').createSync(recursive: true);
      File('$folder/cho/p-2.sgf').writeAsStringSync(
        '(;GM[1]FF[4]SZ[19]C[Black to kill]PL[B]AB[pr][qq][rq][sq][or][nr]AW[qr][rr][pq][oq][nq][mr]'
        '(;B[sr]C[Correct];W[rs])(;B[ps]C[Wrong]))',
      );
      File('$folder/cho/p-10.sgf').writeAsStringSync('(;GM[1]SZ[19]GN[ten]AB[cc][dc]AW[bc][bd]PL[W];W[db])');
      File('$folder/center.sgf')
          .writeAsStringSync('(;GM[1]FF[4]SZ[19]GN[center 3d]AB[jj][jk][kj]AW[ij][ik][jl][kk][lj][ji]PL[B];B[jm])');
      File('$folder/unanswered.sgf').writeAsStringSync('(;GM[1]FF[4]SZ[19]AB[aa][ba]AW[ca][cb]PL[B])');
    });

    test('listing', () async {
      final listed = await run('tsumego.list', {'source': folder});
      expect(listed['total'], 3); // problems without an answer are left out
      expect((await run('tsumego.list', {'source': folder, 'answered': false}))['total'], 4);
      expect([for (final p in listed['problems']) p['name']], ['center 3d', 'p-2', 'ten']);
      expect(listed['difficulties'], {'3d': 1, 'unknown': 2});
      expect((await run('tsumego.list', {'source': folder, 'set': 'cho'}))['total'], 2);
      expect((await fails('tsumego.list', {'source': '$folder/missing'})).code, 'not_found');
    });

    test('solving', () async {
      final loaded = await run('tsumego.load', {'source': folder, 'index': 1});
      expect(loaded['problem']['name'], 'p-2');
      expect(loaded['goal'], 'kill');
      expect(loaded['frame'], isTrue);
      expect(loaded['has_reference_solution'], isTrue);
      expect(host.zoomRegion, isNotNull);
      expect(host.hiddenCoords, isNotEmpty);
      // played against KataGo at full strength, with nothing on the board that gives the answer away
      expect(host.mode, modePlay);
      expect((host.playersInfo['B']!.playerType, host.playersInfo['W']!.playerType), (playerHuman, playerAi));
      expect(host.playersInfo['W']!.playerSubtype, aiDefault);
      for (final key in spoilers) {
        expect(host.controls[key], isFalse, reason: key);
      }
      // dead stones have to be captured, so KataGo plays a kill out rather than passing
      expect(host.game!.root.ruleset, 'tromp-taylor');
      final eval = await run('tsumego.eval', {'visits': 40});
      expect(eval['solver'], 'B');
      expect(eval['target']['status'], isNotNull);
      final tried = await run('tsumego.try', {'move': 'T2', 'visits': 40});
      expect(tried['move'], 'B:T2');
      expect(tried['verdict'], isIn(['best', 'ok', 'inaccuracy', 'mistake']));
      expect(tried['reply'], isNotNull);
      final solution = await run('tsumego.solution', {'visits': 40, 'show': true});
      expect(solution['reference_lines'][0], {
        'moves': ['B:T2', 'W:S1'],
        'label': 'correct',
      });
      expect(solution['reference_lines'][1]['label'], 'wrong');
      expect(solution['shown']['pv'], ['T2', 'S1']);
      final reset = await run('tsumego.reset');
      expect(reset['attempts'], 0);
      expect((await run('tsumego.status'))['current'], reset['start']);
      // the answer tree judges the moves: a line marked correct solves the problem, one that ends elsewhere fails it
      expect((await run('tsumego.status'))['progress'], {'on_book': true, 'result': null});
      await run('play', {'moves': 'T2'});
      expect((await run('tsumego.status'))['progress'], {'on_book': true, 'result': 'solved', 'comment': 'Correct'});
      await run('tsumego.reset');
      await run('play', {'moves': 'Q1'});
      expect((await run('tsumego.status'))['progress'], {'on_book': true, 'result': 'failed', 'comment': 'Wrong'});
      await run('tsumego.reset');
      await run('play', {'moves': 'S1'});
      expect((await run('tsumego.status'))['progress'], {'on_book': false, 'result': null});
      await run('tsumego.reset');
      // a move played through the API is analysed only inside the problem, so the AI never answers in the frame
      final engine = host.testEngine as FakeEngine;
      engine.requests.clear();
      await run('play', {'moves': 'T2'});
      final region = host.game!.regionOfInterest;
      expect(engine.requests, isNotEmpty);
      expect([for (final r in engine.requests) r.regionOfInterest], everyElement(region));
      await run('tsumego.reset');
      expect((await fails('tsumego.target', {'goal': 'win'})).code, 'bad_argument');
      expect((await fails('tsumego.target', {'group': 'A1'})).code, 'bad_argument');
      final zoom = await run('view.set', {'zoom': 'auto', 'hide_frame': false});
      expect(zoom['view']['hidden_stones'], 0);
      await run('game.new');
      expect((await run('tsumego.status'))['active'], isFalse);
      expect((await fails('tsumego.eval')).code, 'no_tsumego');
    });

    test('center problems get no frame', () async {
      final loaded = await run('tsumego.load', {'source': folder, 'index': 0});
      expect(loaded['frame'], isFalse);
      expect(loaded['region'], loaded['view']);
      expect((await fails('tsumego.load', {'source': folder, 'index': 9})).code, 'not_found');
    });
  });

  test('commands list every command once, with its help', () async {
    final commands = await run('commands') as Map;
    expect(commands.length, apiCommands.length);
    expect(commands['analysis.run']['waits_for_engine'], isTrue);
    expect(commands['status']['waits_for_engine'], isFalse);
    expect((await fails('nope')).code, 'unknown_command');
  });
}
