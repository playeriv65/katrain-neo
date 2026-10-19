// KaTrain's keyboard shortcuts on the main screen and in popups.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:katrain_neo/main.dart';
import 'package:katrain_neo/src/state/katrain_gui.dart';
import 'package:katrain_neo/src/ui/board/board_images.dart';
import 'package:katrain_neo/src/ui/popups/simple_popups.dart';

import 'fonts.dart';

void main() {
  testWidgets('keyboard shortcuts', (tester) async {
    tester.view.physicalSize = const Size(2800, 1750);
    tester.view.devicePixelRatio = 1.75;
    addTearDown(tester.view.reset);
    late KaTrainGui gui;
    late BoardImages images;
    await tester.runAsync(() async {
      await loadFonts();
      images = await BoardImages.load();
      final settings = defaultConfig();
      gui = KaTrainGui(MemoryConfigStore(settings), resourceDir: '.');
      await gui.start(
        engineWithoutIo: KataGoEngine(gui.engineHost, (settings['engine'] as Map).cast<String, dynamic>()),
      );
    });
    gui.loadSgfText('(;GM[1]SZ[19];B[pd];W[dd];B[pq];W[dp])');
    await tester.pumpWidget(KaTrainNeoApp(gui: gui, images: images));
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    await settle();
    expect(gui.game!.currentNode.depth, 4);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle();
    expect(gui.game!.currentNode.depth, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await settle();
    expect(gui.game!.currentNode.depth, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await settle();
    expect(gui.game!.currentNode.depth, 1);

    final hints = gui.analysisControls['hints']!;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await settle();
    expect(gui.analysisControls['hints'], !hints);

    final mode = gui.mode;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle();
    expect(gui.mode, isNot(mode));

    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await settle();
    expect(find.byType(TimerDialog), findsOneWidget);
    expect(gui.popupOpen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // ignored while a popup is open
    await settle();
    expect(gui.game!.currentNode.depth, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5); // closes it
    await tester.pumpAndSettle();
    expect(find.byType(TimerDialog), findsNothing);
    expect(gui.popupOpen, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
    await settle();
    expect(gui.zen, 1);
    gui.zen = 0;
    gui.refresh();
    await settle();
    gui.dispose();
  });
}
