// KaTrain Neo: review Go games with KataGo, play against AIs of any strength, and learn from your mistakes.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:katrain_core/api.dart';
import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';

import 'src/state/api_host.dart';
import 'src/state/audio_sounds.dart';
import 'src/state/app_controller.dart';
import 'src/ui/board/board_images.dart';
import 'src/ui/keyboard.dart';
import 'src/ui/main_screen.dart';
import 'src/ui/app_theme.dart';
import 'src/window.dart';

const appTitle = 'KaTrain Neo v$appVersion';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = openConfig(
    commandLineFile: args.where((a) => a.endsWith('config.json')).firstOrNull,
    log: (message, level) {
      if (level <= outputInfo) stdout.writeln(message);
    },
  );
  final resourceDir = await prepareResources();
  late final AppController app;
  app = AppController(store, resourceDir: resourceDir, sounds: AudioSounds(() => app.config('timer/sound') == true));
  i18n.switchLang((app.config('general/lang') ?? defaultLanguage) as String);
  final images = await BoardImages.load();
  final sgf = args.where((a) => const ['.sgf', '.ngf', '.gib'].any(a.toLowerCase().endsWith)).firstOrNull;
  runApp(KaTrainNeoApp(app: app, images: images));
  await setUpWindow(app, appTitle);
  await app.start(sgfFile: sgf != null && File(sgf).existsSync() ? sgf : null);
  // the local API for the katrain-neo command (and the agents driving it)
  final api = await startApiServer(
    CommandHandler(AppApiHost(app), app.apiState),
    config: app.config,
    version: appVersion,
    log: app.log,
  );
  onWindowClose(() async => api?.stop());
}

/// Settings name packaged resources as `katrain/...`; they live in the data folder, with KataGo's analysis settings.
/// The KataGo program and model are the user's.
Future<String> prepareResources() async {
  final dir = Directory('${expandUser(defaultDataFolder)}${Platform.pathSeparator}package');
  final cfg = File('${dir.path}${Platform.pathSeparator}KataGo${Platform.pathSeparator}analysis_config.cfg');
  if (!cfg.existsSync()) {
    cfg.parent.createSync(recursive: true);
    cfg.writeAsStringSync(await rootBundle.loadString('assets/katago/analysis_config.cfg'));
  }
  return dir.path;
}

class KaTrainNeoApp extends StatefulWidget {
  final AppController app;
  final BoardImages images;
  const KaTrainNeoApp({super.key, required this.app, required this.images});

  @override
  State<KaTrainNeoApp> createState() => _KaTrainNeoAppState();
}

class _KaTrainNeoAppState extends State<KaTrainNeoApp> {
  final _navigator = GlobalKey<NavigatorState>();

  // the fonts depend on the language
  void _onLanguage(I18n _) => setState(() {});

  @override
  void initState() {
    super.initState();
    i18n.addListener(_onLanguage);
  }

  @override
  void dispose() {
    i18n.removeListener(_onLanguage);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return MaterialApp(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      theme: appTheme(lang: i18n.lang, brightness: Brightness.light),
      darkTheme: appTheme(lang: i18n.lang, brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      locale: appLocales[i18n.lang],
      supportedLocales: appLocales.values,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      navigatorKey: _navigator,
      builder: (context, child) => KeyboardShortcuts(app: app, navigator: _navigator, child: child!),
      home: ListenableBuilder(
        listenable: app,
        builder: (context, _) => app.game == null ? const Scaffold() : MainScreen(app: app, images: widget.images),
      ),
    );
  }
}
