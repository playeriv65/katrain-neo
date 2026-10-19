// KaTrain's right column (katrain/app.kv PlayAnalyzeSelect and ControlsPanel), as Material cards: the play/analysis
// switch, the players with their captures, the clock with undo and resign (play) or the move tree (analysis), and
// the collapsable score graph, move statistics and info/notes panels with their toggles.

import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'board/board_images.dart';
import 'move_tree.dart';
import 'score_graph.dart';

class SidePanel extends StatelessWidget {
  final AppController app;
  final BoardImages images;
  const SidePanel({super.key, required this.app, required this.images});

  @override
  Widget build(BuildContext context) {
    final graphPanel = app.panels['graph_panel']!;
    final statsPanel = app.panels['stats_panel']!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 12, 12),
      child: LayoutBuilder(
        builder: (context, c) {
          final graphHeight = (c.maxHeight * 0.2).clamp(110.0, 260.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Tooltip(
                message: 'Tab',
                child: SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: modePlay,
                      icon: const Icon(Icons.sports_esports_outlined),
                      label: Text(i18n.tr('btn:Play')),
                    ),
                    ButtonSegment(
                      value: modeAnalyze,
                      icon: const Icon(Icons.biotech_outlined),
                      label: Text(i18n.tr('btn:Analysis')),
                    ),
                  ],
                  selected: {app.mode},
                  onSelectionChanged: (s) => app.selectMode(s.first),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: PlayerCard(app: app, player: 'B'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: PlayerCard(app: app, player: 'W'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (app.mode == modePlay)
                _ClockCard(app: app)
              else
                SizedBox(
                  height: graphPanel.open ? 96 : 96 + graphHeight,
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: MoveTree(app: app, minHeight: 96),
                  ),
                ),
              const SizedBox(height: 8),
              _PanelCard(
                app: app,
                id: 'graph_panel',
                title: i18n.tr('closedlabel:scoregraph'),
                options: const ['score', 'winrate', 'points'],
                colors: [KTheme.scoreColor, KTheme.winrateColor, KTheme.pointlossColor],
                child: SizedBox(
                  height: graphHeight,
                  child: ScoreGraph(
                    app: app,
                    images: images,
                    showScore: graphPanel.options['score']!,
                    showWinrate: graphPanel.options['winrate']!,
                    showPointloss: graphPanel.options['points']!,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _PanelCard(
                app: app,
                id: 'stats_panel',
                title: i18n.tr('closedlabel:movestats'),
                options: const ['score', 'winrate', 'points'],
                colors: [KTheme.scoreColor, KTheme.winrateColor, KTheme.pointlossColor],
                child: _Stats(app: app, options: statsPanel.options),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _PanelCard(
                  app: app,
                  id: 'notes_panel',
                  title: i18n.tr('closedlabel:info&notes'),
                  options: const ['info', 'info-details', 'notes'],
                  colors: [KTheme.infoTabFontColor, KTheme.infoTabFontColor, KTheme.notesTabFontColor],
                  expand: true,
                  child: _InfoAndNotes(app: app),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class PlayerCard extends StatelessWidget {
  final AppController app;
  final String player;

  /// The game report shows the players without captures or whose turn it is.
  final bool inGame;
  const PlayerCard({super.key, required this.app, required this.player, this.inGame = true});

  @override
  Widget build(BuildContext context) {
    final info = app.playersInfo[player]!;
    final active = inGame && app.game?.currentNode.nextPlayer == player;
    final captures = inGame ? '${app.game?.prisonerCount[player] ?? 0}' : '';
    // PlayerInfo.set_label: the name where we have one, otherwise what they are, and the rank
    final showName = info.name.isNotEmpty && info.playerType == playerHuman && info.playerSubtype == playingNormal;
    var subtitle = showName ? info.name : i18n.tr(info.playerSubtype);
    final rank = info.playerType == playerHuman ? info.sgfRank : rankLabel(info.calculatedRank);
    if (rank != null &&
        rank.isNotEmpty &&
        info.playerSubtype != playingTeaching &&
        (showName || info.playerType == playerAi)) {
      subtitle += ' ($rank)';
    }
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: active ? scheme.primary : Colors.transparent, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Tooltip(
              message: i18n.tr('captures'),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: KTheme.stoneColors[player],
                child: Text(
                  captures,
                  style: text.titleMedium!.copyWith(
                    color: KTheme.circleTextColors[player],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(i18n.tr(info.playerType), maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleMedium),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClockCard extends StatelessWidget {
  final AppController app;
  const _ClockCard({required this.app});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: app.clock.ticks,
                builder: (context, _, _) {
                  final t = app.clock;
                  final secs = t.timeRemaining + 0.99;
                  final time =
                      '${(secs ~/ 60).toString().padLeft(2)}:${(secs % 60).toInt().toString().padLeft(2, '0')}';
                  final color = t.timeout ? KTheme.timerTextTimeoutColor : KTheme.timerTextColor;
                  return Row(
                    children: [
                      Text(
                        time,
                        style: Theme.of(context).textTheme.displaySmall!
                            .copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                      if (t.periodsRemaining != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          '×${t.periodsRemaining}',
                          style: Theme.of(context).textTheme.titleMedium!.copyWith(color: color),
                        ),
                      ],
                      const Spacer(),
                      IconButton.filledTonal(
                        tooltip: 'Pause',
                        isSelected: t.paused,
                        selectedIcon: Icon(Icons.play_arrow, color: KTheme.pauseActiveColor),
                        icon: const Icon(Icons.pause),
                        onPressed: () => t.paused = !t.paused,
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: app.undoSmart,
                    icon: const Icon(Icons.undo),
                    label: Text(i18n.tr('undo-button-text')),
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: app.resign,
                    icon: const Icon(Icons.flag_outlined),
                    label: Text(i18n.tr('resign')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A collapsable panel (KaTrain's CollapsablePanel): toggles for its parts, and a button that folds it away.
class _PanelCard extends StatelessWidget {
  final AppController app;
  final String id;
  final String title;
  final List<String> options;
  final List<Color> colors;
  final Widget child;
  final bool expand;
  const _PanelCard({
    required this.app,
    required this.id,
    required this.title,
    required this.options,
    required this.colors,
    required this.child,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final panel = app.panels[id]!;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
      child: Row(
        children: [
          if (panel.open)
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final (i, option) in options.indexed)
                    FilterChip(
                      label: Text(i18n.tr('tab:$option')),
                      selected: panel.options[option]!,
                      showCheckmark: false,
                      selectedColor: colors[i].withValues(alpha: 0.25),
                      side: BorderSide(color: panel.options[option]! ? colors[i] : Colors.transparent),
                      labelStyle: TextStyle(color: panel.options[option]! ? colors[i] : null),
                      onSelected: (v) => app.setPanelState(id, options: {option: v}),
                    ),
                ],
              ),
            )
          else
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
          IconButton(
            icon: Icon(panel.open ? Icons.expand_less : Icons.expand_more),
            onPressed: () => app.setPanelState(id, state: panel.open ? 'close' : 'open'),
          ),
        ],
      ),
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: expand && panel.open ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (panel.open) expand ? Expanded(child: child) : child,
        ],
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  final AppController app;
  final Map<String, bool> options;
  const _Stats({required this.app, required this.options});

  @override
  Widget build(BuildContext context) {
    final lost = app.statsPointsLost;
    final rows = [
      if (options['winrate']!) (i18n.tr('stats:winrate'), app.statsWinrate, KTheme.winrateColor),
      if (options['score']!) (i18n.tr('stats:score'), app.statsScore, KTheme.scoreColor),
      if (options['points']!)
        (
          i18n.tr(lost == null || lost > 0 ? 'stats:pointslost' : 'stats:pointsgained'),
          lost != null ? '${i18n.tr('short color ${app.statsPlayer}')}: ${pyFixed(lost.abs(), 1)}' : '…',
          KTheme.pointlossColor,
        ),
    ];
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        children: [
          for (final (label, value, color) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(child: Text(label, style: text.bodyLarge)),
                  Text(
                    value,
                    style: text.titleMedium!.copyWith(color: color, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The status line, the comments of the move (with clickable variations), and the notes.
class _InfoAndNotes extends StatefulWidget {
  final AppController app;
  const _InfoAndNotes({required this.app});

  @override
  State<_InfoAndNotes> createState() => _InfoAndNotesState();
}

class _InfoAndNotesState extends State<_InfoAndNotes> {
  final _note = TextEditingController();
  final _noteFocus = FocusNode();

  @override
  void dispose() {
    _note.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final options = app.panels['notes_panel']!.options;
    final showInfo = options['info']! || options['info-details']!;
    if (!_noteFocus.hasFocus && _note.text != app.noteText) _note.text = app.noteText;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (app.statusText.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: app.statusIsError ? scheme.errorContainer : scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              app.statusText,
              style: TextStyle(color: app.statusIsError ? scheme.onErrorContainer : scheme.onSecondaryContainer),
            ),
          ),
        if (showInfo)
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _InfoText(app: app),
            ),
          ),
        if (options['notes']!)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: TextField(
                controller: _note,
                focusNode: _noteFocus,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(hintText: i18n.tr('SGF Notes Hint'), border: const OutlineInputBorder()),
                onChanged: app.setNote,
                onTapOutside: (_) => _noteFocus.unfocus(), // shortcuts work again once you click elsewhere
              ),
            ),
          ),
        if (!showInfo && !options['notes']!) const Spacer(),
      ],
    );
  }
}

/// The comments, with KaTrain's variation links `[u][ref=...][color=...]` clickable and `[color=...]` coloured.
class _InfoText extends StatelessWidget {
  final AppController app;
  const _InfoText({required this.app});

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    final markup = RegExp(
      r'\[u\]\[ref=([^\]]*)\]\[color=([^\]]*)\](.*?)\[/color\]\[/ref\]\[/u\]|\[color=([^\]]*)\](.*?)\[/color\]',
      dotAll: true,
    );
    var last = 0;
    final text = app.infoText;
    Color parse(String hex) =>
        Color(int.parse('FF${hex.replaceFirst('#', '').padRight(6, '0').substring(0, 6)}', radix: 16));
    for (final m in markup.allMatches(text)) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
      if (m[1] != null) {
        final pv = m[1]!;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  final node = app.activeCommentNode?.parent;
                  if (node != null) app.board.setHoverPv(pv.substring(1).split(' '), node, enabled: true);
                },
                child: Text(
                  m[3]!,
                  style: TextStyle(color: parse(m[2]!), decoration: TextDecoration.underline),
                ),
              ),
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m[5],
            style: TextStyle(color: parse(m[4]!)),
          ),
        );
      }
      last = m.end;
    }
    spans.add(TextSpan(text: text.substring(last)));
    return SelectionArea(
      child: Text.rich(TextSpan(children: spans), style: Theme.of(context).textTheme.bodyMedium!.copyWith(height: 1.4)),
    );
  }
}
