/// The parts of katrain_core that need dart:io: running KataGo as a process or connecting to a remote one, and
/// writing files.
library;

export 'src/engine/io/local_katago.dart';
export 'src/engine/io/make_engine.dart';
export 'src/engine/io/remote_katago.dart';
export 'src/game/io/write_sgf.dart';
