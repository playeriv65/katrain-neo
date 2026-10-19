// The main window (KaTrain's KaTrainGui layout in katrain/gui.kv): the board with its bars on the left, the side
// panel on the right (0.4 times the window height wide, as in KaTrain). Zen mode hides the bars, then the panel.

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/katrain_gui.dart';
import 'board/board_images.dart';
import 'board/board_view.dart';
import 'bottom_bar.dart';
import 'menu_drawer.dart';
import 'popups/popups.dart';
import 'side_panel.dart';
import 'top_bar.dart';

class MainScreen extends StatefulWidget {
  final KaTrainGui gui;
  final BoardImages images;
  const MainScreen({super.key, required this.gui, required this.images});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _passButtonKey = GlobalKey();
  final _boardKey = GlobalKey();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final _popups = PopupPresenter(widget.gui, () => context);

  @override
  void initState() {
    super.initState();
    widget.gui.presentPopup = _popups.present;
    widget.gui.toggleNavDrawer = () {
      final scaffold = _scaffoldKey.currentState;
      if (scaffold == null) return;
      scaffold.isDrawerOpen ? scaffold.closeDrawer() : scaffold.openDrawer();
    };
  }

  @override
  void dispose() {
    widget.gui.presentPopup = null;
    widget.gui.toggleNavDrawer = null;
    super.dispose();
  }

  /// The pass button in the board's coordinates, for a pass in a variation.
  Rect? _passButtonRect() {
    final box = _passButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final boardBox = _boardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || boardBox == null || !box.hasSize || !boardBox.hasSize) return null;
    return boardBox.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
  }

  void _setLanguage(String lang) {
    final gui = widget.gui;
    gui.log('Switching language to $lang', outputInfo);
    i18n.switchLang(lang);
    (gui.config('general') as Map)['lang'] = lang;
    gui.saveConfig();
    gui.updateState();
    gui.setStatus('', statusInfo);
  }

  @override
  Widget build(BuildContext context) {
    final gui = widget.gui;
    return Scaffold(
      key: _scaffoldKey,
      drawer: MenuDrawer(gui: gui, onLanguage: _setLanguage),
      onDrawerChanged: (open) {
        gui.navDrawerOpen = open;
        if (!open) gui.updateState(); // ai move etc on nav drawer close
      },
      // KaTrain loads files dropped on the window
      body: DropTarget(
        onDragDone: (details) {
          for (final file in details.files) {
            gui.loadSgfFile(file.path);
          }
        },
        child: ListenableBuilder(
          listenable: gui,
          builder: (context, _) => LayoutBuilder(
            builder: (context, c) {
              final rightWidth = gui.zen == 2 ? 0.0 : (c.maxHeight * 0.4).clamp(340.0, 560.0);
              final bars = gui.zen == 0;
              return Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        if (bars)
                          SizedBox(
                            height: 56,
                            child: TopBar(gui: gui, onMenu: () => _scaffoldKey.currentState?.openDrawer()),
                          ),
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: bars ? 0 : 8),
                            child: BoardView(
                              key: _boardKey,
                              gui: gui,
                              images: widget.images,
                              passButtonRect: _passButtonRect,
                            ),
                          ),
                        ),
                        if (bars)
                          SizedBox(
                            height: 56,
                            child: BottomBar(gui: gui, passButtonKey: _passButtonKey),
                          ),
                      ],
                    ),
                  ),
                  if (rightWidth > 0)
                    SizedBox(
                      width: rightWidth,
                      child: SidePanel(gui: gui, images: widget.images),
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
