// The dialogs the controller asks the screen to open.

/// The dialogs of the app.
enum AppDialog { newGame, loadGame, saveGameAs, timer, teacher, ai, settings, reanalyze, report, tsumegoFrame }

/// The engine failed to start or stopped working.
class EngineFailure {
  final String message;
  final Object? code;

  /// `local` or `remote`, for the advice to give.
  final String engineType;
  const EngineFailure(this.message, this.code, this.engineType);
}

/// What the screen does for the controller: open dialogs and the menu.
abstract interface class AppScreen {
  void openDialog(AppDialog dialog);
  void showEngineFailure(EngineFailure failure);
  void toggleMenu();
}
