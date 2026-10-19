// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/gui/popups.py and popups.kv: ConfigPopup
// (general and engine settings).

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:katrain_core/io.dart';
import 'package:katrain_core/katrain_core.dart';

import '../../state/katrain_gui.dart';
import 'config_editor.dart';
import 'engine_files.dart';

/// General settings, and which KataGo to use (a local program, a remote server or a custom command) with its
/// analysis settings.
class ConfigDialog extends StatefulWidget {
  final KaTrainGui gui;
  final EngineDownloads downloads;
  const ConfigDialog({super.key, required this.gui, required this.downloads});

  @override
  State<ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<ConfigDialog> {
  late final gui = widget.gui;
  late final editor = ConfigEditor(gui);
  late final finder = EngineFileFinder(gui, widget.downloads);
  late String backend = resolveEngineBackend(_engineConfig);
  late final paths = {
    for (final key in const ['engine/katago', 'engine/model', 'engine/humanlike_model', 'engine/config'])
      key: TextEditingController(text: pyStr(editor.value(key))),
  };
  late final remoteUrl = TextEditingController(text: pyStr(editor.value('engine/remote_url')));
  late final altCommand = TextEditingController(text: pyStr(editor.value('engine/altcommand')));
  late bool sound = editor.value('timer/sound') == true;
  late bool restoreSize = editor.value('ui_state/restoresize') == true;
  List<FoundFile> models = [];
  List<FoundFile> humanlikeModels = [];
  List<FoundFile> katagos = [];
  List<Download> modelDownloads = [];
  List<Download>? katagoDownloads = [];
  DateTime _lastModelDownload = DateTime(0);

  Map<String, dynamic> get _engineConfig => (gui.config('engine') as Map).cast<String, dynamic>();

  @override
  void initState() {
    super.initState();
    for (final MapEntry(:key, :value) in paths.entries) {
      // LabelledPathInput: no line breaks, no surrounding space
      editor.field(key, () => value.text.trim().replaceAll('\n', ' ').replaceAll('\r', ' '));
      value.addListener(_checkFiles);
    }
    editor.field('engine/remote_url', () => remoteUrl.text);
    editor.field('engine/altcommand', () => altCommand.text);
    editor.field('timer/sound', () => sound);
    editor.field('ui_state/restoresize', () => restoreSize);
    _scanFiles();
  }

  @override
  void dispose() {
    for (final c in [...paths.values, remoteUrl, altCommand]) {
      c.dispose();
    }
    for (final d in [...modelDownloads, ...?katagoDownloads]) {
      d.cancel();
    }
    super.dispose();
  }

  void _scanFiles() {
    final (all, humanlike) = finder.models(paths['engine/model']!.text, paths['engine/humanlike_model']!.text);
    models = all;
    humanlikeModels = humanlike;
    katagos = finder.katagos(paths['engine/katago']!.text);
  }

  void _checkFiles() {
    if (mounted) setState(_scanFiles);
  }

  bool _exists(String path) => path.isNotEmpty && File(findResource(path, gui.resourceDir)).existsSync();

  Future<void> _browse(String key) async {
    final current = paths[key]!.text.trim();
    final dir = current.isEmpty ? null : File(findResource(current, gui.resourceDir)).parent.path;
    final file = await openFile(initialDirectory: dir != null && Directory(dir).existsSync() ? dir : null);
    if (file != null) paths[key]!.text = file.path;
  }

  void _downloadModels() {
    // KaTrain ignores clicks within 5 seconds of the last one
    if (DateTime.now().difference(_lastModelDownload).inSeconds <= 5) return;
    _lastModelDownload = DateTime.now();
    for (final d in modelDownloads) {
      d.cancel();
    }
    setState(() => modelDownloads = []);
    downloadModels(gui, widget.downloads, [...models, ...humanlikeModels], _checkFiles).then((started) {
      if (!mounted) return;
      setState(
        () =>
            modelDownloads = started.isEmpty ? [Download(i18n.tr('All models downloaded'), '')..done = true] : started,
      );
    });
  }

  void _downloadKatagos() {
    for (final d in [...?katagoDownloads]) {
      d.cancel();
    }
    setState(() => katagoDownloads = downloadKatagos(gui, widget.downloads, katagos, _checkFiles));
  }

  void _update() {
    final oldBackend = gui.config('engine/backend', '');
    final Set<String> updated;
    try {
      (gui.configStore.data['engine'] as Map)['backend'] = backend;
      updated = editor.updateConfig();
    } on InputParseError catch (e) {
      gui.setStatus('$e', statusError);
      return;
    }
    if (backend != oldBackend) updated.add('engine/backend');
    gui.debugLevel = gui.config('general/debug_level', outputInfo) as int;
    Navigator.of(context).pop();

    const ignore = {'max_visits', 'fast_visits', 'max_time', 'enable_ownership', 'wide_root_noise'};
    final detectedRestart = [
      for (final key in updated)
        if (key.contains('engine') && !ignore.any(key.contains)) key,
    ];
    if (detectedRestart.isNotEmpty) {
      gui.log('Restarting Engine after ${pyStr(detectedRestart)} settings change');
      gui.restartEngine();
    } else {
      gui.updateState();
    }
  }

  Widget _number(String key, String label, {bool integer = false, String? hint}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: NumberField(
      label: i18n.tr(label),
      initial: editor.value(key),
      integer: integer,
      helper: hint == null ? null : i18n.tr(hint),
      register: (read) => editor.field(key, read),
    ),
  );

  Widget _pathField(
    String key,
    String label, {
    String? hint,
    List<FoundFile>? found,
    String? foundLabel,
    bool allowEmpty = false,
  }) {
    final controller = paths[key]!;
    final text = controller.text.trim();
    final missing = !(allowEmpty && text.isEmpty) && !_exists(text);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: i18n.tr(label),
          hintText: hint == null ? null : i18n.tr(hint),
          errorText: missing ? i18n.tr('file not found') : null,
          helperText: foundLabel,
          isDense: true,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (found != null)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.arrow_drop_down_circle_outlined),
                  tooltip: foundLabel,
                  onSelected: (path) => controller.text = path,
                  itemBuilder: (_) => [
                    if (key == 'engine/katago') PopupMenuItem(value: '', child: Text(i18n.tr('default katago option'))),
                    for (final f in found) PopupMenuItem(value: f.path, child: Text(f.description)),
                  ],
                ),
              IconButton(
                icon: const Icon(Icons.folder_open_outlined),
                tooltip: i18n.tr(label),
                onPressed: () => _browse(key),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _downloadsView(List<Download>? downloads, String noneForPlatform) {
    if (downloads == null) return Text(noneForPlatform);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final d in downloads)
          ListenableBuilder(
            listenable: d,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    d.url.isEmpty
                        ? d.name
                        : d.error != null
                        ? 'Download of ${d.name} failed or cancelled (${d.error})'
                        : d.done
                        ? '${d.name}: ✓'
                        : 'Downloading ${d.name}: ${d.progress == null ? '' : '${(d.progress! * 100).toStringAsFixed(0)}%'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (!d.done && d.error == null) LinearProgressIndicator(value: d.progress),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _local() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _pathField(
        'engine/katago',
        'engine:katago',
        hint: 'engine:katago:hint',
        found: katagos,
        foundLabel: pyFormat(i18n.tr('katago binaries available'), {'num': katagos.length}),
        allowEmpty: true,
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.download),
          label: Text(i18n.tr('download katago button')),
          onPressed: _downloadKatagos,
        ),
      ),
      _downloadsView(katagoDownloads, 'No binaries available for platform ${EngineDownloads.platform}'),
      _pathField(
        'engine/model',
        'engine:model',
        found: models,
        foundLabel: pyFormat(i18n.tr('models available'), {'num': models.length}),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.download),
          label: Text(i18n.tr('download models button')),
          onPressed: _downloadModels,
        ),
      ),
      _downloadsView(modelDownloads, ''),
      _pathField(
        'engine/humanlike_model',
        'engine:humanlike_model',
        found: humanlikeModels,
        foundLabel: pyFormat(i18n.tr('models available'), {'num': humanlikeModels.length}),
        allowEmpty: true,
      ),
      _pathField('engine/config', 'engine:config'),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final configFile = gui.configStore is JsonConfigStore ? (gui.configStore as JsonConfigStore).filename : '';
    final engineSection = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(i18n.tr('katago settings'), style: text.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            for (final b in const ['local', 'remote', 'custom'])
              ButtonSegment(value: b, label: Text(i18n.tr('engine:tab:$b'))),
          ],
          selected: {backend},
          onSelectionChanged: (s) => setState(() => backend = s.first),
        ),
        const SizedBox(height: 4),
        Text(i18n.tr('engine:backend:note'), style: text.bodySmall?.copyWith(color: scheme.tertiary)),
        const SizedBox(height: 8),
        // All three stay mounted: KaTrain stores the settings of every tab, and the selected tab picks the backend.
        Offstage(offstage: backend != 'local', child: _local()),
        Offstage(
          offstage: backend != 'remote',
          child: TextField(
            controller: remoteUrl,
            decoration: InputDecoration(
              labelText: i18n.tr('engine:remote_url'),
              hintText: i18n.tr('engine:remote_url:hint'),
              isDense: true,
            ),
          ),
        ),
        Offstage(
          offstage: backend != 'custom',
          child: TextField(
            controller: altCommand,
            decoration: InputDecoration(
              labelText: i18n.tr('engine:altcommand'),
              hintText: i18n.tr('engine:altcommand:hint'),
              isDense: true,
            ),
          ),
        ),
      ],
    );
    final general = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(i18n.tr('general settings'), style: text.titleMedium),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(i18n.tr('count down sound')),
          value: sound,
          onChanged: (v) => setState(() => sound = v),
        ),
        _number('general/anim_pv_time', 'general:anim_pv_time', hint: 'engine:time:hint'),
        _number('general/anim_pv_moves', 'general:anim_pv_moves', integer: true),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Restore window size on startup'),
          value: restoreSize,
          onChanged: (v) => setState(() => restoreSize = v),
        ),
        _number('general/debug_level', 'general:debug_level', integer: true, hint: 'general:debug_level:hint'),
        const SizedBox(height: 16),
        Text(i18n.tr('engine settings'), style: text.titleMedium),
        _number('engine/max_visits', 'engine:max_visits', integer: true),
        _number('engine/fast_visits', 'engine:fast_visits', integer: true),
        _number('engine/max_time', 'engine:max_time', hint: 'engine:time:hint'),
        _number('engine/wide_root_noise', 'engine:wide_root_noise', hint: 'engine:wide_root_noise:hint'),
      ],
    );
    return SettingsDialog(
      title: [i18n.tr('general settings title'), if (configFile.isNotEmpty) configFile].join(': '),
      actionLabel: i18n.tr('update settings'),
      onAction: _update,
      width: 1000,
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth > 760
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: engineSection),
                  const SizedBox(width: 32),
                  Expanded(flex: 2, child: general),
                ],
              )
            : Column(children: [engineSection, const SizedBox(height: 24), general]),
      ),
    );
  }
}
