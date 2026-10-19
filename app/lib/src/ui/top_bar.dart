// The bar above the board: the menu button, the five display toggles with their shortcut keys, and the analysis
// menu.

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/app_controller.dart';
import '../state/dialogs.dart';

/// The analysis menu: label key, icon, shortcut text, action.
List<(String, IconData, String, void Function(AppController))> analysisMenuItems() => [
  ('analysis:extra', Icons.add_circle_outline, 'A', (a) => a.analyzeExtra('extra')),
  ('analysis:equalize', Icons.balance, 'S', (a) => a.analyzeExtra('equalize')),
  ('analysis:sweep', Icons.grid_on, 'D', (a) => a.analyzeExtra('sweep')),
  ('analysis:alternatives', Icons.alt_route, 'F', (a) => a.analyzeExtra('alternative')),
  ('analysis:region', Icons.crop_free, 'G', (a) => a.selectRegion()),
  ('analysis:reset', Icons.restart_alt, 'Ctrl+H', (a) => a.resetAnalysis()),
  ('analysis:insert', Icons.playlist_add, 'I', (a) => a.insertMode()),
  ('analysis:playtoend', Icons.sports_score, 'L', (a) => a.selfplay('end')),
  ('analysis:game', Icons.manage_search, 'F2', (a) => a.openDialog(AppDialog.reanalyze)),
  ('analysis:report', Icons.analytics_outlined, 'F3', (a) => a.openDialog(AppDialog.report)),
  ('analysis:tsumegoframe', Icons.filter_frames_outlined, 'F10', (a) => a.openDialog(AppDialog.tsumegoFrame)),
  ('analysis:continuous', Icons.all_inclusive, 'Space', (a) => a.toggleContinuousAnalysis()),
  ('analysis:aimove', Icons.smart_toy_outlined, 'Enter', (a) => a.aiMove()),
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
  final AppController app;
  final VoidCallback onMenu;
  const TopBar({super.key, required this.app, required this.onMenu});

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
                          selected: app.analysisControls[key]!,
                          showCheckmark: false,
                          onSelected: key == 'hints' && app.analysisControls['policy']!
                              ? null
                              : (v) => app.setAnalysisControl(key, v),
                        ),
                      ),
                    AnalysisMenu(app: app),
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
  final AppController app;
  const AnalysisMenu({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final (label, icon, shortcut, action) in analysisMenuItems())
          MenuItemButton(
            leadingIcon: Icon(icon),
            trailingIcon: Text(shortcut, style: Theme.of(context).textTheme.labelMedium),
            onPressed: () => action(app),
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
