// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/base_katrain.py: HostBase
// (settings, logging, players) and parse_version. Reading and writing the settings file is in io/config_file.dart.

import 'dart:convert';

import '../constants.dart';
import '../game/ai.dart';
import '../game/game.dart';
import '../game/player.dart';
import 'default_config.dart';

/// Where KaTrain Neo keeps its settings and KataGo's files. KaTrain uses `~/.katrain`; a separate folder keeps the
/// two programs from overwriting each other's settings.
const defaultDataFolder = '~/.katrain-neo';

/// KaTrain's default settings (a fresh copy).
Map<String, dynamic> defaultConfig() => jsonDecode(defaultConfigJson) as Map<String, dynamic>;

/// `parse_version`: the numbers of a version string, padded to three.
List<int> parseVersion(String s) {
  final parts = [for (final p in s.split('.')) int.parse(p)];
  while (parts.length < 3) {
    parts.add(0);
  }
  return parts;
}

/// Python's comparison of two lists of numbers.
int compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

/// Where the settings live: the sections, and how to store one (KaTrain uses Kivy's JsonStore).
abstract interface class ConfigStore {
  /// The sections by name; the maps are the ones [HostBase] reads and changes.
  Map<String, dynamic> get data;

  /// Replaces a section and saves it.
  void put(String key, Map<String, dynamic> values);
}

/// Settings kept in memory only, e.g. the defaults when no file can be used.
class MemoryConfigStore implements ConfigStore {
  @override
  final Map<String, dynamic> data;

  MemoryConfigStore([Map<String, dynamic>? data]) : data = data ?? defaultConfig();

  @override
  void put(String key, Map<String, dynamic> values) => data[key] = Map.of(values);
}

/// Settings, logging, and players, so other classes like bots who need a host instance can be used without a GUI.
/// The program around a game (the GUI, or a headless runner) adds the rest of [GameHost].
abstract class HostBase implements GameHost {
  int debugLevel;
  @override
  Game? game;
  final ConfigStore configStore;
  late final Map<String, dynamic> _config;
  @override
  final Map<String, Player> playersInfo = {'B': Player('B'), 'W': Player('W')};

  /// Where log lines go; KaTrain prints them.
  void Function(String line) printer = print;

  HostBase(this.configStore, {int? debugLevel}) : debugLevel = debugLevel ?? 0 {
    _config = configStore.data;
    this.debugLevel = debugLevel ?? (config('general/debug_level', outputInfo) as int);
    resetPlayers();
  }

  @override
  void log(String message, [num level = outputInfo]) {
    if (level == outputError) {
      printer('ERROR: $message');
    } else if (debugLevel >= level) {
      printer(message);
    }
  }

  /// Saves one section, or all of them.
  void saveConfig([String? key]) {
    if (key == null) {
      for (final e in _config.entries) {
        configStore.put(e.key, (e.value as Map).cast<String, dynamic>());
      }
    } else {
      configStore.put(key, (_config[key] as Map).cast<String, dynamic>());
    }
  }

  /// A setting such as `game/size`, or a whole section such as `trainer`.
  @override
  Object? config(String setting, [Object? defaultValue]) {
    if (setting.contains('/')) {
      final [cat, key] = setting.split('/');
      final section = _config[cat];
      return section is Map ? (section.containsKey(key) ? section[key] : defaultValue) : defaultValue;
    }
    return _config.containsKey(setting) ? _config[setting] : defaultValue;
  }

  /// Changes who plays [bw]; as in KaTrain, a type or subtype that is not given goes back to its default.
  void updatePlayer(String bw, {String playerType = playerHuman, String playerSubtype = playingNormal}) {
    playersInfo[bw]!.update(playerType, playerSubtype);
    updateCalculatedRanks();
  }

  void updateCalculatedRanks() {
    for (final playerInfo in playersInfo.values) {
      if (playerInfo.playerType == playerAi) {
        final settings = (config('ai/${playerInfo.strategy}') as Map?)?.cast<String, dynamic>();
        playerInfo.calculatedRank = aiRankEstimation(playerInfo.playerSubtype, settings).toDouble();
      } else {
        playerInfo.calculatedRank = null;
      }
    }
  }

  void resetPlayers() {
    updatePlayer('B');
    updatePlayer('W');
    for (final v in playersInfo.values) {
      v.periodsUsed = 0;
    }
  }

  Player get lastPlayerInfo => playersInfo[game!.currentNode.player]!;

  Player get nextPlayerInfo => playersInfo[game!.currentNode.nextPlayer]!;
}
