// Starting the tsumego practice: a folder (or file) of problems that come with answers, and a level; the problems
// are then played one after another against the strongest AI, judged by their answers (see the side panel).

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:katrain_core/api.dart' show ApiError;
import 'package:katrain_core/katrain_core.dart';

import '../../state/app_controller.dart';
import 'config_editor.dart';

class TsumegoPracticeDialog extends StatefulWidget {
  final AppController app;
  const TsumegoPracticeDialog({super.key, required this.app});

  @override
  State<TsumegoPracticeDialog> createState() => _TsumegoPracticeDialogState();
}

class _TsumegoPracticeDialogState extends State<TsumegoPracticeDialog> {
  late final app = widget.app;
  late final folder = TextEditingController(text: app.practiceSource);
  late String level = app.practiceLevel;

  /// The problems with an answer in the folder, by level; null while counting or without a folder.
  ({int total, Map<String, int> levels})? count;
  String? error;
  Timer? _recount;

  @override
  void initState() {
    super.initState();
    folder.addListener(() {
      _recount?.cancel();
      _recount = Timer(const Duration(milliseconds: 400), _count);
    });
    _count();
  }

  @override
  void dispose() {
    _recount?.cancel();
    folder.dispose();
    super.dispose();
  }

  Future<void> _count() async {
    final source = folder.text.trim();
    void show(({int total, Map<String, int> levels})? counted, String? problem) => setState(() {
      count = counted;
      error = problem;
      if (counted != null && !counted.levels.containsKey(level)) level = '';
    });
    if (source.isEmpty) return show(null, null);
    try {
      final counted = await app.practiceCount(source, '');
      if (mounted && source == folder.text.trim()) show(counted, null);
    } on ApiError catch (e) {
      if (mounted) show(null, e.message);
    }
  }

  Future<void> _browse() async {
    final current = folder.text.trim();
    final dir = await getDirectoryPath(
      initialDirectory: current.isNotEmpty && Directory(current).existsSync() ? current : null,
    );
    if (dir != null) folder.text = dir;
  }

  int get _selected => level.isEmpty ? count?.total ?? 0 : count?.levels[level] ?? 0;

  void _start() {
    if (_selected == 0) return;
    final source = folder.text.trim();
    // the same set goes on where it was left; another one starts at its first problem
    final same = source == app.practiceSource && level == app.practiceLevel;
    Navigator.of(context).pop();
    app.startPractice(source: source, level: level, index: same ? app.practiceIndex : 0);
  }

  @override
  Widget build(BuildContext context) {
    final levels = [...?count?.levels.keys]..sort((a, b) => int.parse(a).compareTo(int.parse(b)));
    final total = count?.total;
    return SettingsDialog(
      title: i18n.tr('menu:tsumego'),
      actionLabel: i18n.tr('tsumego:start'),
      width: 480,
      onAction: _start,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FieldLabel(
            label: i18n.tr('tsumego:folder'),
            child: TextField(
              controller: folder,
              // a long path wraps instead of hiding its end; Enter still starts (a path has no line breaks)
              minLines: 1,
              maxLines: 3,
              inputFormatters: [FilteringTextInputFormatter.deny('\n')],
              decoration: InputDecoration(
                isDense: true,
                errorText: error ?? (total == 0 ? i18n.tr('tsumego:none') : null),
                helperText: folder.text.trim().isEmpty
                    ? i18n.tr('tsumego:choose folder')
                    : total == null
                    ? null
                    : fillTemplate(i18n.tr('tsumego:count'), {'n': total}),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.folder_open_outlined),
                  tooltip: i18n.tr('tsumego:folder'),
                  onPressed: _browse,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FieldLabel(
            label: i18n.tr('tsumego:level'),
            child: DropdownButtonFormField<String>(
              key: ValueKey('level-$level-${levels.join(',')}'),
              initialValue: level,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: [
                DropdownMenuItem(value: '', child: Text(i18n.tr('tsumego:any level'))),
                for (final l in levels)
                  DropdownMenuItem(
                    value: l,
                    child: Text('${fillTemplate(i18n.tr('tsumego:level n'), {'n': l})}  (${count!.levels[l]})'),
                  ),
              ],
              onChanged: levels.isEmpty ? null : (v) => setState(() => level = v ?? ''),
            ),
          ),
        ],
      ),
    );
  }
}
