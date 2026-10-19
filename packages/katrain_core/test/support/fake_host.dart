// A stand-in for the program around a game (KaTrain's GUI): settings in memory, and a record of what the game asked
// it to show.

import 'package:katrain_core/katrain_core.dart';

/// One call of [GameHost.setStatus].
typedef StatusUpdate = ({String message, num type, GameNode? atNode});

/// One call of [GameHost.log].
typedef LogEntry = ({String message, int level});

/// A [GameHost] with the default settings (or [settings]) that records status messages, logs and redraws.
class FakeHost implements GameHost {
  /// The settings by section, e.g. `settings['game']['size']`.
  final Map<String, dynamic> settings;

  @override
  final Map<String, Player> playersInfo = {'B': Player('B'), 'W': Player('W')};

  @override
  Game? game;

  @override
  bool pondering = false;

  @override
  GameNode? insertNode;

  final List<StatusUpdate> statuses = [];
  final List<LogEntry> logs = [];
  int stateUpdates = 0;
  int boardRedraws = 0;
  int moveTreeRedraws = 0;

  FakeHost([Map<String, dynamic>? settings]) : settings = settings ?? defaultConfig();

  @override
  Object? config(String setting, [Object? defaultValue]) {
    if (setting.contains('/')) {
      final [section, key] = setting.split('/');
      return (settings[section] as Map<String, dynamic>? ?? const {})[key] ?? defaultValue;
    }
    return settings[setting] ?? defaultValue;
  }

  /// Changes one setting, given as `section/key`.
  void setConfig(String setting, Object? value) {
    final [section, key] = setting.split('/');
    (settings.putIfAbsent(section, () => <String, dynamic>{}) as Map<String, dynamic>)[key] = value;
  }

  /// Makes [bw] a human or an AI player; [subtype] is the mode (normal, teaching) or the AI strategy.
  void setPlayer(String bw, String type, [String? subtype]) =>
      playersInfo[bw]!.update(type, subtype ?? (type == playerAi ? aiDefault : playingNormal));

  StatusUpdate? get lastStatus => statuses.isEmpty ? null : statuses.last;

  @override
  void log(String message, int level) => logs.add((message: message, level: level));

  @override
  void setStatus(String message, num statusType, {GameNode? atNode}) =>
      statuses.add((message: message, type: statusType, atNode: atNode));

  @override
  void updateState({bool redrawBoard = false}) {
    stateUpdates += 1;
    if (redrawBoard) boardRedraws += 1;
  }

  @override
  void redrawMoveTree() => moveTreeRedraws += 1;
}
