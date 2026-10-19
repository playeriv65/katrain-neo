// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/gui/popups.py and popups.kv: NewGamePopup.

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../../state/katrain_gui.dart';
import '../menu_drawer.dart' show PlayerSetupBlock;
import 'config_editor.dart';

/// Starts a new game, a game from a position set up by self-play, or edits the current game's players and rules.
class NewGameDialog extends StatefulWidget {
  final KaTrainGui gui;
  const NewGameDialog({super.key, required this.gui});

  @override
  State<NewGameDialog> createState() => _NewGameDialogState();
}

class _NewGameDialogState extends State<NewGameDialog> {
  late final gui = widget.gui;
  late final editor = ConfigEditor(gui);
  String mode = 'newgame';
  late final players = {
    for (final MapEntry(:key, :value) in gui.playersInfo.entries) key: (value.playerType, value.playerSubtype),
  };
  final names = {'B': TextEditingController(), 'W': TextEditingController()};
  late final komi = TextEditingController(text: pyStr(gui.game!.root.komi));
  late final size = TextEditingController(text: pyStr(editor.value('game/size')));
  late final handicap = TextEditingController(text: pyStr(editor.value('game/handicap')));
  late String rules = _normalizedRules() ?? editor.value('game/rules') as String;
  late bool clearCache = editor.value('game/clear_cache') == true;

  @override
  void initState() {
    super.initState();
    editor.field('game/rules', () => rules);
    editor.field('game/komi', () => _parse(komi, 'game/komi', double.parse));
    editor.field('game/size', () => size.text);
    editor.field('game/handicap', () => _parse(handicap, 'game/handicap', (t) => int.parse(t.isEmpty ? '0' : t)));
    editor.field('game/clear_cache', () => clearCache);
  }

  @override
  void dispose() {
    for (final c in [...names.values, komi, size, handicap]) {
      c.dispose();
    }
    super.dispose();
  }

  Object _parse(TextEditingController c, String key, Object Function(String) parse) {
    try {
      return parse(c.text.trim().isEmpty && key == 'game/komi' ? '0.0' : c.text.trim());
    } on FormatException catch (e) {
      throw InputParseError("Could not parse value '${c.text}' for $key: $e");
    }
  }

  String? _normalizedRules() {
    final ruleset = gui.game!.root.getProperty('RU', 'japanese')!.trim().toLowerCase();
    for (final (abbr, name) in rulesetsAbbr) {
      if (abbr == ruleset || name == ruleset) return name;
    }
    return null;
  }

  /// `update_playername`: the current names when editing the game, and empty fields otherwise.
  void _setMode(String newMode) {
    setState(() => mode = newMode);
    for (final bw in const ['B', 'W']) {
      final name = gui.game!.root.getProperty('P$bw');
      if (name != null && name.isNotEmpty && !name.contains(sgfInternalCommentsMarker)) {
        names[bw]!.text = mode == 'editgame' ? name : '';
      }
    }
  }

  void _updatePlayerInfo() {
    for (final bw in const ['B', 'W']) {
      final name = names[bw]!.text;
      if (name.isNotEmpty) {
        gui.game!.root.setProperty('P$bw', name);
      } else {
        gui.game!.root.clearProperty('P$bw');
      }
      gui.updatePlayer(bw, playerType: players[bw]!.$1, playerSubtype: players[bw]!.$2);
    }
  }

  void _submit() {
    final Map<String, Object?> props;
    try {
      editor.updateConfig();
      props = editor.collect();
    } on InputParseError catch (e) {
      gui.setStatus('$e', statusError);
      return;
    }
    Navigator.of(context).pop();
    gui.log('Mode: $mode, settings: ${pyStr(gui.config('game'))}', outputDebug);
    _updatePlayerInfo(); // type
    if (mode == 'newgame') {
      if (clearCache) {
        gui.log('Restarting Engine', outputDebug);
        gui.restartEngine().then((_) {
          gui.doNewGame();
          _updatePlayerInfo(); // name
        });
        return;
      }
      gui.doNewGame();
    } else if (mode == 'editgame') {
      final root = gui.game!.root;
      var changed = false;
      for (final (k, current, value) in [
        ('RU', _normalizedRules(), props['game/rules']),
        ('KM', root.komi, props['game/komi']),
      ]) {
        if (current != value) {
          changed = true;
          gui.log(
            'Property $k changed from ${pyStr(current)} to ${pyStr(value)}, triggering re-analysis of entire game.',
            outputInfo,
          );
          root.setProperty(k, value);
        }
      }
      if (changed) {
        gui.engine!.onNewGame();
        gui.game!.analyzeAllNodes(analyzeFast: true);
      }
    } else {
      gui.doNewGame();
      gui.act('selfplay-setup', [props['game/setup_move'], props['game/setup_advantage']]);
    }
    _updatePlayerInfo(); // name
  }

