// Saving a game to an SGF file.

import 'dart:io';

import '../../i18n/i18n.dart';
import '../../utils/template.dart';
import '../game.dart';

/// Saves [game] to [filename] (creating its folder) and returns the status message to show. Line ends are
/// always LF.
String writeSgf(Game game, String filename, {Map<String, dynamic>? trainerConfig}) {
  final sgf = game.sgfToSave(trainerConfig);
  game.sgfFilename = filename;
  final file = File(filename);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(sgf);
  return fillTemplate(i18n.tr('sgf written'), {'file_name': filename});
}
