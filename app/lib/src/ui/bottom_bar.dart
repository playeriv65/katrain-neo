// KaTrain's board controls (katrain/gui.kv BadukPanControls): pass, navigation through the game and to mistakes,
// rotation, who is to move, and the engine status light with its queue length. Passing's policy, when the policy
// is shown, colours the pass button as badukpan.py colours the circle it draws on it.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/katrain_gui.dart';
import '../theme.dart';
import 'board/board_painters.dart';

class BottomBar extends StatelessWidget {
  final KaTrainGui gui;

  /// The pass button's key, so the board can draw a passed stone of a variation next to it.
  final GlobalKey passButtonKey;
  const BottomBar({super.key, required this.gui, required this.passButtonKey});

  @override
  Widget build(BuildContext context) {
    final next = gui.game?.currentNode.nextPlayer ?? 'B';
    Widget nav(IconData icon, String tooltip, VoidCallback onPressed, {Color? color}) => IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: color),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _PassButton(gui: gui, passButtonKey: passButtonKey),
          const Spacer(),
          nav(
            Icons.keyboard_double_arrow_left,
            'Shift+N',
            () => gui.act('find-mistake', ['undo']),
            color: KTheme.mistakeButtonColor,
          ),
          nav(Icons.first_page, 'Home', () => gui.act('undo', [9999])),
          nav(Icons.fast_rewind, 'Shift+←', () => gui.act('undo', [10])),
          nav(Icons.chevron_left, '←', () => gui.act('undo')),
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
          nav(Icons.chevron_right, '→', () => gui.act('redo')),
          nav(Icons.fast_forward, 'Shift+→', () => gui.act('redo', [10])),
          nav(Icons.last_page, 'End', () => gui.act('redo', [9999])),
          nav(
            Icons.keyboard_double_arrow_right,
            'N',
            () => gui.act('find-mistake', ['redo']),
            color: KTheme.mistakeButtonColor,
          ),
          const SizedBox(width: 8),
          nav(Icons.rotate_right, i18n.tr('Rotate'), () => gui.act('rotate')),
          const Spacer(),
          _EngineStatus(gui: gui),
        ],
      ),
    );
  }
}

class _PassButton extends StatelessWidget {
  final KaTrainGui gui;
  final GlobalKey passButtonKey;
  const _PassButton({required this.gui, required this.passButtonKey});

  @override
  Widget build(BuildContext context) {
    Color? policyColor;
    if (gui.game != null && gui.analysisControls['policy']!) {
      final policy = boardPolicy(gui);
      if (policy != null) {
        final movePolicy = policy.last;
        final polOrder = 5 - (-math.log(math.max(1e-9, movePolicy - 1e-9)) / math.ln10).truncate();
        if (polOrder >= 0) {
          policyColor = withAlpha(KTheme.evalColors[trainerConfig(gui)['theme']]![polOrder], KTheme.ghostAlpha);
        }
      }
    }
    return Tooltip(
      message: 'P',
      child: OutlinedButton(
        key: passButtonKey,
        style: policyColor == null ? null : OutlinedButton.styleFrom(backgroundColor: policyColor),
        onPressed: () => gui.act('play', [null]),
        child: Text(i18n.tr('pass-button-text')),
      ),
    );
  }
}

class _EngineStatus extends StatelessWidget {
  final KaTrainGui gui;
  const _EngineStatus({required this.gui});

  @override
  Widget build(BuildContext context) {
    final engine = gui.engine;
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
        onTap: () => gui.setStatus(i18n.tr('ai-ponder'), statusInfo),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 18,
                child: gui.isPondering
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
