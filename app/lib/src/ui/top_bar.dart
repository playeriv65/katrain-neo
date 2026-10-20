// The bar above the board: the menu button, the five display toggles with their shortcut keys, and the analysis
// menu.

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/app_controller.dart';
import '../state/dialogs.dart';
import 'app_theme.dart' show oneLine;

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

  static const _spacing = 8.0;

  /// Room a labelled toggle takes besides its label: padding, the icon and the border.
  static const _chipChrome = 56.0;

  /// Room kept free so that the estimate errs towards icons.
  static const _margin = 16.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.chipTheme.labelStyle ?? theme.textTheme.labelLarge!;
    final scaler = MediaQuery.textScalerOf(context);
    double width(String text) => (TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout()).width;
    final labels = [for (final (_, label, _, _) in displayToggles) oneLine(i18n.tr(label))];
    final menuLabel = i18n.tr('btn:Analyze');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '${MaterialLocalizations.of(context).openAppDrawerTooltip} (Alt)',
            onPressed: onMenu,
            icon: const Icon(Icons.menu),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // labels while everything fits, else icons with the label as tooltip
                final menuWidth = width(menuLabel) + _chipChrome + 8;
                final labelled =
                    labels.map((l) => width(l) + _chipChrome + _spacing).fold(0.0, (a, b) => a + b) + menuWidth;
                final showLabels = labelled + _margin <= constraints.maxWidth;
                final compactMenu =
                    !showLabels && displayToggles.length * (40 + _spacing) + menuWidth + _margin > constraints.maxWidth;
                // the estimate is close, not exact: a row a pixel too wide is scaled down rather than cut
                return Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: _spacing,
                      children: [
                        for (final (i, (key, _, shortcut, icon)) in displayToggles.indexed)
                          _toggle(key, labels[i], shortcut, icon, showLabels),
                        AnalysisMenu(app: app, compact: compactMenu),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggle(String key, String label, String shortcut, IconData icon, bool showLabel) {
    final selected = app.analysisControls[key]!;
    final onChanged = key == 'hints' && app.analysisControls['policy']!
        ? null
        : (bool v) => app.setAnalysisControl(key, v);
    if (!showLabel) {
      return IconButton.outlined(
        tooltip: '$label ($shortcut)',
        isSelected: selected,
        icon: Icon(icon, size: 18),
        onPressed: onChanged == null ? null : () => onChanged(!selected),
      );
    }
    return Tooltip(
      message: shortcut,
      child: FilterChip(
        avatar: Icon(icon, size: 16),
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        onSelected: onChanged,
      ),
    );
  }
}

class AnalysisMenu extends StatelessWidget {
  final AppController app;

  /// Only the icon, with the label as tooltip.
  final bool compact;
  const AnalysisMenu({super.key, required this.app, this.compact = false});

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
      builder: (context, controller, _) {
        void toggle() => controller.isOpen ? controller.close() : controller.open();
        if (compact) {
          return IconButton.filledTonal(
            tooltip: i18n.tr('btn:Analyze'),
            onPressed: toggle,
            icon: const Icon(Icons.insights),
          );
        }
        return FilledButton.tonalIcon(
          onPressed: toggle,
          icon: const Icon(Icons.insights),
          label: Text(i18n.tr('btn:Analyze')),
        );
      },
    );
  }
}
