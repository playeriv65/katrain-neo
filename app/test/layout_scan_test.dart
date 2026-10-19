// Lays out the main screen, the menu and every dialog at several window sizes and in several languages, and reports
// overflowing layouts and text that is cut off. NEO_LAYOUT_OUT (a folder) also saves each screen as a PNG.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:katrain_neo/main.dart';
import 'package:katrain_neo/src/state/app_controller.dart';
import 'package:katrain_neo/src/state/dialogs.dart';
import 'package:katrain_neo/src/ui/board/board_images.dart';
import 'package:katrain_neo/src/ui/move_tree.dart';

import 'fonts.dart';

/// Window sizes in logical pixels: the default window on a 1366x768 laptop, on a 1920x1080 display, and wide.
const sizes = [Size(868, 668), Size(1274, 980), Size(1600, 900)];
const languages = ['en', 'cn', 'de', 'ru', 'fr', 'jp', 'ko', 'tr'];

/// The font each language needs beyond Segoe UI (or Roboto standing in for it); without it, the language is not
/// scanned, as its text would be laid out in the test's placeholder glyphs.
const languageFonts = {'cn': 'Microsoft YaHei', 'jp': 'Yu Gothic', 'ko': 'Malgun Gothic'};

const sgf =
    '(;GM[1]FF[4]SZ[19]KM[6.5]RU[japanese]PB[Shin Jinseo]PW[Ke Jie]BR[9d]WR[9d]'
    ';B[pd];W[dp];B[pq];W[dd];B[fq];W[cn];B[jp];W[qo];B[pl];W[qq];B[pp];W[qp];B[po];W[rr])';

void main() {
  final out = Platform.environment['NEO_LAYOUT_OUT'];
  late BoardImages images;
  late Set<String> fonts;

  // files are read before the test, in real time; in the test the app runs in the test's time, and every wait is a
  // pump
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    fonts = await loadFonts(systemUi: true);
    images = await BoardImages.load();
  });

  testWidgets('no overflow and no cut-off text', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final problems = <String>[];
    final scanned = [
      for (final lang in languages)
        if (languageFonts[lang] == null || fonts.contains(languageFonts[lang])) lang,
    ];
    final settings = defaultConfig();
    final app = AppController(MemoryConfigStore(settings), resourceDir: '.');
    await app.start(engineWithoutIo: KataGoEngine(app.engineHost, (settings['engine'] as Map).cast<String, dynamic>()));
    app.loadSgfText(sgf);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: KaTrainNeoApp(app: app, images: images),
      ),
    );

    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    String where(RenderObject node) {
      final creator = node.debugCreator;
      return creator is DebugCreator ? creator.element.debugGetCreatorChain(6) : '$node';
    }

    void check(String screen) {
      void visit(RenderObject node) {
        if (node is RenderFlex && node.hasSize) {
          // children beyond the end of a row or column: what the striped overflow marker shows
          final horizontal = node.direction == Axis.horizontal;
          final extent = horizontal ? node.size.width : node.size.height;
          var end = 0.0;
          node.visitChildren((child) {
            final box = child as RenderBox;
            final offset = (box.parentData! as BoxParentData).offset;
            end = math.max(end, horizontal ? offset.dx + box.size.width : offset.dy + box.size.height);
          });
          if (end > extent + 0.5) {
            problems.add('$screen: overflow by ${(end - extent).toStringAsFixed(0)} px in ${where(node)}');
          }
        }
        if (node is RenderParagraph && node.hasSize) {
          // more lines than allowed, or more than the box around the text has room for (CJK fonts have line boxes
          // a pixel or two taller than their glyphs, which is no cut)
          // (a paragraph is as wide as its longest line; laid out again at exactly that width, rounding can break
          // a line more, so give it a pixel)
          final textHeight = node.getMinIntrinsicHeight(node.size.width + 1);
          if (node.didExceedMaxLines) {
            problems.add('$screen: cut off "${node.text.toPlainText()}" in ${where(node)}');
          } else if (textHeight > node.size.height + 3) {
            final excess = (textHeight - node.size.height).toStringAsFixed(1);
            problems.add('$screen: $excess px too tall "${node.text.toPlainText()}" in ${where(node)}');
          }
        }
        node.visitChildren(visit);
      }

      // content hidden in a sideways scroll, which a mouse user rarely finds
      for (final element in find.byType(Scrollable).evaluate()) {
        final state = (element as StatefulElement).state as ScrollableState;
        if (element.findAncestorWidgetOfExactType<MoveTree>() != null) continue; // a tree is wide on purpose
        if (axisDirectionToAxis(state.axisDirection) == Axis.horizontal &&
            state.position.hasContentDimensions &&
            state.position.maxScrollExtent > 0.5) {
          problems.add(
            '$screen: ${state.position.maxScrollExtent.round()} px hidden sideways in ${element.debugGetCreatorChain(4)}',
          );
        }
      }
      for (final view in tester.binding.renderViews) {
        visit(view);
      }
    }

    Future<void> save(String name) async {
      if (out == null) return;
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await render.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    final screen = app.screen!;
    for (final size in sizes) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (final lang in scanned) {
        i18n.switchLang(lang);
        final tag = '${size.width.round()}x${size.height.round()}_$lang';
        for (final mode in [modeAnalyze, modePlay]) {
          app.selectMode(mode);
          await settle();
          check('$tag $mode');
          await save('${tag}_$mode');
        }
        app.toggleMenu();
        await settle();
        check('$tag menu');
        await save('${tag}_menu');
        app.toggleMenu();
        await tester.pumpAndSettle();
        for (final (name, open) in <(String, void Function())>[
          for (final dialog in AppDialog.values)
            if (dialog != AppDialog.saveGameAs) (dialog.name, () => app.openDialog(dialog)),
          (
            'engine_failure',
            () => screen.showEngineFailure(const EngineFailure('KataGo exited with code 1', 1, 'local')),
          ),
        ]) {
          open();
          await settle();
          check('$tag $name');
          await save('${tag}_$name');
          tester.state<NavigatorState>(find.byType(Navigator).first).pop();
          await tester.pumpAndSettle();
        }
      }
    }
    i18n.switchLang('en');
    tester.view.reset();
    await app.shutdown();
    app.dispose();
    debugDefaultTargetPlatformOverride = null;
    if (out != null) File('$out/problems.txt').writeAsStringSync('${problems.toSet().join('\n')}\n');
    expect(problems.toSet(), isEmpty);
  });
}
