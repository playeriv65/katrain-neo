// Renders the main screen headlessly to a PNG, to look at without opening a window. Runs when NEO_RENDER_SGF
// (a game, e.g. one saved with its analysis) and NEO_RENDER_OUT (a folder) are set; NEO_RENDER_MOVE picks the
// move and NEO_RENDER_LANG the language. With NEO_RENDER_OUT alone, renders what the local API draws: marks, a
// pinned variation and the zoomed tsumego view.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:katrain_core/api.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:katrain_neo/main.dart';
import 'package:katrain_neo/src/state/api_host.dart';
import 'package:katrain_neo/src/state/app_controller.dart';
import 'package:katrain_neo/src/state/dialogs.dart';
import 'package:katrain_neo/src/ui/board/board_images.dart';

import 'fonts.dart';

void main() {
  final env = Platform.environment;
  final sgf = env['NEO_RENDER_SGF'];
  final out = env['NEO_RENDER_OUT'];

  testWidgets('render the main screen', (tester) async {
    tester.view.physicalSize = const Size(2800, 1750);
    tester.view.devicePixelRatio = 1.75;
    addTearDown(tester.view.reset);
    final move = int.parse(env['NEO_RENDER_MOVE'] ?? '78');
    i18n.switchLang(env['NEO_RENDER_LANG'] ?? 'en');
    late AppController app;
    late BoardImages images;
    await tester.runAsync(() async {
      await loadFonts();
      images = await BoardImages.load();
      final settings = defaultConfig();
      app = AppController(MemoryConfigStore(settings), resourceDir: '.');
      final engine = KataGoEngine(app.engineHost, (settings['engine'] as Map).cast<String, dynamic>());
      await app.start(sgfFile: sgf, engineWithoutIo: engine);
    });
    app.redo(move);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    for (final (key, value) in [
      ('show_children', true),
      ('eval', true),
      ('hints', true),
      ('policy', false),
      ('ownership', false),
    ]) {
      app.analysisControls[key] = value;
    }
    app.panels['graph_panel']!.options.addAll({'score': true, 'winrate': true, 'points': false});
    app.panels['notes_panel']!.options.addAll({'info': true, 'info-details': true, 'notes': false});
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: KaTrainNeoApp(app: app, images: images),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // circle images load asynchronously
    for (final element in find.byType(Image).evaluate()) {
      await tester.runAsync(() => precacheImage((element.widget as Image).image, element));
    }
    await tester.pump();

    Future<void> save(String name) async {
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1.75);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    await save('main_analyze');
    app.analysisControls['ownership'] = true;
    app.refresh();
    await tester.pump();
    await save('main_ownership');
    app.analysisControls['ownership'] = false;
    app.analysisControls['policy'] = true;
    app.refresh();
    await tester.pump();
    await save('main_policy');
    app.analysisControls['policy'] = false;
    app.selectMode(modePlay);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await save('main_play');

    final screen = app.screen!;
    for (final (name, open) in <(String, void Function())>[
      for (final dialog in AppDialog.values)
        if (dialog != AppDialog.saveGameAs) (dialog.name, () => app.openDialog(dialog)), // a system dialog
      ('engine_failure', () => screen.showEngineFailure(const EngineFailure('KataGo exited with code 1', 1, 'local'))),
    ]) {
      open();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await save('popup_$name');
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
    }
    app.dispose();
  }, skip: sgf == null || out == null);

  testWidgets('render API overlays', (tester) async {
    tester.view.physicalSize = const Size(2800, 1750);
    tester.view.devicePixelRatio = 1.75;
    addTearDown(tester.view.reset);
    i18n.switchLang('en');
    late AppController app;
    late BoardImages images;
    final problems = Directory.systemTemp.createTempSync('neo_tsumego');
    File('${problems.path}/corner.sgf').writeAsStringSync(
      '(;GM[1]FF[4]SZ[19]C[Black to kill]PL[B]AB[pr][qq][rq][sq][or][nr]AW[qr][rr][pq][oq][nq][mr];B[sr])',
    );
    await tester.runAsync(() async {
      await loadFonts();
      images = await BoardImages.load();
      final settings = defaultConfig();
      app = AppController(MemoryConfigStore(settings), resourceDir: '.');
      final engine = KataGoEngine(app.engineHost, (settings['engine'] as Map).cast<String, dynamic>());
      await app.start(engineWithoutIo: engine);
    });
    final api = CommandHandler(AppApiHost(app), app.apiState, dataFolder: problems.path);
    Future<void> run(String command, Map<String, Object?> args) async {
      await tester.runAsync(() => api.dispatch(command, args));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    }

    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: KaTrainNeoApp(app: app, images: images),
      ),
    );
    Future<void> save(String name) async {
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1.75);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    await run('sgf.import', {'content': '(;GM[1]SZ[19];B[pd];W[dp];B[pq];W[dd];B[fq];W[cn])', 'at_end': true});
    await run('mark.add', {'points': 'C3 D4 E5', 'type': 'label'});
    await run('mark.add', {'points': 'K10', 'type': 'triangle', 'color': 'blue'});
    await run('mark.add', {'points': 'K12', 'type': 'square', 'color': 'green'});
    await run('mark.add', {'points': 'M10', 'type': 'cross'});
    await run('mark.add', {'points': 'O10', 'type': 'dot', 'color': 'orange'});
    await run('mark.add', {'points': 'Q10', 'type': 'circle', 'color': 'purple'});
    await run('mark.area', {'region': 'B15:F19', 'text': 'weak group', 'color': 'orange'});
    await run('pv.show', {'moves': 'C17 D17 C16', 'step': 3});
    await save('api_marks');
    await run('tsumego.load', {'source': problems.path});
    await run('mark.add', {'points': 'S2', 'type': 'circle'});
    await save('api_tsumego_zoom');
    await run('view.set', {'zoom': 'off', 'hide_frame': false});
    await save('api_tsumego_full');
    app.dispose();
    problems.deleteSync(recursive: true);
  }, skip: out == null);
}