  Widget _quick(TextEditingController target, List<String> values, [void Function(String)? also]) => Wrap(
    spacing: 4,
    children: [
      for (final v in values)
        ActionChip(
          label: Text(v),
          onPressed: () => setState(() {
            target.text = v;
            also?.call(v);
          }),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget row(String label, Widget input, [Widget? extra]) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 150, child: Text(i18n.tr(label), style: text.bodyMedium)),
          Expanded(child: input),
          if (extra != null) ...[const SizedBox(width: 12), extra],
        ],
      ),
    );
    return SettingsDialog(
      title: i18n.tr('New Game title'),
      actionLabel: i18n.tr(mode),
      onAction: _submit,
      width: 640,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            segments: [
              for (final m in const ['newgame', 'setupposition', 'editgame'])
                ButtonSegment(value: m, label: Text(i18n.tr(m))),
            ],
            selected: {mode},
            onSelectionChanged: (s) => _setMode(s.first),
          ),
          const SizedBox(height: 12),
          PlayerSetupBlock(
            gui: gui,
            players: players,
            onChanged: (bw, type, subtype) => setState(() => players[bw] = (type, subtype)),
          ),
          row(
            'player names',
            Row(
              children: [
                for (final (bw, hint) in const [('B', 'black player name hint'), ('W', 'white player name hint')]) ...[
                  Expanded(
                    child: TextField(
                      controller: names[bw],
                      decoration: InputDecoration(hintText: i18n.tr(hint), isDense: true),
                    ),
                  ),
                  if (bw == 'B') const SizedBox(width: 12),
                ],
              ],
            ),
          ),
          row(
            'ruleset',
            DropdownButtonFormField<String>(
              initialValue: rules,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: [for (final (_, name) in rulesetsAbbr) DropdownMenuItem(value: name, child: Text(i18n.tr(name)))],
              onChanged: (v) => rules = v ?? rules,
            ),
          ),
          row(
            'komi',
            TextField(controller: komi, decoration: const InputDecoration(isDense: true)),
            _quick(komi, const ['0.5', '6.5', '7.5']),
          ),
          if (mode != 'editgame') ...[
            row(
              'board size',
              TextField(
                controller: size,
                decoration: InputDecoration(hintText: i18n.tr('non square board hint'), isDense: true),
              ),
              _quick(size, const ['9', '13', '19']),
            ),
            row(
              'handicap',
              TextField(controller: handicap, decoration: const InputDecoration(isDense: true)),
              _quick(handicap, const ['0', '2', '9'], (v) => komi.text = v == '0' ? '6.5' : '0.5'),
            ),
          ],
          if (mode == 'newgame')
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(i18n.tr('clear cache')),
              subtitle: Text(i18n.tr('avoids replaying')),
              value: clearCache,
              onChanged: (v) => setState(() => clearCache = v),
            ),
          // Kept mounted in every mode: KaTrain stores these settings whichever mode is used.
          Offstage(
            offstage: mode != 'setupposition',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Text(i18n.tr('setup position explanation'), style: text.bodySmall),
                row(
                  'setup position black score',
                  SelectionSliderField(
                    values: [for (var pt = -150; pt <= 150; pt++) (pt, '$pt')],
                    initial: editor.value('game/setup_advantage'),
                    keyOption: true,
                    register: (read) => editor.field('game/setup_advantage', read),
                  ),
                ),
                row(
                  'setup position move number',
                  SelectionSliderField(
                    values: [for (var mv = 50; mv <= 250; mv++) (mv, '$mv')],
                    initial: editor.value('game/setup_move'),
                    keyOption: true,
                    register: (read) => editor.field('game/setup_move', read),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
