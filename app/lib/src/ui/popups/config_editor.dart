// Settings dialogs read settings by path (`trainer/eval_thresholds::2` is an element of a list) and write back the
// ones that changed; plus the number field, slider and dialog frame they share.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:katrain_core/katrain_core.dart';

import '../../state/app_controller.dart';

class InputParseError implements Exception {
  final String message;
  InputParseError(this.message);
  @override
  String toString() => message;
}

/// Values entered in a popup, by setting path, and how to store them (QuickConfigGui).
class ConfigEditor {
  final AppController app;
  final Map<String, Object? Function()> _fields = {};
  ConfigEditor(this.app);

  /// `get_setting`: the value at [key], the map or list holding it, and the key or index in there. Missing
  /// sections are created; a missing value is created empty and logged.
  (Object?, Object, Object) getSetting(String key) {
    final keys = key.split('/');
    Map<String, dynamic> config = app.configStore.data;
    for (final k in keys.sublist(0, keys.length - 1)) {
      config = (config.putIfAbsent(k, () => <String, dynamic>{}) as Map).cast<String, dynamic>();
    }
    final last = keys.last;
    if (last.contains('::')) {
      final [arrayKey, ix] = last.split('::');
      final array = config[arrayKey] as List;
      final i = int.parse(ix);
      return (array[i], array, i);
    }
    if (!config.containsKey(last)) {
      config[last] = '';
      app.log(
        'Configuration setting $key was missing, created it, but this likely indicates a broken config file.',
        outputError,
      );
    }
    return (config[last], config, last);
  }

  Object? value(String key) => getSetting(key).$1;

  /// Registers an input: [read] gives its current value, and throws [InputParseError] for an invalid one.
  void field(String key, Object? Function() read) => _fields[key] = read;

  void remove(String key) => _fields.remove(key);

  Map<String, Object?> collect() => {for (final e in _fields.entries) e.key: e.value()};

  /// Stores the values that changed; returns their keys.
  Set<String> updateConfig({bool saveToFile = true}) {
    final updated = <String>{};
    for (final MapEntry(key: multikey, :value) in collect().entries) {
      final (old, container, key) = getSetting(multikey);
      if (value != old) {
        app.log('Updating setting $multikey = $value', outputDebug);
        if (container is List) {
          container[key as int] = value;
        } else {
          (container as Map)[key] = value;
        }
        updated.add(multikey);
      }
    }
    if (saveToFile) app.saveConfig();
    return updated;
  }
}

/// `LabelledFloatInput` / `LabelledIntInput`: a text field for a number.
class NumberField extends StatefulWidget {
  final String label;
  final Object? initial;
  final bool integer;
  final String? helper;
  final void Function(Object? Function() read) register;
  final ValueChanged<String>? onChanged;
  const NumberField({
    super.key,
    required this.label,
    required this.initial,
    required this.register,
    this.integer = false,
    this.helper,
    this.onChanged,
  });

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final _controller = TextEditingController(text: '${widget.initial}');

  Object? _read() {
    final text = _controller.text.trim();
    try {
      if (widget.integer) return int.parse(text.isEmpty ? '0' : text);
      return double.parse(text.isEmpty ? '0.0' : text);
    } on FormatException catch (e) {
      throw InputParseError("Could not parse value '$text' for ${widget.label}: $e");
    }
  }

  @override
  void initState() {
    super.initState();
    widget.register(_read);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
    decoration: InputDecoration(labelText: widget.label, helperText: widget.helper, isDense: true),
    onChanged: widget.onChanged,
  );
}

/// `LabelledSelectionSlider`: a slider over fixed (value, label) steps next to a text field, which may hold any
/// number; the text wins when it is not empty.
class SelectionSliderField extends StatefulWidget {
  final List<(num, String)> values;
  final Object? initial;
  final bool keyOption;
  final void Function(Object? Function() read) register;
  final VoidCallback? onChanged;
  const SelectionSliderField({
    super.key,
    required this.values,
    required this.initial,
    required this.register,
    this.keyOption = false,
    this.onChanged,
  });

  @override
  State<SelectionSliderField> createState() => _SelectionSliderFieldState();
}

class _SelectionSliderFieldState extends State<SelectionSliderField> {
  late final _controller = TextEditingController(text: '${widget.initial}');
  int index = 0;

  /// `SelectionSlider.set_value`: the closest step, the first one on a tie.
  void _setIndexFrom(Object? value) {
    if (value is! num) return;
    var best = 0;
    for (var i = 1; i < widget.values.length; i++) {
      if ((widget.values[i].$1 - value).abs() < (widget.values[best].$1 - value).abs()) best = i;
    }
    index = best;
  }

  Object? _read() {
    final text = _controller.text.trim();
    if (text.isEmpty) return widget.values[index].$1;
    try {
      return double.parse(text);
    } on FormatException catch (e) {
      throw InputParseError("Could not parse value '$text': $e");
    }
  }

  @override
  void initState() {
    super.initState();
    _setIndexFrom(widget.initial);
    widget.register(_read);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = widget.values[index].$2;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                value: index.toDouble(),
                max: (widget.values.length - 1).toDouble(),
                divisions: widget.values.length > 1 ? widget.values.length - 1 : null,
                activeColor: widget.keyOption ? scheme.primary : scheme.secondary,
                onChanged: (v) {
                  setState(() {
                    index = v.round();
                    _controller.text = '${widget.values[index].$1}';
                  });
                  widget.onChanged?.call();
                },
              ),
              if (label != '${widget.values[index].$1}')
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(label, style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ),
        ),
        SizedBox(
          width: 88,
          child: TextField(
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(isDense: true),
            onChanged: (text) {
              final v = double.tryParse(text);
              if (v != null) setState(() => _setIndexFrom(v));
              widget.onChanged?.call();
            },
          ),
        ),
      ],
    );
  }
}

/// A dialog with a title, scrollable content and the button that applies it.
class SettingsDialog extends StatelessWidget {
  final String title;
  final Widget child;
  final String actionLabel;
  final VoidCallback onAction;
  final double width;
  const SettingsDialog({
    super.key,
    required this.title,
    required this.child,
    required this.actionLabel,
    required this.onAction,
    this.width = 560,
  });

  /// Enter applies the dialog.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      onAction();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: _onKey,
    child: AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(child: child),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(onPressed: onAction, child: Text(actionLabel)),
      ],
    ),
  );
}
