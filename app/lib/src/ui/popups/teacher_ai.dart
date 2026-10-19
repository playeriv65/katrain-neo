// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/app/popups.py and popups.kv:
// ConfigTeacherPopup and ConfigAIPopup.

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../../state/app_controller.dart';
import '../../theme.dart';
import 'config_editor.dart';

Widget _labelled(BuildContext context, String label, Widget input) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    children: [
      Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
      const SizedBox(width: 16),
      SizedBox(width: 260, child: input),
    ],
  ),
);

/// A dropdown over translated keys, storing the key (`LabelledSpinner`).
Widget _choice(String value, List<String> refs, ValueChanged<String> onChanged) => DropdownButtonFormField<String>(
  initialValue: refs.contains(value) ? value : refs.first,
  isExpanded: true,
  decoration: const InputDecoration(isDense: true),
  items: [
    for (final r in refs)
      DropdownMenuItem(
        value: r,
        child: Text(i18n.tr(r), overflow: TextOverflow.ellipsis),
      ),
  ],
  onChanged: (v) => v == null ? null : onChanged(v),
);

/// Teaching settings: per point loss class, its threshold, undos offered, and whether to show and save its dots;
/// and what the board shows.
class TeacherDialog extends StatefulWidget {
  final AppController app;
  const TeacherDialog({super.key, required this.app});

  @override
  State<TeacherDialog> createState() => _TeacherDialogState();
}

class _TeacherDialogState extends State<TeacherDialog> {
  late final app = widget.app;
  late final editor = ConfigEditor(app);
  late String theme = editor.value('trainer/theme') as String;
  final bools = <String, bool>{};

  bool _bool(String key) => bools.putIfAbsent(key, () {
    editor.field(key, () => bools[key]!);
    return editor.value(key) == true;
  });

  void _update() {
    try {
      editor.updateConfig();
    } on InputParseError catch (e) {
      app.setStatus('$e', statusError);
      return;
    }
    // The keyboard shortcut can change this without changing the config.
    app.showMoveNum = app.config('trainer/show_move_numbers') as bool;
    Navigator.of(context).pop();
  }

  Widget _check(String key) => Checkbox(value: _bool(key), onChanged: (v) => setState(() => bools[key] = v!));

  Widget _switch(String key, String label) => SwitchListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(i18n.tr(label)),
    value: _bool(key),
    onChanged: (v) => setState(() => bools[key] = v),
  );

  Widget _number(String key, {bool integer = false, String? label}) => NumberField(
    key: ValueKey(key),
    label: label ?? '',
    initial: editor.value(key),
    integer: integer,
    register: (read) => editor.field(key, read),
  );

  @override
  Widget build(BuildContext context) {
    editor.field('trainer/theme', () => theme);
    final thresholds = app.config('trainer/eval_thresholds') as List;
    final colors = KTheme.evalColors[theme]!;
    final header = Theme.of(context).textTheme.labelMedium;
    return SettingsDialog(
      title: i18n.tr('teacher settings'),
      actionLabel: i18n.tr('update teacher'),
      onAction: _update,
      width: 680,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            columnWidths: const {0: FixedColumnWidth(64)},
            children: [
              TableRow(
                children: [
                  for (final k in const ['dot color', 'point loss threshold', 'num undos', 'show dots', 'save dots'])
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(i18n.tr(k), style: header, textAlign: TextAlign.center),
                    ),
                ],
              ),
              for (var i = thresholds.length - 1; i >= 0; i--)
                TableRow(
                  children: [
                    Center(child: CircleAvatar(radius: 10, backgroundColor: colors[i])),
                    Padding(padding: const EdgeInsets.all(4), child: _number('trainer/eval_thresholds::$i')),
                    Padding(padding: const EdgeInsets.all(4), child: _number('trainer/num_undo_prompts::$i')),
                    Center(child: _check('trainer/show_dots::$i')),
                    Center(child: _check('trainer/save_feedback::$i')),
                  ],
                ),
            ],
          ),
          const Divider(height: 24),
          _labelled(
            context,
            i18n.tr('theme'),
            _choice(theme, KTheme.evalColors.keys.toList(), (v) => setState(() => theme = v)),
          ),
          _labelled(
            context,
            i18n.tr('stats on top move'),
            Row(
              children: [
                for (final key in const ['trainer/top_moves_show', 'trainer/top_moves_show_secondary']) ...[
                  Expanded(
                    child: _TopMoveChoice(editor: editor, settingKey: key),
                  ),
                  if (key == 'trainer/top_moves_show') const Padding(padding: EdgeInsets.all(6), child: Text('&')),
                ],
              ],
            ),
          ),
          _labelled(context, i18n.tr('show stats if'), _number('trainer/low_visits', integer: true)),
          _labelled(context, i18n.tr('show last n dots'), _number('trainer/eval_on_show_last', integer: true)),
          _switch('trainer/show_move_numbers', 'show move numbers'),
          _switch('trainer/eval_show_ai', 'show ai dots'),
          _switch('trainer/extra_precision', 'show two digits for point loss near zero'),
          _switch('trainer/save_analysis', 'cache analysis to sgf'),
        ],
      ),
    );
  }
}

