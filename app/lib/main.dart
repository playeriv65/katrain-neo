// KaTrain Neo: an unofficial Flutter rewrite of KaTrain (https://github.com/sanderland/katrain).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';

import 'src/state/audio_sounds.dart';
import 'src/state/katrain_gui.dart';
import 'src/ui/board/board_images.dart';
import 'src/ui/keyboard.dart';
import 'src/ui/main_screen.dart';
import 'src/ui/app_theme.dart';
import 'src/window.dart';

const appTitle = 'KaTrain Neo v$coreVersion';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = openConfig(
    commandLineFile: args.where((a) => a.endsWith('config.json')).firstOrNull,
    log: (message, level) {
      if (level <= outputInfo) stdout.writeln(message);
    },
  );
  final resourceDir = await prepareResources();
  late final KaTrainGui gui;
  gui = KaTrainGui(store, resourceDir: resourceDir, sounds: AudioSounds(() => gui.config('timer/sound') == true));
  i18n.switchLang((gui.config('general/lang') ?? defaultLanguage) as String);
  final images = await BoardImages.load();
  final sgf = args.where((a) => const ['.sgf', '.ngf', '.gib'].any(a.toLowerCase().endsWith)).firstOrNull;
  runApp(KaTrainNeoApp(gui: gui, images: images));
  await setUpWindow(gui, appTitle);
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

class KaTrainNeoApp extends StatefulWidget {
  final KaTrainGui gui;
  final BoardImages images;
  const KaTrainNeoApp({super.key, required this.gui, required this.images});

  @override
  State<KaTrainNeoApp> createState() => _KaTrainNeoAppState();
}

class _KaTrainNeoAppState extends State<KaTrainNeoApp> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final gui = widget.gui;
    return MaterialApp(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      navigatorKey: _navigator,
      builder: (context, child) => KeyboardShortcuts(gui: gui, navigator: _navigator, child: child!),
      home: ListenableBuilder(
        listenable: gui,
        builder: (context, _) => gui.game == null ? const Scaffold() : MainScreen(gui: gui, images: widget.images),
      ),
    );
  }
}
