/// The parts of katrain_core that need dart:io: running KataGo as a process or connecting to a remote one, and
/// reading and writing files (games, settings).
library;

export 'src/config/io/config_file.dart';
export 'src/engine/io/local_katago.dart';
export 'src/engine/io/make_engine.dart';
export 'src/engine/io/remote_katago.dart';
export 'src/game/io/write_sgf.dart';
