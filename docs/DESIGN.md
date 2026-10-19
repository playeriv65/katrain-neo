# KaTrain Neo — design

KaTrain Neo is an unofficial, independent rewrite of [KaTrain](https://github.com/sanderland/katrain) in Flutter and
Dart. It aims for feature and UI parity with KaTrain, with a smoother and more modern interface. The logic is ported
from KaTrain (MIT, © Sander Land and contributors); it is not affiliated with or endorsed by the KaTrain project.

## Goals

- Everything KaTrain does: the same functions, controls, settings and shortcuts, and the same game logic (tested
  against KaTrain). The interface is not a copy of KaTrain's Kivy look: it uses natural, modern Flutter components
  (Material 3), with the board's information shown as KaTrain shows it.
- Smooth: resizing, hovering and continuous analysis at display refresh rate.
- Strong engines: a local KataGo process (any backend, e.g. our ROCm build) or a remote KataGo over WebSocket (e.g. a
  cloud GPU). No in-browser or reimplemented engine.
- Compatible: reads and writes the same SGF files, including KaTrain's analysis data (`KT`), so files move freely
  between KaTrain and KaTrain Neo.
- The agent API and CLI from our KaTrain fork (playeriv65/katrain), so coding agents can drive KaTrain Neo the same
  way: the same commands, as `katrain-neo` instead of `katrain`.

## Non-goals (for now)

- Distributed training contribution (`contribute_engine.py`): rarely used, large, can come last or never.
- Mobile builds. The architecture does not prevent them (a phone can use a remote engine), but they are not a target.
- New features beyond KaTrain. Ideas from other projects (training loops, spaced repetition, rank reading) are listed
  at the end and come after parity.

## Architecture

One Flutter desktop app, written in Dart only. Windows first; macOS and Linux built in CI.

```
app/                      Flutter application (UI only)
  lib/ui/board/           board painter and hit testing
  lib/ui/panels/          players, graph, stats, info/notes, move tree, timer
  lib/ui/popups/          new game, AI, teacher, timer, settings, load/save, report, tsumego frame, analysis
  lib/ui/menus/           hamburger menu, analysis dropdown, top toggles, bottom navigation
  lib/controller/         app controller: the logic of KaTrain's __main__.py (message flow, AI moves, teaching undo)
packages/katrain_core/    pure Dart, no Flutter imports; unit tested on its own
  rules/                  board, chains, captures, ko, suicide per ruleset, scoring
  sgf/                    SGF parse/write (+ KT analysis data), later NGF and GIB
  game/                   game tree, nodes, variations, shortcuts, insert mode
  analysis/               analysis results, candidate moves, points lost, policy ranking
  engine/                 KataGo analysis protocol: query building, local process, remote WebSocket, priorities
  ai/                     the AI strategies, ported one by one
  report/                 game report, rank estimation
  tsumego/                tsumego frame
  config/                 settings model and persistence
```

Why pure Dart and not a Python sidecar: the analysis viewer does not need KaTrain's Python at all, and the rest of
KaTrain's core is about 6000 lines, small enough to port with tests. One language and one process keep packaging
simple.

### Settings

Same keys and file format as KaTrain (its defaults, saved like Kivy's JsonStore), but in `~/.katrain-neo` instead of
`~/.katrain`, so KaTrain Neo and KaTrain never overwrite each other's settings.

### File encodings

Files are decoded exactly as KaTrain decodes them (Python's `bytes.decode(..., errors="ignore")`), with tables
generated from CPython's codecs. Without a `CA` property KaTrain asks chardet (LGPL, not ported) about the first 300
bytes; KaTrain Neo guesses from the whole file instead (valid UTF-8; else the CJK codec with the fewest errors and the
most plausible text; Windows-1252 for western text). Short Korean texts can still be read as Chinese.

### Engine

KaTrain talks to KataGo's JSON analysis engine; KaTrain Neo uses the same protocol and builds the same queries
(rules, komi, moves, initial stones, avoidMoves for regions, priorities, report intervals, pondering). Two transports
behind one interface:

- Local: start `katago analysis -model ... -config ...`, JSON lines over stdin/stdout, stderr to the log.
- Remote: JSON lines over WebSocket, compatible with the remote backend of our KaTrain fork (`ws://...`).

### Agent API and CLI

Ported from our KaTrain fork (`katrain/api/`, `katrain/cli.py`), with the same commands, arguments and JSON results,
so the fork's agent guide applies (`katrain-neo guide` prints it with the new name):

- `katrain_core/lib/api.dart`: node references, coordinates and JSON (model), every command (including sandboxes and
  the tsumego mode), and the HTTP server: 127.0.0.1 only, a token per run, port 8765 or the next free one, written
  with the token to `~/.katrain-neo/api.json`. `KATRAIN_NEO_API=0` turns it off, `KATRAIN_NEO_API_PORT` moves it;
  settings `api/enabled` and `api/port` too.
- The app implements `ApiHost` (`app/lib/src/state/api_host.dart`): the board shows the API's marks, a pinned
  variation (it survives hovering, a click clears it) and the zoomed tsumego view (only the problem's part of the
  board, the frame stones hidden; KataGo still sees them).
- `packages/katrain_cli`: the `katrain-neo` command, a pure Dart program with the fork's argument rules. `katrain-neo
  gui` starts the app (`KATRAIN_NEO_APP`, or the app next to the CLI) and waits for its API.
- In the core, `regionRoot` (from the fork): a region analysis that also counts as the node's evaluation, used by the
  tsumego frame so the local best move shows no loss. Off by default, so KaTrain's own behaviour is unchanged.

The commands were checked once against the fork: the same script of 182 commands (all of them, with their error
cases) through the fork's Python command handler and through the port, with the same synthetic engine answers, gave
the same results, events and states. Two differences remain, both from CPython set order: which stone of a chain
comes first (the tsumego target is reported as another stone of the same group) and the order of handicap stones in
`AB`. The check is not kept as a test. Differences on purpose: starting any new game clears the zoomed view (the
fork clears it only for games loaded through its API).

### UI

- The board is a `CustomPainter` with three layers that repaint independently: board and grid (only on resize),
  stones and evaluation dots (on position change), hints, PV and hover (on analysis and mouse move). Text is laid out
  once per size, not rasterised per frame.
- State lives in a plain `ChangeNotifier` (`KaTrainGui`, the port of KaTrain's controller with its message queue),
  no state management package.
- The arrangement follows KaTrain (board on the left; players, clock or move tree, score graph, stats and info/notes
  on the right; display toggles and the analysis menu on top; navigation below; a drawer for players, game and
  settings), built from Material 3 parts: segmented buttons, filter chips, cards, menus, dialogs, tooltips with the
  keyboard shortcuts. The board keeps KaTrain's textures, hint colours and labels.
- Popups are Material dialogs that read and write settings by KaTrain's paths (`ConfigEditor`, the port of
  `QuickConfigGui`); Enter applies a settings dialog, Escape closes it, and the popup keys (F2–F10) close an open
  popup as in KaTrain. Loading and saving use the system's file dialogs instead of KaTrain's file browser. Unlike
  KaTrain, which keeps each popup once built, a dialog is built afresh each time from the settings, so text typed
  but not applied (e.g. player names) is not kept.
- Keyboard shortcuts (`ui/keyboard.dart`) sit above the navigator so they see every key; a focused text field keeps
  its keys. Alt alone opens the menu, Tab alone switches between play and analysis.
- The window's size and position are restored and saved on closing (`window_manager`), files dropped on the window
  are loaded (`desktop_drop`), sounds play through `audioplayers`. Model and KataGo download locations (KaTrain's)
  are in `app/assets/katago/downloads.json`.
- Fonts: the system's for the interface; Roboto (Apache-2.0, as Kivy ships it) for the board's coordinates and
  numbers.
- Assets: only what KaTrain licenses under MIT is reused, with credit: board and stone textures, sounds. Its menu
  icons and flags (Flaticon, used by KaTrain with permission) and the DIGITAL-7 font (non-commercial) are not;
  KaTrain Neo uses Material icons and language names instead. KataGo binaries and models are never committed, the app downloads or
  points at them.
- Translations: KaTrain's compiled catalogues (by KaTrain's translators) are generated into the core, with credit.

## Parity checklist

Grouped by phase. A feature counts as done when it behaves like KaTrain, verified as described under Testing.

**Phase 1 — analysis viewer**
- Board 9×9 to 19×19 (any size KaTrain supports), coordinates toggle, rotation, move numbers.
- SGF load (file, drag and drop, clipboard), save and save as, with variations, comments and KT analysis data.
- Navigation: next, previous, 5/10 steps, start, end, branches, previous branch, next mistake; move tree with select,
  delete, prune, make main branch, collapse.
- Engine: local and remote KataGo, status dot and queue count, engine recovery prompt.
- Analysis display: hints with KaTrain's colours and labels (top_moves_show options), PV on hover with animation,
  children/next moves, evaluation dots, policy, ownership/territory, region of interest.
- Score and win-rate graph (+ points lost), stats panel, info and notes panels.
- Analysis menu: extra, equalize, sweep, alternatives, continuous analysis, stop, reset, whole-game analysis,
  insert mode, select region, tsumego frame.
- Keyboard shortcuts as in KaTrain.

**Phase 2 — playing**
- New game popup: size, komi, handicap, rules, players (human/AI, normal/teaching).
- Play by click, pass, resign, undo; captures display; game end and manual scoring.
- AI moves with all KaTrain strategies: default, antimirror, handicap, jigo, scoreloss, policy, simple ownership,
  settle stones, weighted, pick, local, tenuki, influence, territory, rank, human, pro; AI settings popup;
  calibrated rank estimate per setting.
- Self-play to end, setup position (setup move / advantage).

**Phase 3 — teaching and the rest**
- Teaching mode: evaluation thresholds, auto undo with fractional undo prompts, mistake sounds, lock AI.
- Timer: main time, byo-yomi periods, minimal use, sounds, pause.
- Game report popup with depth filter.
- Teacher, timer and general settings popups; themes; all 10 languages.
- Tsumego frame (and the zoomed problem view from our fork).

**Phase 4 — agents and packaging**
- The agent HTTP API and `katrain` CLI command set (as `katrain-neo`), so existing agent instructions keep working.
- Installers for Windows, macOS and Linux.

## Testing

- `katrain_core` unit tests: rules (captures, ko, suicide per ruleset, scoring), SGF round trips on KaTrain's own
  test files.
- Differential tests against Python KaTrain: a script runs KaTrain's core on the same inputs and records its outputs as
  fixtures, for example the board and prisoners after every move of the test SGFs, candidate moves and points lost
  from recorded KataGo results, and the move each AI strategy chooses from recorded analyses with fixed random seeds.
  The Dart port must reproduce them exactly.
- UI: widget and golden tests rendered headlessly (`flutter test`), so checks never open windows on the developer's
  desktop. The app is only launched when someone wants to look at it.
- CI on GitHub Actions: `flutter analyze`, tests, and builds for the three desktop platforms.

## Later: ideas from other projects

Collected while surveying other Go training apps, for after parity:

- Training loop: key moments of your reviewed games become exercises with spaced repetition; re-choose your own
  mistakes with the answer hidden; tsumego mined from your games (Masame, AI Sensei, go-tutor).
- Rank read from your moves per game phase with KataGo's human network, and practice for the weakest phase (Masame).
- Trustworthy agent explanations: facts only from KataGo and the rules, tool whitelists, local knowledge cards,
  opt-in student profile (GoAgent, 弈鉴).
- LizGoban-style views: a sub-board that always shows the PV, trial boards like browser tabs.

## Credits and license

MIT. Logic, assets and translations ported from KaTrain keep KaTrain's copyright notice and credits (see
`CREDITS.md`). KataGo is by David Wu (lightvector).
