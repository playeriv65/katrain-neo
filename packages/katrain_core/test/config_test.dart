// Settings: KaTrain's defaults, finding and upgrading the settings file as KaTrain does, saving in the format of
// Kivy's JsonStore, and players with their AI ranks (katrain/core/base_katrain.py).

import 'dart:convert';
import 'dart:io';

import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

/// KaTrainBase without a GUI.
class Headless extends KaTrainBase {
  final List<String> lines = [];

  Headless(super.configStore, {super.debugLevel}) {
    printer = lines.add;
  }

  @override
  set pondering(bool value) {}

  @override
  void setStatus(String message, num statusType, {GameNode? atNode}) {}

  @override
  void updateState({bool redrawBoard = false}) {}

  @override
  set insertNode(GameNode? node) {}

  @override
  void redrawMoveTree() {}
}

void main() {
  late Directory tmp;
  late String folder;
  late File configFile;
  final logs = <(String, int)>[];
  void log(String message, int level) => logs.add((message, level));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('katrain_neo_config');
    folder = '${tmp.path}${Platform.pathSeparator}data';
    configFile = File('$folder${Platform.pathSeparator}config.json');
    logs.clear();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test("the defaults are KaTrain's config.json, which is in json.dump format", () {
    expect((defaultConfig()['general'] as Map)['version'], version);
    expect(defaultConfigText(), defaultConfigJson);
  });

  test('a missing settings file is created from the defaults', () {
    final store = openConfig(dataFolder: folder, log: log);
    expect(configFile.readAsStringSync(), defaultConfigJson);
    expect(store.data, defaultConfig());
    expect(logs.map((l) => l.$1), contains('Copied package config to local file ${configFile.absolute.path}'));
  });

  test('an outdated or broken file is replaced, with a backup', () {
    configFile.parent.createSync(recursive: true);
    for (final (content, versionText) in [('{"general": {"version": "1.2.3"}}', '1.2.3'), ('{broken', '0.0.0')]) {
      configFile.writeAsStringSync(content);
      openConfig(dataFolder: folder, log: log);
      expect(configFile.readAsStringSync(), defaultConfigJson);
      expect(File('${configFile.absolute.path}.$versionText.backup').readAsStringSync(), content);
    }
    expect(
      logs.map((l) => l.$1),
      contains(
        'Copied package config file to ${configFile.absolute.path} as user file is outdated or broken '
        '([1, 2, 3]<[1, 20, 0]). Old version stored as ${configFile.absolute.path}.1.2.3.backup',
      ),
    );
  });

  test('a current file is used as it is, and saving writes it like JsonStore', () {
    configFile.parent.createSync(recursive: true);
    final settings = defaultConfig();
    (settings['general'] as Map)['lang'] = 'cn';
    configFile.writeAsStringSync(jsonEncode(settings));
    final katrain = Headless(openConfig(dataFolder: folder));
    expect(katrain.config('general/lang'), 'cn');
    expect(katrain.config('general/missing', 42), 42);
    expect(katrain.config('nosection/key'), isNull);
    expect((katrain.config('trainer') as Map)['eval_thresholds'], [12, 6, 3, 1.5, 0.5, 0]);
    (katrain.config('game') as Map)['komi'] = 7.5;
    katrain.saveConfig('game');
    (settings['game'] as Map)['komi'] = 7.5;
    expect(configFile.readAsStringSync(), pyJsonDumps(settings, indent: 4));
  });

  test('a command line file, and the defaults without a file', () {
    final cmd = File('${tmp.path}${Platform.pathSeparator}my_config.json')..writeAsStringSync('{"general": {}}');
    expect(openConfig(commandLineFile: cmd.path, log: log).data, {'general': <String, dynamic>{}});
    final memory = openConfig(forcePackageConfig: true);
    memory.put('general', {'lang': 'fr'});
    expect(memory.data['general'], {'lang': 'fr'});
    expect(configFile.existsSync(), isFalse);
  });

  test('players, AI ranks and logging', () {
    final katrain = Headless(MemoryConfigStore());
    expect(katrain.debugLevel, 0);
    expect(katrain.playersInfo['B']!.human, isTrue);
    katrain.updatePlayer('W', playerType: playerAi, playerSubtype: aiPick);
    final ai = katrain.playersInfo['W']!;
    expect(ai.strategy, aiPick);
    expect(ai.calculatedRank, closeTo(-4.2487, 1e-4)); // as in ai.json
    katrain.updatePlayer('B', playerType: playerHuman, playerSubtype: playingTeaching);
    expect(katrain.playersInfo['B']!.beingTaught, isTrue);
    expect(katrain.playersInfo['B']!.calculatedRank, isNull);
    katrain.updatePlayer('B'); // a subtype that is not given goes back to normal, as in KaTrain
    expect(katrain.playersInfo['B']!.playerSubtype, playingNormal);
    katrain.log('shown');
    katrain.log('hidden', outputDebug);
    katrain.log('bad', outputError);
    expect(katrain.lines, ['shown', 'ERROR: bad']);
    katrain.resetPlayers();
    expect(katrain.playersInfo['W']!.human, isTrue);
  });
}
