// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/__main__.py: shortcuts,
// _on_keyboard_down, _on_keyboard_up and _single_key_action, with the keys of katrain/gui/theme.py.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/katrain_gui.dart';

typedef _K = LogicalKeyboardKey;

/// The popups whose keys close an open popup instead (KaTrain switches between popups this way).
final _popupKeys = {_K.f2, _K.f3, _K.f5, _K.f6, _K.f7, _K.f8, _K.f9, _K.f10};

/// Keys without Ctrl that run a KaTrain message (`shortcuts`); the analysis toggles are handled apart.
final Map<LogicalKeyboardKey, (String, List<Object?>)> _messages = {
  _K.enter: ('ai-move', []),
  _K.numpadEnter: ('ai-move', []),
  _K.keyA: ('analyze-extra', ['extra']),
  _K.keyS: ('analyze-extra', ['equalize']),
  _K.keyD: ('analyze-extra', ['sweep']),
  _K.keyF: ('analyze-extra', ['alternative']),
  _K.keyG: ('select-box', []),
  _K.keyI: ('insert-mode', []),
  _K.keyP: ('play', [null]),
  _K.keyL: ('selfplay-setup', ['end', null]),
  _K.keyB: ('undo', ['branch']),
  _K.arrowDown: ('switch-branch', [1]),
  _K.arrowUp: ('switch-branch', [-1]),
  _K.f5: ('timer-popup', []),
  _K.f6: ('teacher-popup', []),
  _K.f7: ('ai-popup', []),
  _K.f8: ('config-popup', []),
  _K.escape: ('analyze-extra', ['stop']),
};

final _analysisToggles = {
  _K.keyQ: 'show_children',
  _K.keyW: 'eval',
  _K.keyE: 'hints',
  _K.keyT: 'ownership',
  _K.keyR: 'policy',
};

/// KaTrain's keyboard shortcuts for the main window. Keys typed into a text field (the notes) are left to it.
///
/// It sits above the navigator, so that it sees the keys wherever the focus is, popups included.
class KeyboardShortcuts extends StatefulWidget {
  final KaTrainGui gui;
  final GlobalKey<NavigatorState> navigator;
  final Widget child;
  const KeyboardShortcuts({super.key, required this.gui, required this.navigator, required this.child});

  @override
  State<KeyboardShortcuts> createState() => _KeyboardShortcutsState();
}

class _KeyboardShortcutsState extends State<KeyboardShortcuts> {
  LogicalKeyboardKey? _lastKeyDown;

  KaTrainGui get gui => widget.gui;

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
    if (event is! KeyDownEvent || !gui.popupOpen || !_popupKeys.contains(event.logicalKey)) return false;
    widget.navigator.currentState?.pop();
    return true;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (gui.popupOpen || _textFocused()) return KeyEventResult.ignored;
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
      gui.toggleContinuousAnalysis(quiet: shift);
    } else if (key == _K.keyM) {
      gui.toggleMoveNum();
    } else if (key == _K.keyK) {
      gui.board.toggleCoordinates();
    } else if ((key == _K.pause || key == _K.f15) && !ctrl) {
      gui.setTimerPaused(!gui.timer.paused);
    } else if (key == _K.backquote || key == _K.tilde || key == _K.f12) {
      gui.zen = (gui.zen + 1) % 3;
      gui.refresh();
    } else if (key == _K.arrowLeft || key == _K.keyZ) {
      gui.act('undo', [steps]);
    } else if (key == _K.arrowRight || key == _K.keyX) {
      gui.act('redo', [steps]);
    } else if (key == _K.home) {
      gui.act('undo', [9999]);
    } else if (key == _K.end) {
      gui.act('redo', [9999]);
    } else if (key == _K.pageUp) {
      gui.makeSelectedNodeMainBranch();
    } else if (key == _K.keyN && !ctrl) {
      gui.act('find-mistake', [shift ? 'undo' : 'redo']);
    } else if (key == _K.delete && ctrl) {
      gui.deleteSelectedNode();
    } else if (key == _K.keyC && !ctrl) {
      gui.toggleSelectedNodeCollapse();
    } else if (key == _K.keyH && realCtrl) {
      // Do not treat macOS Cmd-H as Ctrl-H.
      gui.act('reset-analysis');
    } else if (key == _K.keyN && ctrl) {
      gui.act('new-game-popup');
    } else if (key == _K.keyL && ctrl) {
      gui.act('analyze-sgf-popup');
    } else if (key == _K.keyS && ctrl) {
      gui.act('save-game');
    } else if (key == _K.keyD && ctrl) {
      gui.act('save-game-as-popup');
    } else if (key == _K.keyC && ctrl) {
      Clipboard.setData(ClipboardData(text: gui.game!.root.sgf()));
      gui.setStatus(i18n.tr('Copied SGF to clipboard.'), statusInfo);
    } else if (key == _K.keyV && ctrl) {
      _loadSgfFromClipboard();
    } else if (key == _K.keyB && shift) {
      gui.act('undo', ['main-branch']);
    } else if (key == _K.f2) {
      gui.act('game-analysis-popup');
    } else if (key == _K.f10) {
      gui.act('tsumego-frame-popup');
    } else if (key == _K.f3) {
      gui.act('report-popup');
    } else if (!ctrl) {
      final toggle = _analysisToggles[key];
      if (toggle != null) {
        gui.setAnalysisControl(toggle, !(gui.analysisControls[toggle] ?? false));
        return true;
      }
      final message = _messages[key];
      if (message == null) return false;
      gui.act(message.$1, message.$2);
    } else {
      return false;
    }
    return true;
  }

  /// `_single_key_action`: Alt alone opens or closes the menu, Tab alone switches between play and analysis.
  void _singleKeyAction(LogicalKeyboardKey key, LogicalKeyboardKey? lastKeyDown) {
    final normalized = _isAlt(key) ? _K.alt : key;
    if (!mounted || _textFocused() || gui.popupOpen || normalized != lastKeyDown || normalized != _lastKeyDown) return;
    if (normalized == _K.alt) {
      gui.toggleNavDrawer?.call();
    } else if (normalized == _K.tab) {
      gui.switchUiMode();
    }
  }

  /// `load_sgf_from_clipboard`: a game record, or a link to one.
  Future<void> _loadSgfFromClipboard() async {
    var clipboard = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (clipboard.isEmpty) {
      gui.setStatus('Ctrl-V pressed but clipboard is empty.', statusInfo);
      return;
    }
    final url = RegExp(r'https?://[^\s]+').matchAsPrefix(clipboard);
    if (url != null) {
      gui.log('Recognized url: ${url[0]}', outputInfo);
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(Uri.parse(url[0]!))).close();
        clipboard = await response.transform(const Utf8Decoder(allowMalformed: true)).join();
      } on Object catch (e) {
        gui.setStatus(
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
    gui.loadSgfText(clipboard);
  }

  @override
  Widget build(BuildContext context) => Focus(autofocus: true, onKeyEvent: _onKey, child: widget.child);
}
