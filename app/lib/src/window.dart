// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/__main__.py KaTrainApp: the window's
// size and position, restored from the last session, and what happens when it closes.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:katrain_core/katrain_core.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'state/katrain_gui.dart';

/// Set to keep the window hidden (to try the app without it taking the screen).
const hiddenWindowVariable = 'KATRAIN_NEO_HIDDEN';

/// Sizes the window as KaTrain does and shows it; on closing, saves the ui state and window placement and stops
/// the engine.
Future<void> setUpWindow(KaTrainGui gui, String title) async {
  await windowManager.ensureInitialized();
  final displays = await screenRetriever.getAllDisplays();
  List<num>? size;
  num? left;
  num? top;
  if ((gui.config('ui_state/restoresize', true) ?? true) == true) {
    final saved = gui.config('ui_state/size', []);
    size = saved is List && saved.length == 2 ? saved.cast<num>() : null;
    left = gui.config('ui_state/left') as num?;
    top = gui.config('ui_state/top') as num?;
  }
  if (size == null) {
    var scale = 1.0;
    for (final d in displays) {
      scale = math.min(scale, math.min((d.size.height - 100) / 1000, (d.size.width - 100) / 1300));
    }
    if (displays.isEmpty) scale = 0.85;
    size = [1300 * scale, 1000 * scale];
  }
  gui.log('Setting window size to $size and position to ${[left, top]}', outputDebug);
  final windowSize = Size(size[0].toDouble(), size[1].toDouble());
  final validPosition =
      left != null &&
      top != null &&
      displays.any((m) {
        final origin = m.visiblePosition ?? Offset.zero;
        return left! >= origin.dx &&
            left + windowSize.width <= origin.dx + m.size.width &&
            top! >= origin.dy &&
            top + windowSize.height <= origin.dy + m.size.height;
      });

  await windowManager.waitUntilReadyToShow(
    WindowOptions(size: windowSize, title: title, center: !validPosition),
    () async {
      if (validPosition) await windowManager.setPosition(Offset(left!.toDouble(), top!.toDouble()));
      if (Platform.environment[hiddenWindowVariable] == null) {
        await windowManager.show();
        await windowManager.focus();
      }
    },
  );
  await windowManager.setPreventClose(true);
  windowManager.addListener(_CloseListener(gui));
}

final List<Future<void> Function()> _onClose = [];

/// Runs [callback] when the window closes, before the engine stops.
void onWindowClose(Future<void> Function() callback) => _onClose.add(callback);

class _CloseListener extends WindowListener {
  final KaTrainGui gui;
  _CloseListener(this.gui);

  @override
  Future<void> onWindowClose() async {
    gui.saveUiState();
    final bounds = await windowManager.getBounds();
    final uiState = gui.configStore.data['ui_state'] as Map;
    uiState['size'] = [bounds.width, bounds.height];
    uiState['top'] = bounds.top;
    uiState['left'] = bounds.left;
    gui.saveConfig('ui_state');
    for (final callback in _onClose) {
      await callback();
    }
    await gui.shutdown();
    await windowManager.destroy();
  }
}
