// Loading and saving games with the system's file dialogs, and the game report.

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';

import '../../state/app_controller.dart';
import '../../theme.dart';
import '../side_panel.dart' show PlayerCard;
import 'config_editor.dart';

const _sgfTypes = [
  XTypeGroup(label: 'SGF', extensions: ['sgf', 'gib', 'ngf']),
];

String? _existingDir(Object? setting) {
  final dir = File(expandUser('${setting ?? '.'}')).absolute.path;
  return Directory(dir).existsSync() ? dir : null;
}

/// `os.path.split(path)`.
(String, String) _split(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i < 0 ? ('', path) : (path.substring(0, i), path.substring(i + 1));
}

/// Picks an SGF (or NGF, GIB) file to analyse, with whether to analyse it fast and to start at its first move.
class LoadSgfDialog extends StatefulWidget {
  final AppController app;
  const LoadSgfDialog({super.key, required this.app});

  @override
  State<LoadSgfDialog> createState() => _LoadSgfDialogState();
}

class _LoadSgfDialogState extends State<LoadSgfDialog> {
  late final app = widget.app;
  late final editor = ConfigEditor(app);
  late bool fast = editor.value('general/load_fast_analysis') == true;
  late bool rewind = editor.value('general/load_sgf_rewind') == true;

  Future<void> _choose() async {
    final file = await openFile(
      acceptedTypeGroups: _sgfTypes,
      initialDirectory: _existingDir(app.config('general/sgf_load')),
    );
    if (file == null || !mounted) return;
    Navigator.of(context).pop();
    final (path, _) = _split(file.path);
    if (path != app.config('general/sgf_load')) {
      app.log('Updating sgf load path default to $path', outputDebug);
      (app.configStore.data['general'] as Map)['sgf_load'] = path;
    }
    editor
      ..field('general/load_fast_analysis', () => fast)
      ..field('general/load_sgf_rewind', () => rewind)
      ..updateConfig(saveToFile: false);
    app.saveConfig('general');
    app.loadSgfFile(file.path, fast: fast, rewind: rewind);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDialog(
      title: i18n.tr('load sgf title'),
      actionLabel: 'Load File',
      onAction: _choose,
      width: 420,
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(i18n.tr('load sgf fast analysis')),
            value: fast,
            onChanged: (v) => setState(() => fast = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(i18n.tr('load sgf rewind')),
            value: rewind,
            onChanged: (v) => setState(() => rewind = v),
          ),
        ],
      ),
    );
  }
}

/// Asks where to save the game, suggesting a name from its players and date in the last save folder.
Future<void> saveGameAs(AppController app) async {
  final location = await getSaveLocation(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'SGF', extensions: ['sgf']),
    ],
    initialDirectory: _existingDir(app.config('general/sgf_save')),
    suggestedName: app.game!.generateFilename(),
  );
  if (location == null) return;
  var filename = location.path.trim();
  if (!filename.toLowerCase().endsWith('.sgf')) filename += '.sgf';
  final (path, file) = _split(filename);
  if (path != app.config('general/sgf_save')) {
    app.log('Updating sgf save path default to $path', outputDebug);
    (app.configStore.data['general'] as Map)['sgf_save'] = path;
    app.saveConfig('general');
  }
  app.saveGame('$path${Platform.pathSeparator}$file');
}

/// The game report: accuracy, point loss and agreement with the AI for both players, and how many moves fell in
/// each point loss class; for the whole game or its opening, middle game or endgame.
class GameReportDialog extends StatefulWidget {
  final AppController app;
  const GameReportDialog({super.key, required this.app});

  @override
  State<GameReportDialog> createState() => _GameReportDialogState();
}

