// KaTrain's keyboard shortcuts on the main screen and in popups.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:katrain_neo/main.dart';
import 'package:katrain_neo/src/state/app_controller.dart';
import 'package:katrain_neo/src/ui/board/board_images.dart';
import 'package:katrain_neo/src/ui/popups/simple_popups.dart';

import 'fonts.dart';

void main() {
  testWidgets('keyboard shortcuts', (tester) async {
    tester.view.physicalSize = const Size(2800, 1750);
    tester.view.devicePixelRatio = 1.75;
    addTearDown(tester.view.reset);
    late AppController app;
    late BoardImages images;
    await tester.runAsync(() async {
      await loadFonts();
      images = await BoardImages.load();
      final settings = defaultConfig();
      app = AppController(MemoryConfigStore(settings), resourceDir: '.');
      await app.start(
        engineWithoutIo: KataGoEngine(app.engineHost, (settings['engine'] as Map).cast<String, dynamic>()),
      );
    });
    app.loadSgfText('(;GM[1]SZ[19];B[pd];W[dd];B[pq];W[dp])');
    await tester.pumpWidget(KaTrainNeoApp(app: app, images: images));
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    await settle();
    expect(app.game!.currentNode.depth, 4);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle();
    expect(app.game!.currentNode.depth, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await settle();
    expect(app.game!.currentNode.depth, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await settle();
    expect(app.game!.currentNode.depth, 1);

    final hints = app.analysisControls['hints']!;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await settle();
    expect(app.analysisControls['hints'], !hints);

    final mode = app.mode;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle();
    expect(app.mode, isNot(mode));

    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await settle();
    expect(find.byType(TimerDialog), findsOneWidget);
    expect(app.popupOpen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // ignored while a popup is open
    await settle();
    expect(app.game!.currentNode.depth, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5); // closes it
    await tester.pumpAndSettle();
    expect(find.byType(TimerDialog), findsNothing);
    expect(app.popupOpen, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
    await settle();
    expect(app.zen, 1);
    app.zen = 0;
    app.refresh();
    await settle();
    app.dispose();
  });
}
