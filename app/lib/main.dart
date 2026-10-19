// KaTrain Neo: an unofficial Flutter rewrite of KaTrain (https://github.com/sanderland/katrain).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';

import 'src/state/katrain_gui.dart';
import 'src/ui/board/board_images.dart';
import 'src/ui/main_screen.dart';
import 'src/ui/app_theme.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = openConfig(
    commandLineFile: args.where((a) => a.endsWith('config.json')).firstOrNull,
    log: (message, level) {
      if (level <= outputInfo) stdout.writeln(message);
    },
  );
  final resourceDir = await prepareResources();
  final gui = KaTrainGui(store, resourceDir: resourceDir);
  i18n.switchLang((gui.config('general/lang') ?? defaultLanguage) as String);
  final images = await BoardImages.load();
  final sgf = args.where((a) => const ['.sgf', '.ngf', '.gib'].any(a.toLowerCase().endsWith)).firstOrNull;
  runApp(KaTrainNeoApp(gui: gui, images: images));
  await gui.start(sgfFile: sgf != null && File(sgf).existsSync() ? sgf : null);
}

/// KaTrain finds `katrain/...` resources in its package; KaTrain Neo keeps them in its data folder, with KataGo's
/// analysis settings from KaTrain. The KataGo program and model are the user's.
Future<String> prepareResources() async {
  final dir = Directory('${expandUser(neoDataFolder)}${Platform.pathSeparator}package');
  final cfg = File('${dir.path}${Platform.pathSeparator}KataGo${Platform.pathSeparator}analysis_config.cfg');
  if (!cfg.existsSync()) {
    cfg.parent.createSync(recursive: true);
    cfg.writeAsStringSync(await rootBundle.loadString('assets/katago/analysis_config.cfg'));
  }
  return dir.path;
}

class KaTrainNeoApp extends StatelessWidget {
  final KaTrainGui gui;
  final BoardImages images;
  const KaTrainNeoApp({super.key, required this.gui, required this.images});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KaTrain Neo v$coreVersion',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      home: ListenableBuilder(
        listenable: gui,
        builder: (context, _) => gui.game == null ? const Scaffold() : MainScreen(gui: gui, images: images),
      ),
    );
  }
}
