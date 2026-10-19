// The bar below the board: pass, navigation through the game and to mistakes, rotation, who is to move, and the
// engine status light with its queue length. When the policy is shown, passing's policy colours the pass button.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'board/board_painters.dart';

class BottomBar extends StatelessWidget {
  final AppController app;

  /// The pass button's key, so the board can draw a passed stone of a variation next to it.
  final GlobalKey passButtonKey;
  const BottomBar({super.key, required this.app, required this.passButtonKey});

  @override
  Widget build(BuildContext context) {
    final next = app.game?.currentNode.nextPlayer ?? 'B';
    Widget nav(IconData icon, String tooltip, VoidCallback onPressed, {Color? color}) => IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: color),
    );
    return LayoutBuilder(
      // a narrow bar leaves out the 10-move steps and rotation; their keys still work
      builder: (context, constraints) => _bar(context, nav, next, full: constraints.maxWidth >= 620),
    );
  }

  Widget _bar(
    BuildContext context,
    Widget Function(IconData, String, VoidCallback, {Color? color}) nav,
    String next, {
    required bool full,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _PassButton(app: app, passButtonKey: passButtonKey),
          const Spacer(),
          nav(
            Icons.keyboard_double_arrow_left,
            'Shift+N',
            () => app.findMistake(backwards: true),
            color: KTheme.mistakeButtonColor,
          ),
          nav(Icons.first_page, 'Home', () => app.undo(9999)),
          if (full) nav(Icons.fast_rewind, 'Shift+←', () => app.undo(10)),
          nav(Icons.chevron_left, '←', () => app.undo()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Tooltip(
              message: i18n.tr('short color $next'),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: KTheme.stoneColors[next],
                  border: Border.all(color: KTheme.stoneColors[next == 'B' ? 'W' : 'B']!),
                ),
              ),
            ),
          ),
          nav(Icons.chevron_right, '→', () => app.redo()),
          if (full) nav(Icons.fast_forward, 'Shift+→', () => app.redo(10)),
          nav(Icons.last_page, 'End', () => app.redo(9999)),
          nav(Icons.keyboard_double_arrow_right, 'N', () => app.findMistake(), color: KTheme.mistakeButtonColor),
          if (full) ...[const SizedBox(width: 8), nav(Icons.rotate_right, i18n.tr('Rotate'), app.rotate)],
          const Spacer(),
          _EngineStatus(app: app),
        ],
      ),
    );
  }
}

class _PassButton extends StatelessWidget {
  final AppController app;
  final GlobalKey passButtonKey;
  const _PassButton({required this.app, required this.passButtonKey});

  @override
  Widget build(BuildContext context) {
    Color? policyColor;
    if (app.game != null && app.analysisControls['policy']!) {
      final policy = boardPolicy(app);
      if (policy != null) {
        final movePolicy = policy.last;
        final polOrder = 5 - (-math.log(math.max(1e-9, movePolicy - 1e-9)) / math.ln10).truncate();
        if (polOrder >= 0) {
          policyColor = withAlpha(KTheme.evalColors[trainerConfig(app)['theme']]![polOrder], KTheme.ghostAlpha);
        }
      }
    }
    return Tooltip(
      message: 'P',
      child: OutlinedButton(
        key: passButtonKey,
        style: policyColor == null ? null : OutlinedButton.styleFrom(backgroundColor: policyColor),
        onPressed: () => app.play(null),
        child: Text(i18n.tr('pass-button-text')),
      ),
    );
  }
}

class _EngineStatus extends StatelessWidget {
  final AppController app;
  const _EngineStatus({required this.app});

  @override
  Widget build(BuildContext context) {
    final engine = app.engine;
    final Color color;
    final String state;
    if (engine == null) {
      color = KTheme.engineDownColor;
      state = 'KataGo: off';
    } else if (engine.isIdle()) {
      color = KTheme.engineReadyColor;
      state = 'KataGo: ready';
    } else {
      color = KTheme.engineBusyColor;
      state = 'KataGo: busy';
    }
    final remaining = engine?.queriesRemaining() ?? 0;
    return Tooltip(
      message: state,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => app.setStatus(i18n.tr('ai-ponder'), statusInfo),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 18,
                child: app.isPondering
                    ? CircularProgressIndicator(
                        strokeWidth: 3,
                        color: KTheme.enginePonderingColor,
                        backgroundColor: color,
                      )
                    : DecoratedBox(
                        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                      ),
              ),
              if (remaining >= 3) ...[const SizedBox(width: 6), Text('$remaining')],
            ],
          ),
        ),
      ),
    );
  }
}
