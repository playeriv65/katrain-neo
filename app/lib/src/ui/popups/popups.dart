// Opens the app's dialogs over the main screen.

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../../state/app_controller.dart';
import '../../state/dialogs.dart';
import 'config_dialog.dart';
import 'engine_files.dart';
import 'files_report.dart';
import 'new_game.dart';
import 'simple_popups.dart';
import 'teacher_ai.dart';

/// Opens dialogs over [context]; the AI does not move while one is open.
class PopupPresenter {
  final AppController app;
  final BuildContext Function() context;
  bool _recoveryOpen = false;
  int _open = 0;
  EngineDownloads? _downloads;
  PopupPresenter(this.app, this.context);

  Future<void> open(AppDialog dialog) async {
    switch (dialog) {
      case AppDialog.newGame:
        await _show(NewGameDialog(app: app));
      case AppDialog.timer:
        await _show(TimerDialog(app: app));
      case AppDialog.teacher:
        await _show(TeacherDialog(app: app));
      case AppDialog.ai:
        await _show(AiDialog(app: app));
      case AppDialog.settings:
        await _showConfig();
      case AppDialog.loadGame:
        await _show(LoadSgfDialog(app: app));
      case AppDialog.saveGameAs:
        _opened(1);
        try {
          await saveGameAs(app);
        } finally {
          _opened(-1);
        }
      case AppDialog.reanalyze:
        await _show(ReAnalyzeGameDialog(app: app));
      case AppDialog.report:
        await _show(GameReportDialog(app: app));
      case AppDialog.tsumegoFrame:
        await _show(TsumegoFrameDialog(app: app));
    }
  }

  /// One engine failure at a time: a second one while the first is shown is only logged.
  Future<void> showEngineFailure(EngineFailure failure) async {
    if (_recoveryOpen) {
      app.log('Not showing engine failure ${failure.message}: one is shown already', outputDebug);
      return;
    }
    _recoveryOpen = true;
    try {
      await _show(EngineRecoveryDialog(app: app, failure: failure, openSettings: () => open(AppDialog.settings)));
    } finally {
      _recoveryOpen = false;
    }
  }

  Future<void> _showConfig() async {
    _downloads ??= await EngineDownloads.load();
    await _show(ConfigDialog(app: app, downloads: _downloads!));
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
      app.updateState();
    }
  }

  void _opened(int change) {
    _open += change;
    app.popupOpen = _open > 0;
  }
}
