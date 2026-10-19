// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/__main__.py: the `_do_*_popup` handlers,
// which open each popup by its message name.

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../../state/katrain_gui.dart';
import 'config_dialog.dart';
import 'engine_files.dart';
import 'files_report.dart';
import 'new_game.dart';
import 'simple_popups.dart';
import 'teacher_ai.dart';

/// Opens KaTrain's popups as dialogs over [context].
class PopupPresenter {
  final KaTrainGui gui;
  final BuildContext Function() context;
  bool _recoveryOpen = false;
  int _open = 0;
  EngineDownloads? _downloads;
  PopupPresenter(this.gui, this.context);

  Future<void> present(String name, List<Object?> args) async {
    switch (name) {
      case 'new-game-popup':
        await _show(NewGameDialog(gui: gui));
      case 'timer-popup':
        await _show(TimerDialog(gui: gui));
      case 'teacher-popup':
        await _show(TeacherDialog(gui: gui));
      case 'ai-popup':
        await _show(AiDialog(gui: gui));
      case 'config-popup':
        await _showConfig();
      case 'analyze-sgf-popup':
        await _show(LoadSgfDialog(gui: gui));
      case 'save-game-as-popup':
        _opened(1);
        try {
          await saveGameAs(gui);
        } finally {
          _opened(-1);
        }
      case 'game-analysis-popup':
        await _show(ReAnalyzeGameDialog(gui: gui));
      case 'report-popup':
        await _show(GameReportDialog(gui: gui));
      case 'tsumego-frame-popup':
        await _show(TsumegoFrameDialog(gui: gui));
      case 'engine-recovery-popup':
        final [message, code, engineType, ...] = [...args, null, null, null];
        if (_recoveryOpen) {
          gui.log('Not opening engine recovery popup with $message as one is already open', outputDebug);
          return;
        }
        _recoveryOpen = true;
        try {
          await _show(
            EngineRecoveryDialog(
              gui: gui,
              errorMessage: '$message',
              code: code,
              engineType: (engineType as String?) ?? 'local',
              openSettings: () => gui.act('config-popup'),
            ),
          );
        } finally {
          _recoveryOpen = false;
        }
      default:
        gui.log('Popup $name is not part of KaTrain Neo', outputError);
    }
  }

  Future<void> _showConfig() async {
    _downloads ??= await EngineDownloads.load();
    await _show(ConfigDialog(gui: gui, downloads: _downloads!));
  }

  /// Shows [dialog]; the AI does not move while a popup is open, and the state is refreshed after it closes.
  Future<void> _show(Widget dialog) async {
    final ctx = context();
    if (!ctx.mounted) return;
    _opened(1);
    try {
      await showDialog<void>(context: ctx, builder: (_) => dialog);
    } finally {
      _opened(-1);
      gui.updateState();
    }
  }

  void _opened(int change) {
    _open += change;
    gui.popupOpen = _open > 0;
  }
}
