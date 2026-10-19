// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/app/popups.py BaseConfigPopup: finding
// KataGo models and programs on disk, and downloading them.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';

import '../../state/app_controller.dart';

/// Where KaTrain's models and KataGo builds can be downloaded from (assets/katago/downloads.json).
class EngineDownloads {
  final Map<String, String> modelEndpoints;
  final Map<String, String> models;
  final Map<String, String> modelDescriptions;
  final Map<String, Map<String, String>> katagos;
  EngineDownloads._(this.modelEndpoints, this.models, this.modelDescriptions, this.katagos);

  static Future<EngineDownloads> load() async {
    final json = jsonDecode(await rootBundle.loadString('assets/katago/downloads.json')) as Map<String, dynamic>;
    Map<String, String> strings(Object? m) => (m as Map).cast<String, String>();
    return EngineDownloads._(
      strings(json['model_endpoints']),
      strings(json['models']),
      strings(json['model_descriptions']),
      {for (final MapEntry(:key, :value) in (json['katagos'] as Map).entries) key as String: strings(value)},
    );
  }

  /// KaTrain's (Kivy's) platform names, which key [katagos].
  static String get platform => Platform.isWindows
      ? 'win'
      : Platform.isLinux
      ? 'linux'
      : Platform.isMacOS
      ? 'macosx'
      : Platform.operatingSystem;
}

/// A file found on disk: how it is shown, and the path stored in the settings.
typedef FoundFile = ({String description, String path});

String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

/// `os.path.split(path)[0]`.
String _dirname(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i < 0 ? '' : path.substring(0, i);
}

/// Finds models and KataGo programs in the folders KaTrain looks in, remembering folders where some were found.
class EngineFileFinder {
  final AppController app;
  final EngineDownloads downloads;
  final List<String> paths;
  final List<String> katagoPaths;
  EngineFileFinder(this.app, this.downloads)
    : paths = [
        app.config('engine/model') as String? ?? '',
        app.config('engine/humanlike_model') as String? ?? '',
        'katrain/models',
        neoDataFolder,
      ],
      katagoPaths = [app.config('engine/katago') as String? ?? '', neoDataFolder];

  String get _package => app.resourceDir.replaceAll('/', Platform.pathSeparator).replaceAll(RegExp(r'[/\\]+$'), '');

  /// The folder of each of [candidates] (or the candidate itself when it is one), once each, with the files in it
  /// whose name matches [matches]; shown with the package folder as `katrain`.
  List<String> _search(List<String> candidates, bool Function(File file) matches) {
    final done = <String>{};
    final files = <String>[];
    for (var path in candidates) {
      path = path.replaceAll(RegExp(r'[/\\]+$'), '');
      if (path.startsWith('katrain')) path = path.replaceFirst('katrain', _package);
      path = expandUser(path);
      if (!Directory(path).existsSync()) path = _dirname(path);
      final slashPath = path.replaceAll(r'\', '/');
      if (done.contains(slashPath) || path.isEmpty || !Directory(path).existsSync()) continue;
      done.add(slashPath);
      final found = [
        for (final entity in Directory(slashPath).listSync())
          if (entity is File && matches(entity))
            entity.path.replaceAll('/', Platform.pathSeparator).replaceFirst(_package, 'katrain'),
      ];
      if (found.isNotEmpty && !paths.contains(path)) paths.add(path); // persistent on paths with models found
      files.addAll(found);
    }
    return files;
  }

  static int _compare(List<Comparable> a, List<Comparable> b) {
    for (var i = 0; i < a.length; i++) {
      final c = a[i].compareTo(b[i]);
      if (c != 0) return c;
    }
    return 0;
  }

  /// `check_models`: all models, and the human-like ones among them, recommended and known ones first.
  (List<FoundFile>, List<FoundFile>) models(String modelPath, String humanlikeModelPath) {
    final distModels = ((app.config('dist_models') as Map?) ?? const {}).cast<String, dynamic>();
    final fileToDesc = <String, String>{
      for (final models in [downloads.models, downloads.modelDescriptions, distModels])
        for (final MapEntry(key: desc, value: url) in models.entries)
          if (RegExp(r'.*/([^/]+)').firstMatch('$url') case final m?) m[1]!.replaceAll('.zip', '.bin.gz'): desc,
    };
    String describe(String path) {
      final desc = fileToDesc[_basename(path)];
      return desc != null ? '$desc  -  $path' : path;
    }

    final distributedTrainingModels = expandUser('$neoDataFolder/katago_contribute/kata1/models');
    final files = _search([
      ...paths,
      modelPath,
      humanlikeModelPath,
      distributedTrainingModels,
    ], (f) => (f.path.endsWith('.bin.gz') || f.path.endsWith('.txt.gz')) && !f.path.contains('.tmp.'));
    List<FoundFile> sorted(
      Iterable<String> files,
    ) => [for (final path in files) (description: describe(path), path: path)]
      ..sort(
        (a, b) => _compare(
          [!a.description.contains('Recommended'), !a.description.contains('  -  '), a.description].map(_key).toList(),
          [!b.description.contains('Recommended'), !b.description.contains('  -  '), b.description].map(_key).toList(),
        ),
      );
    return (sorted(files), sorted(files.where((f) => f.contains('human'))));
  }

  static Comparable _key(Object v) => v is bool ? (v ? 1 : 0) : v as Comparable;

  /// `check_katas`: KataGo programs, known builds first and builds for big boards (bs29) after the others.
  List<FoundFile> katagos(String katagoPath) {
    final fileToDesc = <String, String>{
      for (final builds in downloads.katagos.values)
        for (final MapEntry(key: desc, value: url) in builds.entries)
          RegExp(r'.*/([^/]+)').firstMatch(url)![1]!.replaceAll('.zip', ''): desc,
    };
    String describe(String path) {
      final desc = fileToDesc[_basename(path).replaceAll('.exe', '')];
      return desc != null ? '$desc  -  $path' : path;
    }

    final files = _search([
      ...katagoPaths,
      katagoPath,
    ], (f) => _basename(f.path).startsWith('katago') && !f.path.endsWith('.zip'));
    double key(FoundFile f) => (f.path.contains('bs29') ? 0.1 : 0) - (f.path != f.description ? 1 : 0);
    final found = [for (final path in files) (description: describe(path), path: path)];
    mergeSortBy(found, key);
    return found;
  }
}

/// One download in progress.
class Download extends ChangeNotifier {
  final String name;
  final String url;
  int received = 0;
  int? total;
  String? error;
  bool done = false;
  bool _cancelled = false;
  Download(this.name, this.url);

