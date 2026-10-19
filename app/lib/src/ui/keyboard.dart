// The keyboard shortcuts of the main window, and single Alt (menu) and Tab (play/analysis) presses.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/app_controller.dart';
import '../state/dialogs.dart';

typedef _K = LogicalKeyboardKey;

/// The dialogs' keys close an open dialog instead.
final _popupKeys = {_K.f2, _K.f3, _K.f5, _K.f6, _K.f7, _K.f8, _K.f9, _K.f10};

/// What keys without Ctrl do (the analysis toggles are handled apart).
final Map<LogicalKeyboardKey, void Function(AppController)> _actions = {
  _K.enter: (a) => a.aiMove(),
  _K.numpadEnter: (a) => a.aiMove(),
  _K.keyA: (a) => a.analyzeExtra('extra'),
  _K.keyS: (a) => a.analyzeExtra('equalize'),
  _K.keyD: (a) => a.analyzeExtra('sweep'),
  _K.keyF: (a) => a.analyzeExtra('alternative'),
  _K.keyG: (a) => a.selectRegion(),
  _K.keyI: (a) => a.insertMode(),
  _K.keyP: (a) => a.play(null),
  _K.keyL: (a) => a.selfplay('end'),
  _K.keyB: (a) => a.undoTo('branch'),
  _K.arrowDown: (a) => a.nextBranch(1),
  _K.arrowUp: (a) => a.nextBranch(-1),
  _K.f5: (a) => a.openDialog(AppDialog.timer),
  _K.f6: (a) => a.openDialog(AppDialog.teacher),
  _K.f7: (a) => a.openDialog(AppDialog.ai),
  _K.f8: (a) => a.openDialog(AppDialog.settings),
  _K.escape: (a) => a.analyzeExtra('stop'),
};

final _analysisToggles = {
  _K.keyQ: 'show_children',
  _K.keyW: 'eval',
  _K.keyE: 'hints',
  _K.keyT: 'ownership',
  _K.keyR: 'policy',
};

/// The main window's keyboard shortcuts. Keys typed into a text field (the notes) are left to it.
///
/// It sits above the navigator, so that it sees the keys wherever the focus is, popups included.
class KeyboardShortcuts extends StatefulWidget {
  final AppController app;
  final GlobalKey<NavigatorState> navigator;
  final Widget child;
  const KeyboardShortcuts({super.key, required this.app, required this.navigator, required this.child});

  @override
  State<KeyboardShortcuts> createState() => _KeyboardShortcutsState();
}

