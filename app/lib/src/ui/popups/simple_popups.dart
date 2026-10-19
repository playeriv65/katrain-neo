// The clock settings, tsumego frame, re-analysis and engine failure dialogs.

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../../state/app_controller.dart';
import '../../state/dialogs.dart';
import '../menu_drawer.dart' show openUrl;
import 'config_editor.dart';

/// Clock settings: main time, byo-yomi length and periods, and the minimal time a move must take.
class TimerDialog extends StatefulWidget {
  final AppController app;
  const TimerDialog({super.key, required this.app});

  @override
  State<TimerDialog> createState() => _TimerDialogState();
}

class _TimerDialogState extends State<TimerDialog> {
  late final editor = ConfigEditor(widget.app);

  void _update() {
    try {
      editor.updateConfig();
    } on InputParseError catch (e) {
      widget.app.setStatus('$e', statusError);
      return;
    }
    final app = widget.app;
    for (final p in app.playersInfo.values) {
      p.periodsUsed = 0;
    }
    app.clock.paused = true;
    app.game!.currentNode.timeUsed = 0;
    app.game!.mainTimeUsed = 0;
    app.updateState();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    Widget number(String key, String label, {bool integer = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: NumberField(
        label: i18n.tr(label),
        initial: editor.value(key),
        integer: integer,
        register: (read) => editor.field(key, read),
      ),
    );
    return SettingsDialog(
      title: i18n.tr('timer settings'),
      actionLabel: i18n.tr('update timer'),
      onAction: _update,
      width: 420,
      child: Column(
        children: [
          number('timer/main_time', 'main time'),
          number('timer/byo_length', 'byoyomi length'),
          number('timer/byo_periods', 'byoyomi periods', integer: true),
          number('timer/minimal_use', 'minimal time use'),
        ],
      ),
    );
  }
}

/// Fills the board around a life-and-death problem.
class TsumegoFrameDialog extends StatefulWidget {
  final AppController app;
  const TsumegoFrameDialog({super.key, required this.app});

  @override
  State<TsumegoFrameDialog> createState() => _TsumegoFrameDialogState();
}

class _TsumegoFrameDialogState extends State<TsumegoFrameDialog> {
  int margin = 4;
  bool ko = false;

  @override
  Widget build(BuildContext context) {
    return SettingsDialog(
      title: i18n.tr('analysis:tsumegoframe'),
      actionLabel: i18n.tr('analysis:tsumegoframe'),
      width: 420,
      onAction: () {
        Navigator.of(context).pop();
        widget.app.tsumegoFrame(ko, margin);
      },
      child: Column(
        children: [
          TextFormField(
            initialValue: '$margin',
            decoration: InputDecoration(labelText: i18n.tr('tsumego:walldistance')),
            keyboardType: TextInputType.number,
            onChanged: (v) => margin = int.tryParse(v) ?? margin,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(i18n.tr('tsumego:ko')),
            value: ko,
            onChanged: (v) => setState(() => ko = v),
          ),
        ],
      ),
    );
  }
}

/// Analyses the whole game again, or a range of moves, or only around mistakes, with more visits.
class ReAnalyzeGameDialog extends StatefulWidget {
  final AppController app;
  const ReAnalyzeGameDialog({super.key, required this.app});

  @override
  State<ReAnalyzeGameDialog> createState() => _ReAnalyzeGameDialogState();
}

class _ReAnalyzeGameDialogState extends State<ReAnalyzeGameDialog> {
  int visits = 2500;
  bool moveRange = false;
  late int startMove = widget.app.game!.currentNode.depth;
  int endMove = 999;
  bool mistakesOnly = false;

  @override
  Widget build(BuildContext context) {
    return SettingsDialog(
      title: i18n.tr('analysis:game'),
      actionLabel: i18n.tr('analysis:game'),
      width: 460,
      onAction: () {
        Navigator.of(context).pop();
        widget.app.analyzeExtra(
          'game',
          visits: visits,
          moveRange: moveRange ? [startMove, endMove] : null,
          mistakesOnly: mistakesOnly,
        );
      },
      child: Column(
        children: [
          TextFormField(
            initialValue: '$visits',
            decoration: InputDecoration(labelText: i18n.tr('reanalyze max visits')),
            onChanged: (v) => visits = int.tryParse(v) ?? visits,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(i18n.tr('limit to moves')),
            value: moveRange,
            onChanged: (v) => setState(() => moveRange = v),
          ),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  enabled: moveRange,
                  initialValue: '$startMove',
                  decoration: InputDecoration(labelText: i18n.tr('from move')),
                  onChanged: (v) => startMove = int.tryParse(v) ?? startMove,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextFormField(
                  enabled: moveRange,
                  initialValue: '$endMove',
                  decoration: InputDecoration(labelText: i18n.tr('to move')),
                  onChanged: (v) => endMove = int.tryParse(v) ?? endMove,
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(i18n.tr('reanalyze mistakes only')),
            value: mistakesOnly,
            onChanged: (v) => setState(() => mistakesOnly = v),
          ),
        ],
      ),
    );
  }
}

/// The engine failed to start or died: what happened, what to try, and retry.
class EngineRecoveryDialog extends StatelessWidget {
  final AppController app;
  final EngineFailure failure;
  final VoidCallback openSettings;
  const EngineRecoveryDialog({super.key, required this.app, required this.failure, required this.openSettings});

  /// The translated message without its markup (the links become buttons).
  String _plain(String text) => text.replaceAll(RegExp(r'\[/?[a-z]+(=[^\]]*)?\]'), '');

  @override
  Widget build(BuildContext context) {
    final remote = failure.engineType == 'remote';
    final settings = i18n.tr('menu:settings');
    final opening = fillTemplate(
      i18n.tr(remote ? 'remote engine disconnected popup opening message' : 'engine died popup opening message'),
      {'code': failure.code, 'error_message': failure.message},
    );
    final suggestion = fillTemplate(
      i18n.tr(remote ? 'remote engine check url suggestion' : 'change engine suggestion'),
      {'link': settings},
    );
    final help = fillTemplate(i18n.tr('go to engine help page'), {'link': i18n.tr('link_here')});
    return AlertDialog(
      icon: const Icon(Icons.error_outline),
      title: Text(i18n.tr('engine recovery')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: SelectableText('${_plain(opening)}\n\n${_plain(suggestion)}\n\n${_plain(help)}'),
        ),
      ),
      actions: [
        TextButton(onPressed: () => openUrl('$homepage#katago'), child: Text(i18n.tr('link_here'))),
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            openSettings();
          },
          child: Text(settings),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            app.restartEngine();
          },
          child: Text(i18n.tr('engine recovery: retry')),
        ),
      ],
    );
  }
}