  double? get progress => total == null || total == 0 ? null : received / total!;

  void cancel() => _cancelled = true;

  /// Downloads to [path] through a `.part` file, then [finish]es it (moving or unpacking).
  Future<void> run(String partPath, Future<void> Function(File part) finish, void Function(String, num) log) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != 200) throw HttpException('status ${response.statusCode}', uri: Uri.parse(url));
      total = response.contentLength >= 0 ? response.contentLength : null;
      final part = File(partPath);
      part.parent.createSync(recursive: true);
      final sink = part.openWrite();
      try {
        await for (final chunk in response) {
          if (_cancelled) throw const HttpException('cancelled');
          sink.add(chunk);
          received += chunk.length;
          notifyListeners();
        }
      } finally {
        await sink.close();
      }
      await finish(part);
      done = true;
    } on Object catch (e) {
      error = '$e';
      log('Download of $name failed or cancelled ($e)', outputError);
    } finally {
      client.close(force: true);
      notifyListeners();
    }
  }
}

/// `_download_models`: asks katagotraining.org for its latest and strongest networks, then downloads every model
/// not yet on disk to the data folder. Returns the started downloads.
Future<List<Download>> downloadModels(
  AppController app,
  EngineDownloads downloads,
  Iterable<FoundFile> present,
  VoidCallback onComplete,
) async {
  final distModels = <String, String>{
    for (final MapEntry(:key, :value) in ((app.config('dist_models') as Map?) ?? const {}).entries)
      if (downloads.modelEndpoints.containsKey(key)) key as String: value as String,
  };
  for (final MapEntry(key: name, value: url) in downloads.modelEndpoints.entries) {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw Exception('Request to $url returned code ${response.statusCode} != 200: $body');
      }
      distModels[name] = (jsonDecode(body) as Map)['model_file'] as String;
    } on Object catch (e) {
      app.log('Failed to retrieve info for model: $e', outputInfo);
    } finally {
      client.close(force: true);
    }
  }
  app.configStore.data['dist_models'] = distModels;
  app.saveConfig('dist_models');

  final names = {for (final f in present) _basename(f.description)};
  final started = <Download>[];
  for (final MapEntry(key: name, value: url) in {...downloads.models, ...distModels}.entries) {
    final filename = url.split('/').last;
    if (names.contains(filename)) continue;
    final savePath = expandUser('$neoDataFolder/$filename');
    app.log('Downloading $name from $url to $savePath.part', outputInfo);
    final download = Download(name, url);
    started.add(download);
    download.run('$savePath.part', (part) async {
      part.renameSync(savePath);
      app.log('Download of $name complete -> $savePath', outputInfo);
      onComplete();
    }, app.log);
  }
  return started;
}

/// `download_katas`: downloads the KataGo builds for this platform not yet on disk, and unpacks the program (and
/// its DLLs) next to the data folder. Null when there are none for this platform.
List<Download>? downloadKatagos(
  AppController app,
  EngineDownloads downloads,
  Iterable<FoundFile> present,
  VoidCallback onComplete,
) {
  final builds = downloads.katagos[EngineDownloads.platform];
  if (builds == null || builds.isEmpty) return null;
  final names = {for (final f in present) _basename(f.description)};
  final started = <Download>[];
  for (final MapEntry(key: name, value: url) in builds.entries) {
    final filename = url.split('/').last;
    final exeName = Platform.isWindows ? filename.replaceAll('.zip', '.exe') : filename.replaceAll('.zip', '');
    if (names.contains(exeName)) continue;
    final zipPath = expandUser('$neoDataFolder/$filename');
    final exePath = expandUser('$neoDataFolder/$exeName');
    app.log('Downloading binary $name from $url to $zipPath', outputInfo);
    final download = Download(name, url);
    started.add(download);
    download.run(zipPath, (zip) async {
      try {
        final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
        final exes = [
          for (final f in archive.files)
            if (f.name.startsWith('katago')) f,
        ];
        if (exes.length != 1) {
          throw FileSystemException(
            'Zip file ${zip.path} does not contain exactly 1 file starting with \'katago\' (contents: ${[for (final f in archive.files) f.name]})',
          );
        }
        File(exePath).writeAsBytesSync(exes.single.content);
        if (!Platform.isWindows) await Process.run('chmod', ['ug+x', exePath]);
        for (final f in archive.files) {
          if (f.name.toLowerCase().endsWith('dll')) {
            try {
              File('${_dirname(exePath)}${Platform.pathSeparator}${f.name}').writeAsBytesSync(f.content);
            } on FileSystemException {
              // a DLL in use by a running KataGo stays as it is
            }
          }
        }
        zip.deleteSync();
        app.log('Download of katago binary $name complete -> $exePath', outputInfo);
      } on Object catch (e) {
        app.log('Download of katago binary $name complete, but could not move file: $e', outputError);
      }
      onComplete();
    }, app.log);
  }
  return started;
}