class _KeyboardShortcutsState extends State<KeyboardShortcuts> {
  LogicalKeyboardKey? _lastKeyDown;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_popupKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_popupKey);
    super.dispose();
  }

  static bool _textFocused() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        (context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  /// With a popup open, the popup keys close it (the dialogs handle Enter and Escape themselves).
  bool _popupKey(KeyEvent event) {
    if (event is! KeyDownEvent || !app.popupOpen || !_popupKeys.contains(event.logicalKey)) return false;
    widget.navigator.currentState?.pop();
    return true;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (app.popupOpen || _textFocused()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (_isAlt(key) || key == _K.tab) {
        final down = _lastKeyDown;
        Timer(const Duration(milliseconds: 50), () => _singleKeyAction(key, down));
        return key == _K.tab ? KeyEventResult.handled : KeyEventResult.ignored;
      }
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _lastKeyDown = _isAlt(key) ? _K.alt : key;
    if (key == _K.tab) return KeyEventResult.handled; // no focus traversal: Tab switches modes
    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed || (keyboard.isMetaPressed && Platform.isMacOS);
    final shift = keyboard.isShiftPressed;
    return _keyDown(key, ctrl: ctrl, shift: shift, realCtrl: keyboard.isControlPressed)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  static bool _isAlt(LogicalKeyboardKey key) => key == _K.altLeft || key == _K.altRight || key == _K.alt;

  /// `_on_keyboard_down`; false for keys it does nothing with.
  bool _keyDown(LogicalKeyboardKey key, {required bool ctrl, required bool shift, required bool realCtrl}) {
    final steps = 1 + (shift ? 9 : 0) + (ctrl ? 9999 : 0);
    if (key == _K.space) {
      app.toggleContinuousAnalysis(quiet: shift);
    } else if (key == _K.keyM) {
      app.toggleMoveNum();
    } else if (key == _K.keyK) {
      app.board.toggleCoordinates();
    } else if ((key == _K.pause || key == _K.f15) && !ctrl) {
      app.clock.paused = !app.clock.paused;
    } else if (key == _K.backquote || key == _K.tilde || key == _K.f12) {
      app.zen = (app.zen + 1) % 3;
      app.refresh();
    } else if (key == _K.arrowLeft || key == _K.keyZ) {
      app.undo(steps);
    } else if (key == _K.arrowRight || key == _K.keyX) {
      app.redo(steps);
    } else if (key == _K.home) {
      app.undo(9999);
    } else if (key == _K.end) {
      app.redo(9999);
    } else if (key == _K.pageUp) {
      app.makeSelectedNodeMainBranch();
    } else if (key == _K.keyN && !ctrl) {
      app.findMistake(backwards: shift);
    } else if (key == _K.delete && ctrl) {
      app.deleteSelectedNode();
    } else if (key == _K.keyC && !ctrl) {
      app.toggleSelectedNodeCollapse();
    } else if (key == _K.keyH && realCtrl) {
      // Do not treat macOS Cmd-H as Ctrl-H.
      app.resetAnalysis();
    } else if (key == _K.keyN && ctrl) {
      app.openDialog(AppDialog.newGame);
    } else if (key == _K.keyL && ctrl) {
      app.openDialog(AppDialog.loadGame);
    } else if (key == _K.keyS && ctrl) {
      app.saveGame();
    } else if (key == _K.keyD && ctrl) {
      app.openDialog(AppDialog.saveGameAs);
    } else if (key == _K.keyC && ctrl) {
      Clipboard.setData(ClipboardData(text: app.game!.root.sgf()));
      app.setStatus(i18n.tr('Copied SGF to clipboard.'), statusInfo);
    } else if (key == _K.keyV && ctrl) {
      _loadSgfFromClipboard();
    } else if (key == _K.keyB && shift) {
      app.undoTo('main-branch');
    } else if (key == _K.f2) {
      app.openDialog(AppDialog.reanalyze);
    } else if (key == _K.f10) {
      app.openDialog(AppDialog.tsumegoFrame);
    } else if (key == _K.f3) {
      app.openDialog(AppDialog.report);
    } else if (!ctrl) {
      final toggle = _analysisToggles[key];
      if (toggle != null) {
        app.setAnalysisControl(toggle, !(app.analysisControls[toggle] ?? false));
        return true;
      }
      final action = _actions[key];
      if (action == null) return false;
      action(app);
    } else {
      return false;
    }
    return true;
  }

  /// `_single_key_action`: Alt alone opens or closes the menu, Tab alone switches between play and analysis.
  void _singleKeyAction(LogicalKeyboardKey key, LogicalKeyboardKey? lastKeyDown) {
    final normalized = _isAlt(key) ? _K.alt : key;
    if (!mounted || _textFocused() || app.popupOpen || normalized != lastKeyDown || normalized != _lastKeyDown) return;
    if (normalized == _K.alt) {
      app.toggleMenu();
    } else if (normalized == _K.tab) {
      app.switchUiMode();
    }
  }

  /// `load_sgf_from_clipboard`: a game record, or a link to one.
  Future<void> _loadSgfFromClipboard() async {
    var clipboard = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (clipboard.isEmpty) {
      app.setStatus('Ctrl-V pressed but clipboard is empty.', statusInfo);
      return;
    }
    final url = RegExp(r'https?://[^\s]+').matchAsPrefix(clipboard);
    if (url != null) {
      app.log('Recognized url: ${url[0]}', outputInfo);
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(Uri.parse(url[0]!))).close();
        clipboard = await response.transform(const Utf8Decoder(allowMalformed: true)).join();
      } on Object catch (e) {
        app.setStatus(
          pyFormat(i18n.tr('Failed to import from clipboard'), {
            'error': e,
            'contents': clipboard.substring(0, clipboard.length < 50 ? clipboard.length : 50),
          }),
          statusInfo,
        );
        return;
      } finally {
        client.close(force: true);
      }
    }
    app.loadSgfText(clipboard);
  }

  @override
  Widget build(BuildContext context) => Focus(autofocus: true, onKeyEvent: _onKey, child: widget.child);
}
