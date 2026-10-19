// Finding, creating and upgrading the settings file, and writing it back as indented JSON.

import 'dart:convert';
import 'dart:io';

import '../../constants.dart';
import '../../engine/io/local_katago.dart' show expandUser;
import '../host_base.dart';

/// Settings in a JSON file, indented by four spaces and written whole on every change.
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

/// The defaults as a settings file's text.
String defaultConfigText() => '${const JsonEncoder.withIndent('    ').convert(defaultConfig())}\n';

/// Finds the settings file: [commandLineFile] when given; otherwise the user's file in [dataFolder],
/// created from the defaults when missing and replaced by them (keeping a backup) when it is older than
/// [configMinVersion] or unreadable. Falls back to the defaults in memory when the user's file cannot be made, or
/// with [forcePackageConfig].
ConfigStore openConfig({
  String? commandLineFile,
  bool forcePackageConfig = false,
  String dataFolder = defaultDataFolder,
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
