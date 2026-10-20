// The right column as Material cards: the play/analysis switch, the players with their captures, the clock with
// undo and resign (play) or the move tree (analysis), and the collapsable score graph, move statistics and
// info/notes panels with their toggles.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:katrain_core/katrain_core.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'app_theme.dart';
import 'board/board_images.dart';
import 'move_tree.dart';
import 'score_graph.dart';
import 'stone_avatar.dart';
import 'wheel_steps.dart';

class SidePanel extends StatelessWidget {
  /// The info and notes panel is never squeezed below this.
  static const _minNotesHeight = 140.0;

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
          Widget notes(double fillHeight) => _PanelCard(
            app: app,
            id: 'notes_panel',
            title: i18n.tr('closedlabel:info&notes'),
            options: const ['info', 'info-details', 'notes'],
            fillHeight: fillHeight,
            child: _InfoAndNotes(app: app),
          );
          final top = Column(
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
                // takes the graph's room while the graph folds, in step with it
                TweenAnimationBuilder<double>(
                  tween: Tween(end: graphPanel.open ? 96 : 96 + graphHeight),
                  duration: _foldDuration,
                  curve: _foldCurve,
                  builder: (context, height, child) => SizedBox(height: height, child: child),
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: MoveTree(app: app, minHeight: 96),
                  ),
                ),
              const SizedBox(height: 8),
              // the evaluation would give a tsumego problem's answer away
              if (!app.solvingTsumego) ...[
                _PanelCard(
                  app: app,
                  id: 'graph_panel',
                  title: i18n.tr('closedlabel:scoregraph'),
                  options: const ['score', 'winrate', 'points'],
                  colors: EvalColors.of(context).all,
                  child: SizedBox(
                    height: graphHeight,
                    child: ScoreGraph(
                      app: app,
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
                  colors: EvalColors.of(context).all,
                  child: _Stats(app: app, options: statsPanel.options),
                ),
                const SizedBox(height: 8),
              ],
              // above the notes, so it shows also when they are folded away
              if (app.statusText.isNotEmpty) ...[_StatusLine(app: app), const SizedBox(height: 8)],
            ],
          );
          // The notes fill the room left; when that is less than they need, the whole column scrolls.
          return CustomScrollView(
            slivers: [
              // the wheel steps through the game over everything but the notes
              SliverToBoxAdapter(
                child: WheelSteps(app: app, child: top),
              ),
              SliverLayoutBuilder(
                builder: (context, constraints) => SliverToBoxAdapter(
                  child: notes(
                    math.max(constraints.viewportMainAxisExtent - constraints.precedingScrollExtent, _minNotesHeight),
                  ),
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
    // the name where there is one, otherwise what they are, and the rank
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
              child: StoneAvatar(
                player: player,
                radius: 18,
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
                  final scheme = Theme.of(context).colorScheme;
                  final color = t.timeout ? scheme.error : scheme.onSurface;
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
                        tooltip: '${i18n.tr('timer:pause')} (Pause)',
                        isSelected: t.paused,
                        selectedIcon: const Icon(Icons.play_arrow),
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

/// How long a panel takes to fold or unfold.
const _foldDuration = Duration(milliseconds: 220);
const _foldCurve = Curves.easeInOutCubic;

/// A collapsable panel: toggles for its parts, and a button that folds it away. Its contents slide shut and open.
class _PanelCard extends StatefulWidget {
  /// The header is one line (its toggles shrink a little when they do not fit), so a filling panel knows the room
  /// left for its contents.
  static const headerHeight = 56.0;

  final AppController app;
  final String id;
  final String title;
  final List<String> options;

  /// The colours of the options that stand for an evaluation (score, win rate, point loss); others look plain.
  final List<Color>? colors;
  final Widget child;

  /// The panel's height when open, header included; null sizes it to its contents.
  final double? fillHeight;
  const _PanelCard({
    required this.app,
    required this.id,
    required this.title,
    required this.options,
    this.colors,
    required this.child,
    this.fillHeight,
  });

  @override
  State<_PanelCard> createState() => _PanelCardState();
}

class _PanelCardState extends State<_PanelCard> with SingleTickerProviderStateMixin {
  late final _fold = AnimationController(vsync: this, duration: _foldDuration, value: _open ? 1 : 0)
    ..addStatusListener((_) => setState(() {})); // drop the contents once folded away
  late final _size = CurvedAnimation(parent: _fold, curve: _foldCurve);

  bool get _open => widget.app.panels[widget.id]!.open;

  @override
  void didUpdateWidget(_PanelCard old) {
    super.didUpdateWidget(old);
    _open ? _fold.forward() : _fold.reverse();
  }

  @override
  void dispose() {
    _size.dispose();
    _fold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final id = widget.id;
    final colors = widget.colors;
    final panel = app.panels[id]!;
    final toggles = FittedBox(
      key: const ValueKey('toggles'),
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          for (final (i, option) in widget.options.indexed) ...[
            if (i > 0) const SizedBox(width: 6),
            FilterChip(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              labelPadding: const EdgeInsets.symmetric(horizontal: 2),
              label: Text(i18n.tr('tab:$option')),
              selected: panel.options[option]!,
              showCheckmark: false,
              selectedColor: colors?[i].withValues(alpha: 0.25),
              side: colors == null ? null : BorderSide(color: panel.options[option]! ? colors[i] : Colors.transparent),
              labelStyle: colors == null ? null : TextStyle(color: panel.options[option]! ? colors[i] : null),
              onSelected: (v) => app.setPanelState(id, options: {option: v}),
            ),
          ],
        ],
      ),
    );
    final header = SizedBox(
      height: _PanelCard.headerHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: _foldDuration,
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                child: panel.open
                    ? toggles
                    : Text(widget.title, key: const ValueKey('title'), style: Theme.of(context).textTheme.titleSmall),
              ),
            ),
            IconButton(
              icon: AnimatedRotation(
                turns: panel.open ? 0.5 : 0,
                duration: _foldDuration,
                curve: _foldCurve,
                child: const Icon(Icons.expand_more),
              ),
              onPressed: () => app.setPanelState(id, state: panel.open ? 'close' : 'open'),
            ),
          ],
        ),
      ),
    );
    final fill = widget.fillHeight;
    final body = fill == null
        ? widget.child
        : SizedBox(height: math.max(0, fill - _PanelCard.headerHeight), child: widget.child);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (!_fold.isDismissed) SizeTransition(sizeFactor: _size, alignment: Alignment.topCenter, child: body),
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
    final colors = EvalColors.of(context);
    final rows = [
      if (options['winrate']!) (i18n.tr('stats:winrate'), app.statsWinrate, colors.winrate),
      if (options['score']!) (i18n.tr('stats:score'), app.statsScore, colors.score),
      if (options['points']!)
        (
          i18n.tr(lost == null || lost > 0 ? 'stats:pointslost' : 'stats:pointsgained'),
          lost != null ? '${i18n.tr('short color ${app.statsPlayer}')}: ${formatFixed(lost.abs(), 1)}' : '…',
          colors.pointloss,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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

/// The status line: what just happened or what the engine is doing, red for errors.
class _StatusLine extends StatelessWidget {
  final AppController app;
  const _StatusLine({required this.app});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = app.statusIsError;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: error ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        app.statusText,
        style: TextStyle(color: error ? scheme.onErrorContainer : scheme.onSecondaryContainer),
      ),
    );
  }
}

