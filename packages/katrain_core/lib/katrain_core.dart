/// Pure Dart core of KaTrain Neo, ported from KaTrain (https://github.com/sanderland/katrain).
library;

export 'src/config/default_config.dart';
export 'src/config/katrain_base.dart';
export 'src/constants.dart';
export 'src/engine/analysis_engine.dart';
export 'src/engine/katago_engine.dart';
export 'src/game/ai.dart';
export 'src/game/game.dart';
export 'src/game/game_node.dart';
export 'src/game/player.dart';
export 'src/game/tsumego_frame.dart';
export 'src/i18n/i18n.dart';
export 'src/rules/base_game.dart';
export 'src/rules/rulesets.dart';
export 'src/sgf/go_node.dart';
export 'src/sgf/move.dart';
export 'src/sgf/parser.dart';
export 'src/utils/py_format.dart';
export 'src/utils/py_random.dart';
export 'src/utils/py_str_format.dart';
export 'src/utils/utils.dart';

/// Version of the core package.
const coreVersion = '0.1.0';
