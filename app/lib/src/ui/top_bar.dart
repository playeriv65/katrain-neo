// KaTrain's analysis controls bar (katrain/gui.kv AnalysisControls and AnalysisDropDown): the menu button, the
// five display toggles with their shortcut keys, and the analysis menu.

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/katrain_gui.dart';

/// The analysis menu: label key, icon, shortcut text, action.
List<(String, IconData, String, void Function(KaTrainGui))> analysisMenuItems() => [
  ('analysis:extra', Icons.add_circle_outline, 'A', (g) => g.act('analyze-extra', ['extra'])),
  ('analysis:equalize', Icons.balance, 'S', (g) => g.act('analyze-extra', ['equalize'])),
  ('analysis:sweep', Icons.grid_on, 'D', (g) => g.act('analyze-extra', ['sweep'])),
  ('analysis:alternatives', Icons.alt_route, 'F', (g) => g.act('analyze-extra', ['alternative'])),
  ('analysis:region', Icons.crop_free, 'G', (g) => g.act('select-box')),
  ('analysis:reset', Icons.restart_alt, 'Ctrl+H', (g) => g.act('reset-analysis')),
  ('analysis:insert', Icons.playlist_add, 'I', (g) => g.act('insert-mode')),
  ('analysis:playtoend', Icons.sports_score, 'L', (g) => g.act('selfplay-setup', ['end'])),
  ('analysis:game', Icons.manage_search, 'F2', (g) => g.act('game-analysis-popup')),
  ('analysis:report', Icons.analytics_outlined, 'F3', (g) => g.act('report-popup')),
  ('analysis:tsumegoframe', Icons.filter_frames_outlined, 'F10', (g) => g.act('tsumego-frame-popup')),
  ('analysis:continuous', Icons.all_inclusive, 'Space', (g) => g.toggleContinuousAnalysis()),
  ('analysis:aimove', Icons.smart_toy_outlined, 'Enter', (g) => g.act('ai-move')),
];

/// The display toggles: setting key, label key, shortcut, icon.
const displayToggles = [
  ('show_children', 'analysis:nextmoves', 'Q', Icons.radio_button_unchecked),
  ('eval', 'analysis:dots', 'W', Icons.circle),
  ('hints', 'analysis:topmoves', 'E', Icons.lightbulb_outline),
  ('policy', 'analysis:policy', 'R', Icons.blur_on),
  ('ownership', 'analysis:territory', 'T', Icons.texture),
];

class TopBar extends StatelessWidget {
  final KaTrainGui gui;
  final VoidCallback onMenu;
  const TopBar({super.key, required this.gui, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(tooltip: 'Alt', onPressed: onMenu, icon: const Icon(Icons.menu)),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Center(
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final (key, label, shortcut, icon) in displayToggles)
                      Tooltip(
                        message: shortcut,
                        child: FilterChip(
                          avatar: Icon(icon, size: 16),
                          label: Text(i18n.tr(label).replaceAll('\n', ' ')),
                          selected: gui.analysisControls[key]!,
                          showCheckmark: false,
                          onSelected: key == 'hints' && gui.analysisControls['policy']!
                              ? null
                              : (v) => gui.setAnalysisControl(key, v),
                        ),
                      ),
                    AnalysisMenu(gui: gui),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AnalysisMenu extends StatelessWidget {
  final KaTrainGui gui;
  const AnalysisMenu({super.key, required this.gui});

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final (label, icon, shortcut, action) in analysisMenuItems())
          MenuItemButton(
            leadingIcon: Icon(icon),
            trailingIcon: Text(shortcut, style: Theme.of(context).textTheme.labelMedium),
            onPressed: () => action(gui),
            child: Text(i18n.tr(label)),
          ),
      ],
      builder: (context, controller, _) => FilledButton.tonalIcon(
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.insights),
        label: Text(i18n.tr('btn:Analyze')),
      ),
    );
  }
}
