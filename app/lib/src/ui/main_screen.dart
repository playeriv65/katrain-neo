// The main window (KaTrain's AppController layout in katrain/app.kv): the board with its bars on the left, the side
// panel on the right (0.4 times the window height wide, as in KaTrain). Zen mode hides the bars, then the panel.

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/app_controller.dart';
import '../state/dialogs.dart';
import 'board/board_images.dart';
import 'board/board_view.dart';
import 'bottom_bar.dart';
import 'menu_drawer.dart';
import 'popups/popups.dart';
import 'side_panel.dart';
import 'top_bar.dart';

class MainScreen extends StatefulWidget {
  final AppController app;
  final BoardImages images;
  const MainScreen({super.key, required this.app, required this.images});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> implements AppScreen {
  final _passButtonKey = GlobalKey();
  final _boardKey = GlobalKey();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final _popups = PopupPresenter(widget.app, () => context);

  @override
  void initState() {
    super.initState();
    widget.app.screen = this;
  }

  @override
  void dispose() {
    if (identical(widget.app.screen, this)) widget.app.screen = null;
    super.dispose();
  }

  @override
  void openDialog(AppDialog dialog) => _popups.open(dialog);

  @override
  void showEngineFailure(EngineFailure failure) => _popups.showEngineFailure(failure);

  @override
  void toggleMenu() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null) return;
    scaffold.isDrawerOpen ? scaffold.closeDrawer() : scaffold.openDrawer();
  }

  /// The pass button in the board's coordinates, for a pass in a variation.
  Rect? _passButtonRect() {
    final box = _passButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final boardBox = _boardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || boardBox == null || !box.hasSize || !boardBox.hasSize) return null;
    return boardBox.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
  }

  void _setLanguage(String lang) {
    final app = widget.app;
    app.log('Switching language to $lang', outputInfo);
    i18n.switchLang(lang);
    (app.config('general') as Map)['lang'] = lang;
    app.saveConfig();
    app.updateState();
    app.setStatus('', statusInfo);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Scaffold(
      key: _scaffoldKey,
      drawer: MenuDrawer(app: app, onLanguage: _setLanguage),
      onDrawerChanged: (open) {
        app.navDrawerOpen = open;
        if (!open) app.updateState(); // ai move etc on nav drawer close
      },
      // KaTrain loads files dropped on the window
      body: DropTarget(
        onDragDone: (details) {
          for (final file in details.files) {
            app.loadSgfFile(file.path);
          }
        },
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) => LayoutBuilder(
            builder: (context, c) {
              final rightWidth = app.zen == 2 ? 0.0 : (c.maxHeight * 0.4).clamp(340.0, 560.0);
              final bars = app.zen == 0;
              return Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        if (bars)
                          SizedBox(
                            height: 56,
                            child: TopBar(app: app, onMenu: () => _scaffoldKey.currentState?.openDrawer()),
                          ),
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: bars ? 0 : 8),
                            child: BoardView(
                              key: _boardKey,
                              app: app,
                              images: widget.images,
                              passButtonRect: _passButtonRect,
                            ),
                          ),
                        ),
                        if (bars)
                          SizedBox(
                            height: 56,
                            child: BottomBar(app: app, passButtonKey: _passButtonKey),
                          ),
                      ],
                    ),
                  ),
                  if (rightWidth > 0)
                    SizedBox(
                      width: rightWidth,
                      child: SidePanel(app: app, images: widget.images),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
