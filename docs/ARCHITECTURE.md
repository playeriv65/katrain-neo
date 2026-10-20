# Architecture

KaTrain Neo is one Flutter desktop app written only in Dart, a pure Dart core it is built on, and a command line
client for its local API. Windows is the main target; macOS and Linux are built in CI.

```
app/                       the Flutter app
  lib/main.dart            start-up: settings, translations, the controller, the API server, the window
  lib/src/state/           AppController and what it keeps: the clock, board view state, graph, move tree layout,
                           the API host, sounds
  lib/src/ui/              main screen, top and bottom bars, side panel, menu, keyboard shortcuts, score graph,
                           move tree
  lib/src/ui/board/        the board: geometry, textures, painters, input
  lib/src/ui/popups/       the dialogs: new game, timer, teacher, AI, settings, engine files, load and save, report,
                           re-analysis, tsumego frame, engine failure
packages/katrain_core/     pure Dart, no Flutter imports, tested with `dart test`
  lib/katrain_core.dart    the library the app uses; io.dart adds files, processes and sockets; api.dart the API
  lib/src/sgf/             SGF, NGF and GIB parsing and writing; codecs for legacy encodings
  lib/src/rules/           the board along a game tree: chains, captures, ko, setup stones; rulesets
  lib/src/game/            Game and GameNode: navigation, analysis, insert mode, self-play, teaching, scoring,
                           saving; the AI strategies and game report; players; the tsumego frame
  lib/src/engine/          KataGo's analysis protocol; local process and WebSocket transports
  lib/src/config/          settings: defaults, the settings file, HostBase (settings, logging, players)
  lib/src/i18n/            translations
  lib/src/api/             the local API: commands, sandboxes, tsumego mode, HTTP server
packages/katrain_cli/      the `katrain-neo` command (package:args), and the guide for agents
installer/windows/         Inno Setup script
```

## Core

- **Games.** `Game` holds a tree of `GameNode`s and the current node; `BaseGame` (rules) keeps the board position
  there. A node's analysis is KataGo's result for the position after its move, merged as results arrive (partial
  results first). Point loss, evaluation classes and the info text are derived from it.
- **Hosts.** A game talks to the program around it through `GameHost`: settings, players, logging, the status line,
  and `updateState` after anything changed. `HostBase` implements settings, logging and players; the app's
  `AppController` and headless runners (tests, tools) extend it.
- **Engine.** `AnalysisEngine` is what games call: `requestAnalysis` with a node and a callback,
  `terminateQueries`, `stopPondering`. `KataGoEngine` builds queries (rules, komi, moves and setup stones, region of
  interest as `avoidMoves`, priorities, report intervals, pondering) and matches results by id; generations drop the
  results of queries made before a restart or a new game. Transports: a local `katago analysis` process (JSON lines
  over stdin and stdout, stderr to the log) or a remote KataGo over WebSocket that resumes outstanding queries after a
  reconnect. A local KataGo is started for the current game's board size (`maxBoardX/YSizeForNNBuffer`,
  `requireMaxBoardSize`), and restarted when a game on another size begins: by default KataGo pads every board to
  19x19, so a 9x9 position would cost as much as a 19x19 one (3.6x slower on a Radeon 780M with b10c384).
- **AI.** Each strategy (`ai.dart`) waits for the analyses it needs and returns a move with its reasoning. The
  calibrated strategies (rank, weighted, pick, local, tenuki, influence, territory) pick from the policy; their rank
  estimates come from the same formulas.
- **Settings.** A JSON file in `~/.katrain-neo/config.json` with the same sections and keys as KaTrain's, so its
  meaning is shared; files older than `configMinVersion` are replaced by the defaults (with a backup).
- **SGF.** Analysis is stored in `KT` properties (gzipped JSON plus half-precision ownership and policy), readable
  by KaTrain. Files without a `CA` property get their encoding guessed: valid UTF-8, else the CJK codec with the fewest
  errors and the most plausible text, else Windows-1252. Short Korean texts can still be read as Chinese.

## App

- **Controller.** `AppController` (a `ChangeNotifier`) owns the game, the engine, the players and the clock. Every
  user action is a method; the ones that touch the game run in order on one queue (`_enqueue`), and are dropped if the
  game was replaced meanwhile. After each action `_react` makes AI moves, judges teaching moves, keeps pondering and
  redraws. Dialogs are opened through `AppScreen` (`openDialog(AppDialog)`), so the controller has no widgets.
- **Board.** A `CustomPainter` in three layers that repaint independently: board and grid (on resize), stones and
  evaluation dots (on a new position), hints, variations and hover (on analysis and mouse moves). Text is laid out
  once per size.
