// Choosing and starting the engine for the configured backend.

import '../../config/host_base.dart' show defaultDataFolder;
import '../katago_engine.dart';
import 'local_katago.dart';
import 'remote_katago.dart';

/// An engine for the configured backend (see [resolveEngineBackend]), started; [resourceDir] resolves
/// `katrain/...` paths and [dataFolder] is KataGo's homeDataDir. A local KataGo is made for boards of [boardSize]
/// only (see [LocalKataGo.boardSize]); a remote server or a custom command is as it is.
Future<(KataGoEngine, Object)> makeEngine(
  EngineHost host,
  Map<String, dynamic> config, {
  required String resourceDir,
  String dataFolder = defaultDataFolder,
  (int, int)? boardSize,
}) async {
  if (resolveEngineBackend(config) == 'remote') {
    final engine = KataGoEngine(host, config, engineType: 'remote');
    final remote = RemoteKataGo(engine);
    await remote.start();
    return (engine, remote);
  }
  final engine = KataGoEngine(host, config);
  final custom = resolveEngineBackend(config) == 'custom';
  final local = LocalKataGo(
    engine,
    resourceDir: resourceDir,
    dataFolder: dataFolder,
    boardSize: custom ? null : boardSize,
  );
  await local.start();
  return (engine, local);
}
