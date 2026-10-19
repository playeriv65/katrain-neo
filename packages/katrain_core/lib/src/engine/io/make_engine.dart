// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/remote_engine.py: make_engine.

import '../../config/host_base.dart' show defaultDataFolder;
import '../katago_engine.dart';
import 'local_katago.dart';
import 'remote_katago.dart';

/// An engine for the configured backend (see [resolveEngineBackend]), started; [resourceDir] resolves KaTrain-style
/// `katrain/...` paths and [dataFolder] is KataGo's homeDataDir.
Future<(KataGoEngine, Object)> makeEngine(
  EngineHost host,
  Map<String, dynamic> config, {
  required String resourceDir,
  String dataFolder = defaultDataFolder,
}) async {
  if (resolveEngineBackend(config) == 'remote') {
    final engine = KataGoEngine(host, config, engineType: 'remote');
    final remote = RemoteKataGo(engine);
    await remote.start();
    return (engine, remote);
  }
  final engine = KataGoEngine(host, config);
  final local = LocalKataGo(engine, resourceDir: resourceDir, dataFolder: dataFolder);
  await local.start();
  return (engine, local);
}