/// The comments of the move; a variation in them is a link that shows it on the board.
class _InfoText extends StatefulWidget {
  final AppController app;
  const _InfoText({required this.app});

  @override
  State<_InfoText> createState() => _InfoTextState();
}

class _InfoTextState extends State<_InfoText> {
  final _links = <TapGestureRecognizer>[];

  void _disposeLinks() {
    for (final link in _links) {
      link.dispose();
    }
    _links.clear();
  }

  TapGestureRecognizer _link(VoidCallback onTap) {
    final link = TapGestureRecognizer()..onTap = onTap;
    _links.add(link);
    return link;
  }

  @override
  void dispose() {
    _disposeLinks();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final theme = Theme.of(context);
    _disposeLinks();
    final spans = [
      for (final part in app.infoParts)
        switch (part) {
          CommentText(heading: true) => TextSpan(text: part.text, style: theme.textTheme.titleSmall),
          CommentText() => TextSpan(text: part.text),
          CommentVariation(:final moves) => TextSpan(
            text: part.text,
            style: TextStyle(color: theme.colorScheme.primary, decoration: TextDecoration.underline),
            mouseCursor: SystemMouseCursors.click,
            recognizer: _link(() {
              final node = app.activeCommentNode?.parent;
              if (node != null) app.board.setHoverPv(moves, node, enabled: app.showPvs);
            }),
          ),
        },
    ];
    return SelectionArea(
      child: Text.rich(TextSpan(children: spans), style: theme.textTheme.bodyMedium!.copyWith(height: 1.4)),
    );
  }
}
