// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/game.py: BaseGame.write_sgf.

import 'dart:io';

import '../../i18n/i18n.dart';
import '../../utils/template.dart';
import '../game.dart';

/// Saves [game] to [filename] (creating its folder) and returns the status message to show. KaTrain writes in text
/// mode, so its files get CRLF line ends on Windows; these always use LF.
String writeSgf(Game game, String filename, {Map<String, dynamic>? trainerConfig}) {
  final sgf = game.sgfToSave(trainerConfig);
  game.sgfFilename = filename;
  final file = File(filename);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(sgf);
  return fillTemplate(i18n.tr('sgf written'), {'file_name': filename});
}
