// The app controller: games, moves and navigation, the action queue, AI and teaching moves, pondering, modes, files,
// dialogs and engine failures, the move tree.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:katrain_core/api.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:katrain_neo/src/state/api_host.dart';
import 'package:katrain_neo/src/state/app_controller.dart';
import 'package:katrain_neo/src/state/dialogs.dart';

import 'support/fake_katago.dart';

/// Records what the controller asks the screen to do.
class FakeScreen implements AppScreen {
  final List<AppDialog> dialogs = [];
  final List<EngineFailure> failures = [];
  int menuToggles = 0;

  @override
  void openDialog(AppDialog dialog) => dialogs.add(dialog);

  @override
  void showEngineFailure(EngineFailure failure) => failures.add(failure);

  @override
  void toggleMenu() => menuToggles += 1;
}

(int, int) at(String gtp) => Move.fromGtp(gtp).coords!;

void main() {
  late FakeKataGo kata;
  late AppController app;
  late FakeScreen screen;

  Future<void> begin({int size = 9, Map<String, Object?> settings = const {}}) async {
    kata = FakeKataGo();
    app = await startApp(kata, size: size, settings: settings);
    screen = FakeScreen();
    app.screen = screen;
  }

  tearDown(() async {
    await kata.settle(app); // queued updates run before the app goes
    await app.shutdown();
    app.dispose();
  });

  List<String> line() => [for (final n in app.game!.currentNode.nodesFromRoot) ?n.move?.gtp()];

  Future<void> playAll(List<String> moves) async {
    for (final m in moves) {
      await app.play(at(m));
    }
    await kata.settle(app);
  }

  group('a new game', () {
    test('follows the settings, is played, and is analysed', () async {
      await begin(settings: {'game/komi': 7.5});
      final g = app.game!;
      expect(g.boardSize, (9, 9));
      expect(g.komi, 7.5);
      expect(app.mode, modePlay);
      expect(g.root.analysisComplete, isTrue);
      expect(kata.sent.first['maxVisits'], (app.config('engine/fast_visits') as num).toInt());
    });

    test('a pasted game is reviewed: analysis mode, at its end, with its players', () async {
      await begin();
      expect(app.loadSgfText('(;GM[1]SZ[9]PB[Ann]PW[Bob];B[ee];W[cc];B[gg])'), isTrue);
      await kata.settle(app);
      expect(app.mode, modeAnalyze);
      expect(line(), ['E5', 'C7', 'G3']);
      expect(app.playersInfo['B']!.name, 'Ann');
      expect([for (final n in app.game!.root.nodesInTree) n.analysisComplete], everyElement(isTrue));
    });

    test('text that is not a game record is refused with a status message', () async {
      await begin();
      final before = app.game;
      expect(app.loadSgfText('hello'), isFalse);
      expect(app.game, same(before));
      expect(app.statusText, isNotEmpty);
    });

    test('a new game leaves the zoomed view and the shown variation behind', () async {
      await begin();
      app.board.setZoom([0, 4, 0, 4]);
      await app.newGame();
      await kata.settle(app);
      expect(app.board.zoomRegion, isNull);
      expect(app.board.pv, isNull);
    });
  });

  group('moves and navigation', () {
    setUp(() => begin());

    test('play, undo and redo', () async {
      await playAll(['E5', 'C3', 'G7']);
      expect(line(), ['E5', 'C3', 'G7']);
      await app.undo();
      expect(line(), ['E5', 'C3']);
      await app.undo(9999);
      expect(line(), isEmpty);
      await app.redo(2);
      expect(line(), ['E5', 'C3']);
    });

    test('an illegal move is refused with an error status', () async {
      await playAll(['E5']);
      await app.play(at('E5'));
      expect(line(), ['E5']);
      expect(app.statusIsError, isTrue);
      expect(app.statusText, i18n.tr('illegal:occupied')); // in the user's language, not the rules' English
    });

    test('a pass is a move', () async {
      await app.play(null);
      expect(app.game!.currentNode.isPass, isTrue);
      expect(app.game!.currentNode.player, 'B');
    });

    test('actions run in the order they were asked for', () async {
      final done = [app.play(at('E5')), app.play(at('C3')), app.undo(), app.play(at('D4'))];
      await Future.wait(done);
      expect(line(), ['E5', 'D4']);
      expect(app.game!.currentNode.parent!.children.map((n) => n.move!.gtp()), ['C3', 'D4']);
    });

    test('actions queued for a game that was replaced are dropped', () async {
      final old = app.game;
      final played = app.play(at('E5'));
      app.startGame();
      await played;
      expect(app.game, isNot(same(old)));
      expect(line(), isEmpty);
      expect(old!.root.children, isEmpty);
    });

    test('undo in play mode against the AI goes back to the human move', () async {
      app.updatePlayer('W', playerType: playerAi, playerSubtype: aiDefault);
      await playAll(['E5']);
      expect(line().length, 2); // the AI answered
      await app.undoSmart();
      expect(line(), isEmpty);
    });

    test('the next and previous mistake of a human', () async {
      app.selectMode(modeAnalyze);
      // the third move (G7) loses 8 points for Black
      kata.scoreFor = (moves, _) => moves.length >= 3 && moves[2] == 'G7' ? -8 : 0;
      await playAll(['E5', 'C3', 'G7', 'C7', 'G3']);
      await app.undo(9999);
      await app.findMistake();
      expect(line(), ['E5', 'C3']); // stops before the mistake
      await app.redo(9999);
      await app.findMistake(backwards: true);
      expect(line(), ['E5', 'C3']);
    });

    test('resigning ends the game for the player to move', () async {
      await playAll(['E5']);
      await app.resign();
      expect(app.game!.endResult, 'B+R');
    });
  });

  group('the AI', () {
    setUp(() => begin());

    test('answers a human move in play mode with the best candidate', () async {
      app.updatePlayer('W', playerType: playerAi, playerSubtype: aiDefault);
      await playAll(['E5']);
      expect(line(), ['E5', 'A9']); // the first empty point, the fake's best move
    });

    test('plays first when it has Black', () async {
      app.updatePlayer('B', playerType: playerAi, playerSubtype: aiDefault);
      await kata.settle(app);
      expect(line(), ['A9']);
    });

    test('does not move in analysis mode, while a dialog is open, or after the game ended', () async {
      app.updatePlayer('W', playerType: playerAi, playerSubtype: aiDefault);
      app.selectMode(modeAnalyze);
      await playAll(['E5']);
      expect(line(), ['E5']);

      app.selectMode(modePlay);
      app.popupOpen = true;
      app.updateState();
      await kata.settle(app);
      expect(line(), ['E5']);

      app.popupOpen = false;
      await app.resign();
      await kata.settle(app);
      expect(line(), ['E5']);
    });

    test('self-play continues the game until passing is best, then shows the end', () async {
      app.selectMode(modeAnalyze);
      await playAll(['E5']);
      await app.selfplay('end');
      await kata.settle(app);
      final played = line();
      expect(played.first, 'E5');
      expect(played.length, 20); // the fake prefers passing from move 20 on
      final start = app.game!.root.children.single;
      expect(start.shortcutsTo.single.$1, same(app.game!.currentNode)); // the new moves are one shortcut
    });

    test('setting up a position plays to the move number, aiming at the score', () async {
      app.selectMode(modeAnalyze);
      await app.selfplay(6, blackAdvantage: 0);
      await kata.settle(app);
      expect(line().length, 6);
    });
  });

  group('teaching', () {
    setUp(() => begin());

    test('a bad move is undone and kept as a variation, a good one stays', () async {
      app.updatePlayer('B', playerType: playerHuman, playerSubtype: playingTeaching);
      // A1 loses 10 points for Black, everything else is even
      kata.scoreFor = (moves, _) => moves.contains('A1') ? -10 : 0;
      await playAll(['A1']);
      expect(line(), isEmpty);
      final undone = app.game!.root.children.single;
      expect(undone.move!.gtp(), 'A1');
      expect(undone.autoUndo, isTrue);

      await playAll(['E5']);
      expect(line(), ['E5']);
      expect(app.game!.currentNode.autoUndo, isFalse);
    });
  });

  group('continuous analysis', () {
    setUp(() => begin());

    test('ponders on the current position until it is turned off', () async {
      app.selectMode(modeAnalyze);
      app.toggleContinuousAnalysis();
      await kata.settle(app);
      expect(app.isPondering, isTrue);
      expect(app.analysisControls['hints'], isTrue);
      expect(kata.ponderQueries, isNotEmpty);

      final pondered = kata.ponderQueries.length;
      await playAll(['E5']);
      expect(kata.ponderQueries.length, greaterThan(pondered)); // the new position

      app.toggleContinuousAnalysis();
      await kata.settle(app);
      expect(app.isPondering, isFalse);
      final last = kata.ponderQueries.last['id'];
      expect(kata.terminated, contains(last));
    });

    test('a new game stops it', () async {
      app.toggleContinuousAnalysis();
      await app.newGame();
      await kata.settle(app);
      expect(app.isPondering, isFalse);
    });
  });

  group('modes', () {
    setUp(() => begin());

    test('each mode keeps its own display toggles and panels', () async {
      app.setAnalysisControl('hints', false);
      app.switchUiMode();
      expect(app.mode, modeAnalyze);
      app.setAnalysisControl('hints', true);
      app.setPanelState('graph_panel', state: 'close');
      app.switchUiMode();
      expect(app.mode, modePlay);
      expect(app.analysisControls['hints'], isFalse);
      app.switchUiMode();
      expect(app.analysisControls['hints'], isTrue);
      expect(app.panels['graph_panel']!.state, 'close');
      expect((app.config('ui_state') as Map).keys, containsAll([modePlay, modeAnalyze]));
    });

    test('insert mode switches to analysis', () async {
      await playAll(['E5', 'C3']);
      await app.undo();
      await app.insertMode();
      expect(app.game!.insertMode, isTrue);
      expect(app.mode, modeAnalyze);
    });
  });

  group('files', () {
    late Directory tmp;
    setUp(() async {
      await begin();
      tmp = Directory.systemTemp.createTempSync('neo_controller_');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('saving writes the game, and loading reads it back', () async {
      await playAll(['E5', 'C3']);
      app.updatePlayer('W', playerType: playerAi, playerSubtype: aiDefault);
      await kata.settle(app);
      final path = '${tmp.path}${Platform.pathSeparator}game.sgf';
      await app.saveGame(path);
      expect(app.game!.sgfFilename, path);
      expect(app.statusText, isNotEmpty);
      final saved = line();

      app.loadSgfFile(path, rewind: false);
      await kata.settle(app);
      expect(line(), saved);
      expect(app.mode, modeAnalyze);
      expect(app.playersInfo['W']!.ai, isFalse); // nobody plays a loaded game
    });

    test('saving a game without a file asks where', () async {
      await app.saveGame();
      expect(screen.dialogs, [AppDialog.saveGameAs]);
    });

    test('a file that cannot be read is reported and the game stays', () async {
      final before = app.game;
      app.loadSgfFile('${tmp.path}${Platform.pathSeparator}missing.sgf');
      expect(app.game, same(before));
      expect(app.statusIsError, isTrue);
    });
  });

  group('dialogs and engine failures', () {
    setUp(() => begin());

    test('opening a dialog reaches the screen and pauses the clock', () async {
      app.clock.paused = false;
      app.openDialog(AppDialog.timer);
      expect(screen.dialogs, [AppDialog.timer]);
      expect(app.clock.paused, isTrue);
      app.toggleMenu();
      expect(screen.menuToggles, 1);
    });

    test('a KataGo crash is shown as an engine failure', () async {
      kata.engine.handleLine('Uncaught exception: out of memory');
      expect(screen.failures.single.message, contains('out of memory'));
      expect(screen.failures.single.engineType, 'local');
      expect(app.statusIsError, isTrue);
    });
  });

  group('a tsumego problem', () {
    late Directory tmp;
    late CommandHandler api;
    setUp(() async {
      await begin(size: 19);
      tmp = Directory.systemTemp.createTempSync('neo_tsumego_');
      // the answer: T2, S1, R1 is correct; S1 first is refuted by T2
      File('${tmp.path}${Platform.pathSeparator}corner.sgf').writeAsStringSync(
        '(;GM[1]FF[4]SZ[19]PL[B]AB[pr][qq][rq][sq][or][nr]AW[qr][rr][pq][oq][nq][mr]'
        '(;B[sr];W[rs];B[qs]C[Correct])(;B[rs];W[sr]))',
      );
      api = CommandHandler(AppApiHost(app), app.apiState, dataFolder: tmp.path);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<void> load() async {
      await api.dispatch('tsumego.load', {'source': tmp.path});
      await kata.settle(app);
    }

    String lastMove() => '${app.game!.currentNode.move!.player}:${app.game!.currentNode.move!.gtp()}';

    test('follows its answer: the answer replies, and a correct line ends it at once', () async {
      await load();
      expect(app.problemProgress!.result, isNull);
      await app.play(at('T2'));
      await kata.settle(app);
      expect(lastMove(), 'W:S1'); // the answer's reply, not a search
      await app.play(at('R1'));
      await kata.settle(app);
      expect(app.problemProgress!.result, 'solved');
      expect(lastMove(), 'B:R1'); // nobody moves after the answer says it is solved
      // the answer's moves were not searched; the hints, once turned on, are
      expect(app.game!.currentNode.analysisExists, isFalse);
      app.setAnalysisControl('hints', true);
      await kata.settle(app);
      expect(app.game!.currentNode.analysisExists, isTrue);
      expect(app.game!.currentNode.parent!.analysisExists, isTrue);
      expect(lastMove(), 'B:R1');
    });

    test('a wrong line fails once the answer has refuted it', () async {
      await load();
      await app.play(at('S1'));
      await kata.settle(app);
      expect(lastMove(), 'W:T2');
      expect(app.problemProgress!.result, 'failed');
    });

    test('is practised from the settings, problem after problem', () async {
      await app.startPractice(source: tmp.path, level: '', index: 0);
      await kata.settle(app);
      expect(app.problemProgress, isNotNull);
      expect((app.practiceSource, app.practiceIndex), (tmp.path, 0));
      await app.nextProblem(); // one problem: round again to it
      await kata.settle(app);
      expect(app.practiceIndex, 0);
      expect(app.problemProgress!.book, isNotNull);
    });

    test('is played against the AI with nothing given away, and going back stops at its start', () async {
      app.setAnalysisControl('hints', true);
      final loaded = await api.dispatch('tsumego.load', {'source': tmp.path}) as Map;
      expect(loaded['to_play'], 'B', reason: '$loaded');
      await kata.settle(app);
      expect(app.mode, modePlay);
      expect(app.solvingTsumego, isTrue);
      expect((app.playersInfo['B']!.ai, app.playersInfo['W']!.ai), (false, true));
      expect(app.analysisControls['hints'], isFalse);
      final start = app.apiState.tsumego!.start;
      expect(app.game!.currentNode, same(start));

      await app.play(at('Q1')); // not in the answer: KataGo answers
      await kata.settle(app);
      expect(app.problemProgress!.book, isNull);
      expect(app.game!.currentNode.parent!.parent, same(start)); // the AI answered

      await app.undo(9999);
      await kata.settle(app);
      expect(app.game!.currentNode, same(start)); // not back to the board without the frame
    });
  });

  group('the move tree', () {
    setUp(() async {
      await begin();
      app.selectMode(modeAnalyze);
      await playAll(['E5', 'C3']);
      await app.undo();
      await playAll(['G7', 'D4', 'D6']); // a second variation after E5
    });

    GameNode branch(String gtp) => app.game!.root.children.single.children.firstWhere((n) => n.move!.gtp() == gtp);

    test('make a variation the main line', () {
      app.moveTreeSelectedNode = branch('G7');
      app.makeSelectedNodeMainBranch();
      expect(app.game!.root.children.single.children.map((n) => n.move!.gtp()), ['G7', 'C3']);
    });

    test('delete a node and go to its parent', () {
      app.moveTreeSelectedNode = branch('C3');
      app.deleteSelectedNode();
      expect(app.game!.root.children.single.children.map((n) => n.move!.gtp()), ['G7']);
      expect(line(), ['E5']);
    });

    test('prune everything but the selected line', () {
      app.moveTreeSelectedNode = branch('C3');
      app.pruneBranch();
      expect(app.game!.root.children.single.children.map((n) => n.move!.gtp()), ['C3']);
      expect(line(), ['E5', 'C3']);
    });

    test('collapse a line into a shortcut to the branching point and expand it again', () {
      final end = app.game!.currentNode; // D6, after E5 G7 D4
      app.moveTreeSelectedNode = end;
      app.toggleSelectedNodeCollapse();
      expect(end.shortcutFrom, same(app.game!.root.children.single));
      app.toggleSelectedNodeCollapse();
      expect(end.shortcutFrom, isNull);
    });
  });
}