class _GameReportDialogState extends State<GameReportDialog> {
  List<num>? depthFilter;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    // While the engine is still analysing, the report fills in.
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!(widget.app.engine?.isIdle() ?? true)) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final thresholds = (app.config('trainer/eval_thresholds') as List).cast<num>();
    final (sumStats, histogram, playerPtloss) = gameReport(app.game!, thresholds, depthFilter: depthFilter);
    final labels = [for (final pt in thresholds) pt > 0 ? '≥ $pt' : '< ${thresholds[thresholds.length - 2]}'];
    final colors = [
      for (final c in KTheme.evalColors[app.config('trainer/theme')]!)
        Color.from(alpha: 1, red: c.r * 0.75, green: c.g * 0.75, blue: c.b * 0.75),
    ];
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    Widget cell(Widget child, {Color? color}) => Container(
      height: 32,
      margin: const EdgeInsets.all(1),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color ?? scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(4)),
      child: child,
    );
    Widget stat(String label, double value, double scale, Color bar, bool left) => cell(
      Stack(
        children: [
          Align(
            alignment: left ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: (value / scale).clamp(0.0, 1.0),
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(4)),
              ),
            ),
          ),
          Center(child: Text(label, style: text.bodyMedium)),
        ],
      ),
    );

    final rows = <TableRow>[
      TableRow(
        children: [
          const SizedBox(),
          cell(Text(i18n.tr('header:keystats'), style: text.titleSmall), color: Colors.transparent),
          const SizedBox(),
        ],
      ),
      for (final (label, format, key, scale, moreIsBetter) in <(String, String Function(double), String, double, bool)>[
        ('accuracy', (v) => formatFixed(v, 1), 'accuracy', 100, true),
        ('meanpointloss', (v) => formatFixed(v, 2), 'mean_ptloss', 5, false),
        ('aitopmove', (v) => formatPercent(v, 1), 'ai_top_move', 1, true),
        ('aitop5', (v) => formatPercent(v, 1), 'ai_top5_move', 1, true),
      ])
        TableRow(
          children: [
            _statCell(stat, sumStats, 'B', key, format, scale, moreIsBetter),
            cell(Text(i18n.tr('stat:$label'))),
            _statCell(stat, sumStats, 'W', key, format, scale, moreIsBetter),
          ],
        ),
      TableRow(
        children: [
          for (final h in const ['header:num moves', 'stats:pointslost', 'header:num moves'])
            cell(Text(i18n.tr(h), style: text.titleSmall), color: Colors.transparent),
        ],
      ),
      for (var i = 0; i < thresholds.length; i++)
        TableRow(
          children: [
            for (final bw in const ['B', '', 'W'])
              if (bw.isEmpty)
                cell(Text(labels[thresholds.length - 1 - i]), color: colors[thresholds.length - 1 - i])
              else
                stat(
                  '${histogram[i][bw]}',
                  histogram[i][bw]!.toDouble(),
                  playerPtloss[bw]!.length + 1e-6,
                  colors[thresholds.length - 1 - i],
                  bw == 'B',
                ),
          ],
        ),
    ];

    return AlertDialog(
      title: Text(i18n.tr('analysis:report')),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<List<num>?>(
                segments: [
                  ButtonSegment(value: null, label: Text(i18n.tr('Entire Game'))),
                  ButtonSegment(value: const [0, 0.14], label: Text(i18n.tr('Opening'))),
                  ButtonSegment(value: const [0.14, 0.4], label: Text(i18n.tr('Midgame'))),
                  ButtonSegment(value: const [0.4, 10], label: Text(i18n.tr('Endgame'))),
                ],
                selected: {depthFilter},
                onSelectionChanged: (s) => setState(() => depthFilter = s.first),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final bw in const ['B', 'W'])
                    Expanded(
                      child: PlayerCard(app: app, player: bw, inGame: false),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Table(columnWidths: const {1: FlexColumnWidth(1.2)}, children: rows),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }

  Widget _statCell(
    Widget Function(String, double, double, Color, bool) stat,
    Map<String, Map<String, double>> sumStats,
    String bw,
    String key,
    String Function(double) format,
    double scale,
    bool moreIsBetter,
  ) {
    final mine = sumStats[bw]![key];
    final theirs = sumStats[bw == 'B' ? 'W' : 'B']![key] ?? 0;
    final better = ((mine ?? 0) < theirs) != moreIsBetter;
    return stat(
      mine != null ? format(mine) : '',
      mine ?? 0,
      scale,
      better ? KTheme.statBetterColor : KTheme.statWorseColor,
      bw == 'B',
    );
  }
}