- **Look.** Material 3, light or dark as the system is, all colours from one seeded scheme except what carries
  meaning: the board's textures, the engine light, and the colours of score, win rate and point loss, which are a
  theme extension (`EvalColors`) with a shade for each mode; `app_theme_test.dart` checks their contrast against the
  surfaces (WCAG 4.5:1). Flutter's own texts (Cancel,
  Close, tooltips, the text field menu) follow the language through `flutter_localizations`. A move's comments come
  from the core as parts (`CommentPart`: text, headings, variations), and variations are links that show them on the
  board. The window is at least 800x600. The arrangement: the board on the left with display toggles above and navigation below; players, clock or
  move tree, graph, statistics and notes on the right; a drawer for players, game and settings. In small windows the
  top bar shows its toggles as icons when their labels do not fit, the bottom bar drops the 10-move steps and
  rotation (their keys still work), and the side panel scrolls rather than squeeze the notes. Chinese, Japanese and
  Korean text falls back to each language's own system font first, so Chinese is not drawn in Japanese forms.
- **Dialogs** read and write settings by path (`ConfigEditor`, e.g. `trainer/eval_thresholds::2`); Enter applies,
  Escape closes, a popup key closes its open popup. A field's label sits above it (`FieldLabel`), so long
  translations wrap instead of covering the value. Files are loaded and saved through the system's dialogs.
- **Keyboard.** Shortcuts (`ui/keyboard.dart`) sit above the navigator; a focused text field keeps its keys. Alt alone
  opens the menu, Tab alone switches between play and analysis.
- **Platform.** The window's size and position are restored (`window_manager`), dropped files are loaded
  (`desktop_drop`), sounds play through `audioplayers`. Model and KataGo download locations are in
  `app/assets/katago/downloads.json`.

## Local API and CLI

The app serves an HTTP API on 127.0.0.1 with a token per run, on port 8765 or the next free one; both are written to
`~/.katrain-neo/api.json`. `KATRAIN_NEO_API=0` turns it off and `KATRAIN_NEO_API_PORT` moves it (settings
`api/enabled` and `api/port` too).

- Commands (`api/commands.dart`) read their arguments through `ApiArgs` and keep their state typed (`Mark`,
  `Snapshot`, `Demo`, `RegisteredVariation`, `TsumegoProblem`). Commands that wait for KataGo await its results.
- Sandboxes are an agent's own cursors in the user's game: their moves become ordinary variations and their analysis
  is kept, but they never move the user's board.
- The tsumego mode loads problems, hides their answers, frames them and searches only the problem's region
  (`regionRoot`: the region's best move counts as no loss). The board can zoom to the problem with the frame hidden.
- `app/lib/src/state/api_host.dart` connects the API to the app; the board draws the API's marks and a pinned
  variation (shared type `PvOverlay`).
- `katrain-neo` (packages/katrain_cli) has one command per API call; `katrain-neo gui` starts the app
  (`KATRAIN_NEO_APP`, or the app next to the command) and waits for its API; `katrain-neo guide` prints the guide for
  agents.

## Testing

- Core: behaviour tests per module (`packages/katrain_core/test`), on fakes for the host and the engine
  (`test/support`). Test game records are in `test/data`. One test runs a real KataGo when `KATAGO_EXE`,
  `KATAGO_MODEL` and `KATAGO_CONFIG` are set, and is skipped otherwise (as in CI).
- CLI: every command's request, usage errors, links, and end to end against an in-test server.
- App: the controller and the clock tested on the real engine with a pretend KataGo behind it
  (`app/test/support/fake_katago.dart`: it records the queries and answers them when the test says so); widget tests
  and headless rendering (`flutter test`). `test/layout_scan_test.dart` lays out the main screen, the menu and every
  dialog in the light and the dark theme, at four window sizes (from the 800x600 minimum) in eight languages, and fails on rows or columns that overflow, text that is cut off
  and content hidden in a sideways scroll; it uses the Windows interface fonts when the machine has them (Chinese,
  Japanese and Korean are scanned only then), and with `NEO_LAYOUT_OUT` (a folder) it saves every screen as a PNG.
  `test/render_test.dart` writes the main screen and the dialogs to PNGs when `NEO_RENDER_SGF` (a game) and
  `NEO_RENDER_OUT` (a folder) are set. Checks never open windows; the app runs hidden with `KATRAIN_NEO_HIDDEN=1`.- CI (GitHub Actions): format, analyze with `--fatal-infos`, all tests, and builds for the three platforms. A `v*` tag
  publishes the builds as a release.

## Roadmap

- **Training:** key moments of your reviewed games become exercises with spaced repetition; re-choose your own
  mistakes with the answer hidden; tsumego mined from your games.
- **Rank:** read your rank from your moves per game phase with KataGo's human network, and practise the weakest phase.
- **Agents:** explanations built only from KataGo's facts and the rules, local knowledge cards, an opt-in student
  profile.
- **Views:** a sub-board that always shows the main variation; trial boards like browser tabs.
- Not planned: distributed training contribution; mobile builds (the architecture does not prevent them).
