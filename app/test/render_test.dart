// Renders the main screen headlessly to a PNG, to compare with screenshots of KaTrain. Runs when NEO_RENDER_SGF
// (a game, e.g. one KaTrain saved with its analysis) and NEO_RENDER_OUT (a folder) are set; NEO_RENDER_MOVE picks the
// move and NEO_RENDER_LANG the language.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:katrain_neo/main.dart';
import 'package:katrain_neo/src/state/katrain_gui.dart';
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
    late KaTrainGui gui;
    late BoardImages images;
    await tester.runAsync(() async {
      await loadFonts();
      images = await BoardImages.load();
      final settings = defaultConfig();
      gui = KaTrainGui(MemoryConfigStore(settings), resourceDir: '.');
      final engine = KataGoEngine(gui.engineHost, (settings['engine'] as Map).cast<String, dynamic>());
      await gui.start(sgfFile: sgf, engineWithoutIo: engine);
    });
    gui.act('redo', [move]);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    for (final (key, value) in [
      ('show_children', true),
      ('eval', true),
      ('hints', true),
      ('policy', false),
      ('ownership', false),
    ]) {
      gui.analysisControls[key] = value;
    }
    gui.panels['graph_panel']!.options.addAll({'score': true, 'winrate': true, 'points': false});
    gui.panels['notes_panel']!.options.addAll({'info': true, 'info-details': true, 'notes': false});
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: KaTrainNeoApp(gui: gui, images: images),
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
    gui.analysisControls['ownership'] = true;
    gui.refresh();
    await tester.pump();
    await save('main_ownership');
    gui.analysisControls['ownership'] = false;
    gui.analysisControls['policy'] = true;
    gui.refresh();
    await tester.pump();
    await save('main_policy');
    gui.analysisControls['policy'] = false;
    gui.selectMode(modePlay);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await save('main_play');

    for (final (name, args) in <(String, List<Object?>)>[
      ('new-game-popup', []),
      ('timer-popup', []),
      ('teacher-popup', []),
      ('ai-popup', []),
      ('config-popup', []),
      ('analyze-sgf-popup', []),
      ('game-analysis-popup', []),
      ('report-popup', []),
      ('tsumego-frame-popup', []),
      ('engine-recovery-popup', ['KataGo exited with code 1', 1, 'local']),
    ]) {
      gui.act(name, args);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await save('popup_${name.replaceAll('-popup', '')}');
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
    }
    gui.dispose();
  }, skip: sgf == null || out == null);
}
