// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/base_katrain.py:
// KaTrainBase._load_config, and the file format of Kivy's JsonStore (kivy/storage/jsonstore.py, MIT), which KaTrain
// keeps its settings in.

import 'dart:convert';
import 'dart:io';

import '../../constants.dart';
import '../../engine/io/local_katago.dart' show expandUser;
import '../katrain_base.dart';

/// Settings in a JSON file, written like Kivy's JsonStore with `indent=4`: the whole file on every change, in
/// Python's `json.dump` format.
class JsonConfigStore implements ConfigStore {
  final String filename;
  @override
  final Map<String, dynamic> data;

  /// Reads [filename]; a missing file is an empty store, as long as its folder exists.
  JsonConfigStore(this.filename) : data = _load(filename);

  static Map<String, dynamic> _load(String filename) {
    final file = File(filename);
    if (!file.existsSync()) {
      final folder = file.absolute.parent;
      if (!folder.existsSync()) throw FileSystemException("The folder '${folder.path}' doesn't exist!", folder.path);
      return {};
    }
    final text = file.readAsStringSync();
    if (text.isEmpty) return {};
    return jsonDecode(text) as Map<String, dynamic>;
  }

  @override
  void put(String key, Map<String, dynamic> values) {
    data[key] = Map.of(values);
    File(filename).writeAsStringSync(const JsonEncoder.withIndent('    ').convert(data));
  }
}

/// The text KaTrain's own config.json has: its defaults as `json.dumps(indent=4)` and a newline.
String defaultConfigText() => '${const JsonEncoder.withIndent('    ').convert(defaultConfig())}\n';

/// Finds the settings file as KaTrain does: [commandLineFile] when given; otherwise the user's file in [dataFolder],
/// created from the defaults when missing and replaced by them (keeping a backup) when it is older than
/// [configMinVersion] or unreadable. Falls back to the defaults in memory when the user's file cannot be made, or
/// with [forcePackageConfig] (KaTrain then uses its package file, which is never written).
ConfigStore openConfig({
  String? commandLineFile,
  bool forcePackageConfig = false,
  String dataFolder = neoDataFolder,
  void Function(String message, int level)? log,
}) {
  void say(String message, int level) => log?.call(message, level);
  if (commandLineFile != null) {
    final configFile = File(commandLineFile).absolute.path;
    say('Using command line config file $configFile', outputInfo);
    return JsonConfigStore(configFile);
  }
  if (forcePackageConfig) return MemoryConfigStore();
  final userConfigFile = File('${expandUser(dataFolder)}${Platform.pathSeparator}config.json').absolute.path;
  try {
    final file = File(userConfigFile);
    if (!file.existsSync()) {
      say('User config does not exist, creating it', outputDebug);
      final parentDir = file.parent.path;
      say('Creating parent directory if needed: $parentDir', outputDebug);
      file.parent.createSync(recursive: true);
      say('Copying package config to user config $userConfigFile', outputDebug);
      file.writeAsStringSync(defaultConfigText());
      say('Copied package config to local file $userConfigFile', outputInfo);
    } else {
      // user file exists
      String versionStr;
      List<int> version;
      try {
        final general = (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['general'] as Map;
        versionStr = general['version'] as String;
        version = parseVersion(versionStr);
        say('Parsed version: $version', outputDebug);
      } catch (e) {
        // broken file etc
        say('Failed to read version from user config: $e', outputDebug);
        versionStr = '0.0.0';
        version = [0, 0, 0];
      }
      final minVersion = parseVersion(configMinVersion);
      if (compareVersions(version, minVersion) < 0) {
        final backup = '$userConfigFile.$versionStr.backup';
        file.copySync(backup);
        file.writeAsStringSync(defaultConfigText());
        say(
          'Copied package config file to $userConfigFile as user file is outdated or broken '
          '($version<$minVersion). Old version stored as $backup',
          outputInfo,
        );
      }
      say('Using user config file $userConfigFile', outputInfo);
    }
  } catch (e) {
    say('Using package config file (exception $e occurred when finding or creating user config)', outputInfo);
    return MemoryConfigStore();
  }
  return JsonConfigStore(userConfigFile);
}