class _TopMoveChoice extends StatefulWidget {
  final ConfigEditor editor;
  final String settingKey;
  const _TopMoveChoice({required this.editor, required this.settingKey});

  @override
  State<_TopMoveChoice> createState() => _TopMoveChoiceState();
}

class _TopMoveChoiceState extends State<_TopMoveChoice> {
  late String value = () {
    final v = widget.editor.value(widget.settingKey);
    return topMoveOptions.contains(v) ? v as String : topMoveOptions.first;
  }();

  @override
  void initState() {
    super.initState();
    widget.editor.field(widget.settingKey, () => value);
  }

  @override
  Widget build(BuildContext context) => _choice(value, topMoveOptions, (v) => setState(() => value = v));
}

/// AI settings: a strategy, its options, and the strength they are estimated to give.
class AiDialog extends StatefulWidget {
  final AppController app;
  const AiDialog({super.key, required this.app});

  @override
  State<AiDialog> createState() => _AiDialogState();
}

class _AiDialogState extends State<AiDialog> {
  late final app = widget.app;
  late var editor = ConfigEditor(widget.app);
  late String strategy = () {
    final selected = {for (final p in app.playersInfo.values) p.strategy}..remove(aiDefault);
    return selected.isEmpty ? aiConfigDefault : selected.first;
  }();
  String estimatedRank = '';
  final bools = <String, bool>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _estimateRank());
  }

  void _estimateRank() {
    if (!mounted) return;
    final Map<String, Object?> options;
    try {
      options = editor.collect();
    } on InputParseError {
      setState(() => estimatedRank = '??');
      return;
    }
    final prefix = 'ai/$strategy/';
    final settings = {
      for (final e in options.entries)
        if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
    };
    setState(() => estimatedRank = rankLabel(aiRankEstimation(strategy, settings).toDouble()));
  }

  void _selectStrategy(String s) {
    setState(() {
      strategy = s;
      editor = ConfigEditor(app); // the options of the other strategy are not stored
      bools.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _estimateRank());
  }

  void _update() {
    try {
      editor.updateConfig();
    } on InputParseError catch (e) {
      app.setStatus('$e', statusError);
      return;
    }
    app.updateCalculatedRanks();
    app.refresh();
    Navigator.of(context).pop();
  }

  Widget _option(String k, Object? v) {
    final key = 'ai/$strategy/$k';
    final values = aiOptionValues[k];
    if (values == 'bool') {
      bools.putIfAbsent(key, () {
        editor.field(key, () => bools[key]!);
        return v == true;
      });
      return Align(
        alignment: Alignment.centerLeft,
        child: Checkbox(
          value: bools[key],
          onChanged: (b) {
            setState(() => bools[key] = b!);
            _estimateRank();
          },
        ),
      );
    }
    if (values is List) {
      final fixed = <(num, String)>[
        for (final value in values)
          if (value is (num, String))
            (value.$1, value.$2.replaceAllMapped(RegExp(r'\[(.*?)]'), (m) => i18n.tr(m[1]!)))
          else
            (value as num, pyStr(value)),
      ];
      return SelectionSliderField(
        key: ValueKey(key),
        values: fixed,
        initial: v,
        keyOption: aiKeyProperties.contains(k),
        register: (read) => editor.field(key, read),
        onChanged: _estimateRank,
      );
    }
    return NumberField(
      key: ValueKey(key),
      label: '',
      initial: v,
      register: (read) => editor.field(key, read),
      onChanged: (_) => _estimateRank(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = (app.config('ai/$strategy') as Map).cast<String, dynamic>();
    final keys = settings.keys.toList()
      ..sort((a, b) {
        final ka = aiKeyProperties.contains(a) ? 0 : 1;
        final kb = aiKeyProperties.contains(b) ? 0 : 1;
        return ka != kb ? ka - kb : a.compareTo(b);
      });
    final text = Theme.of(context).textTheme;
    return SettingsDialog(
      title: i18n.tr('ai settings'),
      actionLabel: i18n.tr('update ai settings'),
      onAction: _update,
      width: 640,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: strategy,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: i18n.tr('Select AI'), isDense: true),
                  items: [
                    for (final s in aiStrategiesRecommendedOrder) DropdownMenuItem(value: s, child: Text(i18n.tr(s))),
                  ],
                  onChanged: (s) => s == null ? null : _selectStrategy(s),
                ),
              ),
              const SizedBox(width: 24),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(i18n.tr('estimated strength'), style: text.labelMedium),
                  Text(estimatedRank, style: text.titleLarge),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(i18n.tr(strategy.replaceFirst('ai:', 'aihelp:')), style: text.bodySmall),
          const SizedBox(height: 12),
          for (final k in keys)
            Padding(
              key: ValueKey('$strategy/$k'),
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(width: 160, child: Text(k, style: text.bodyMedium)),
                  Expanded(child: _option(k, settings[k])),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
