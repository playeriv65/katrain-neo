// The menu: who plays each colour, the game and settings actions with their shortcuts, the language, and links to
// the manual and support pages.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/app_controller.dart';
import '../state/dialogs.dart';
import '../theme.dart';

/// The languages offered (Spanish is translated but not offered yet).
const languages = [
  ('en', 'English'),
  ('de', 'Deutsch'),
  ('fr', 'Français'),
  ('ua', 'Українська'),
  ('ru', 'Русский'),
  ('cn', '简体中文'),
  ('tw', '繁體中文'),
  ('ko', '한국어'),
  ('jp', '日本語'),
  ('tr', 'Türkçe'),
];

/// The menu's actions: label key, icon, shortcut, action.
final List<(String, IconData, String, void Function(AppController))> menuItems = [
  ('menu:newgame', Icons.add_box_outlined, 'Ctrl+N', (a) => a.openDialog(AppDialog.newGame)),
  ('menu:save', Icons.save_outlined, 'Ctrl+S', (a) => a.saveGame()),
  ('menu:save-as', Icons.save_as_outlined, 'Ctrl+D', (a) => a.openDialog(AppDialog.saveGameAs)),
  ('menu:load', Icons.folder_open_outlined, 'Ctrl+L', (a) => a.openDialog(AppDialog.loadGame)),
  ('menu:clocksettings', Icons.timer_outlined, 'F5', (a) => a.openDialog(AppDialog.timer)),
  ('menu:teachsettings', Icons.school_outlined, 'F6', (a) => a.openDialog(AppDialog.teacher)),
  ('menu:aisettings', Icons.smart_toy_outlined, 'F7', (a) => a.openDialog(AppDialog.ai)),
  ('menu:settings', Icons.settings_outlined, 'F8', (a) => a.openDialog(AppDialog.settings)),
];

void openUrl(String url) {
  if (Platform.isWindows) {
    Process.run('cmd', ['/c', 'start', '', url]);
  } else if (Platform.isMacOS) {
    Process.run('open', [url]);
  } else {
    Process.run('xdg-open', [url]);
  }
}

class MenuDrawer extends StatelessWidget {
  final AppController app;
  final ValueChanged<String> onLanguage;
  const MenuDrawer({super.key, required this.app, required this.onLanguage});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Drawer(
      width: 420,
      backgroundColor: KTheme.boxBackgroundColor,
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(i18n.tr('menu:playersetup'), style: text.titleMedium),
            ),
            const SizedBox(height: 8),
            PlayerSetupBlock(
              app: app,
              onChanged: (bw, type, subtype) => app.updatePlayer(bw, playerType: type, playerSubtype: subtype),
            ),
            const Divider(height: 32),
            for (final (label, icon, shortcut, action) in menuItems)
              ListTile(
                leading: Icon(icon),
                title: Text(i18n.tr(label)),
                trailing: Text(shortcut, style: text.labelMedium),
                onTap: () {
                  Navigator.of(context).pop();
                  action(app);
                },
              ),
            const Divider(height: 32),
            ListTile(
              leading: const Icon(Icons.translate),
              title: Text(i18n.tr('menu:lang')),
              trailing: DropdownButton<String>(
                value: languages.any((l) => l.$1 == i18n.lang) ? i18n.lang : 'en',
                underline: const SizedBox.shrink(),
                items: [for (final (code, name) in languages) DropdownMenuItem(value: code, child: Text(name))],
                onChanged: (code) => code == null ? null : onLanguage(code),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: Text(i18n.tr('menu:manual')),
              onTap: () => openUrl('$homepage#manual'),
            ),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: Text(i18n.tr('menu:support')),
              onTap: () => openUrl('$homepage#support'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The black and white player setup side by side, with a button to swap them (also in the new game popup).
class PlayerSetupBlock extends StatelessWidget {
  final AppController app;
  final void Function(String bw, String playerType, String playerSubtype) onChanged;

  /// The players to show; the global ones when null.
  final Map<String, (String, String)>? players;
  const PlayerSetupBlock({super.key, required this.app, required this.onChanged, this.players});

  (String, String) _player(String bw) {
    final p = players?[bw];
    if (p != null) return p;
    final info = app.playersInfo[bw]!;
    return (info.playerType, info.playerSubtype);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (final bw in const ['B', 'W'])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _PlayerSetup(
                bw: bw,
                type: _player(bw).$1,
                subtype: _player(bw).$2,
                onChanged: (type, subtype) => onChanged(bw, type, subtype),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              icon: const Icon(Icons.swap_vert),
              onPressed: () {
                final b = _player('B');
                final w = _player('W');
                onChanged('B', w.$1, w.$2);
                onChanged('W', b.$1, b.$2);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerSetup extends StatelessWidget {
  final String bw;
  final String type;
  final String subtype;
  final void Function(String type, String subtype) onChanged;
  const _PlayerSetup({required this.bw, required this.type, required this.subtype, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final subtypes = type == playerAi ? aiStrategiesRecommendedOrder : gameTypes;
    return Row(
      children: [
        CircleAvatar(radius: 14, backgroundColor: KTheme.stoneColors[bw]),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey('$bw-type-$type'),
            initialValue: type,
            isExpanded: true,
            decoration: InputDecoration(labelText: i18n.tr('player:type'), isDense: true),
            items: [for (final t in playerTypes) DropdownMenuItem(value: t, child: Text(i18n.tr(t)))],
            onChanged: (t) {
              if (t == null || t == type) return;
              onChanged(t, t == playerAi ? aiStrategiesRecommendedOrder.first : gameTypes.first);
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<String>(
            key: ValueKey('$bw-$type-$subtype'),
            initialValue: subtypes.contains(subtype) ? subtype : subtypes.first,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: i18n.tr(type == playerAi ? 'aistrategy' : 'gametype'),
              isDense: true,
            ),
            items: [
              for (final s in subtypes)
                DropdownMenuItem(
                  value: s,
                  child: Text(i18n.tr(s), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (s) => s == null ? null : onChanged(type, s),
          ),
        ),
      ],
    );
  }
}
