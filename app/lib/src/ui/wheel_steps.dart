// The mouse wheel steps through the game (or the variation being shown) over the board, the bar below it, the side
// panel and the move tree, as in KaTrain. Only the notes keep their own scrolling; a sideways scroll is left alone.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../state/app_controller.dart';

class WheelSteps extends StatelessWidget {
  final AppController app;

  /// Over the board or the bar below it, the wheel steps through a variation being shown.
  final bool overBoard;
  final Widget child;
  const WheelSteps({super.key, required this.app, this.overBoard = false, required this.child});

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: (e) {
      if (e is! PointerScrollEvent || e.scrollDelta.dy == 0) return;
      // the deepest listener claims the event first, so a scrolling panel around this one does not also move
      GestureBinding.instance.pointerSignalResolver.register(
        e,
        (_) => app.wheel(up: e.scrollDelta.dy < 0, overBoard: overBoard),
      );
    },
    child: child,
  );
}
