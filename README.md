# KaTrain Neo

A desktop app for reviewing Go games with KataGo, playing against AIs of calibrated strength, and learning from your
mistakes in teaching mode. Built with Flutter and Dart; it talks to a local KataGo process or a remote KataGo over
WebSocket.

KaTrain Neo started as a rewrite of [KaTrain](https://github.com/sanderland/katrain) and keeps its features, settings
and SGF analysis format, so files move freely between the two. It is developed independently and is not affiliated
with or endorsed by the KaTrain project; KaTrain's copyright notice and credits are kept (see [CREDITS.md](CREDITS.md)).

**Status:** early development builds.

## Features

- **Review:** hints with their score, win rate and visits; variations on hover; evaluation dots; policy and territory;
  score, win rate and point loss graphs; move statistics; region of interest; extra, equalize, sweep, alternative and
  whole-game analysis; insert mode; the tsumego frame.
- **Play:** against KataGo at full strength or against the calibrated AIs (rank, weighted, pick, local, tenuki,
  influence, territory, policy, scoreloss, jigo, settle stones, human and pro styles), with handicap, any rules and
  board size, and a byo-yomi clock.
- **Teaching:** moves that lose more than you allow are undone, with the AI's comments; a game report with accuracy
  and point loss per player.
- **Files:** SGF, NGF and GIB, in legacy encodings too (GBK, Big5, Shift_JIS, EUC-KR, ...); drag and drop and the
  clipboard.
- **Agents:** a local API and the `katrain-neo` command let coding agents read and steer the running app.
- 11 languages.

## Install

Builds for Windows (installer or zip), macOS (dmg) and Linux (tar.gz) are attached to each
[release](https://github.com/playeriv65/katrain-neo/releases), and to every CI run as artifacts. They are unsigned
development builds. The `katrain-neo` command sits next to the app (the Windows installer can add it to PATH).

Settings live in `~/.katrain-neo` (KaTrain's own `~/.katrain` is never touched).

## KataGo

KataGo is not included. In the general settings, point the app at your KataGo program and a model, or use the download
buttons there; any backend works (CUDA, TensorRT, OpenCL, Metal, ROCm, Eigen). For a remote KataGo, choose the remote
engine and give its `ws://` or `wss://` address. If KataGo does not start, the engine settings dialog shows the error
and the command line it ran; running that command in a terminal usually tells you what is missing.

## Manual

- **Modes:** Tab switches between analysis and play. In play mode hints are hidden and the clock runs (Pause stops it).
- **Navigation:** arrow keys, `z`/`x` or the scroll wheel (with Shift, 10 moves); Home and End; `n` goes to the next
  mistake, Shift+`n` to the previous one; `b` back to the last branch point, Shift+`b` back to the main line.
- **Display:** `q` next moves, `w` evaluation dots, `e` hints, `r` policy, `t` territory; `k` coordinates, `m` move
  numbers; `` ` `` hides the panels.
- **Analysis:** `a` extra, `s` equalize, `d` sweep, `f` alternatives, `g` select a region, `i` insert mode, `l` play
  to the end, space continuous analysis, Ctrl+H reset.
- **Dialogs:** Ctrl+N new game, Ctrl+L load, Ctrl+S save, Ctrl+D save as; F2 re-analysis, F3 report, F5 timer, F6
  teacher, F7 AI, F8 settings, F10 tsumego frame. Ctrl+C and Ctrl+V copy and paste the game as SGF.

Menu items and toggles show their shortcuts.

## For AI agents: `katrain-neo`

The app serves a local API (127.0.0.1, a token per run in `~/.katrain-neo/api.json`); the `katrain-neo` command
talks to it and prints JSON:

```sh
katrain-neo gui                      # start the app if needed and wait for it
katrain-neo status
katrain-neo analysis run -v 2000     # search the current position
katrain-neo guide                    # the full guide for agents
```

## Development

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the code is organised. Requires Flutter 3.47 (stable) with
desktop support for your platform.

| Path | What |
| --- | --- |
| `app/` | The Flutter desktop app. |
| `packages/katrain_core/` | Pure Dart core: rules, SGF, games, KataGo protocol, AIs, settings, translations, the API. |
| `packages/katrain_cli/` | The `katrain-neo` command line client. |
| `installer/` | The Windows installer script. |

```sh
flutter pub get                                # resolves the whole workspace
cd packages/katrain_core && dart test          # core tests
cd packages/katrain_cli && dart test           # CLI tests
cd app && flutter analyze && flutter test      # app checks
cd app && flutter run -d windows               # run (or macos / linux)
```

## Support

Bugs and ideas: [issues](https://github.com/playeriv65/katrain-neo/issues).

## License

MIT, see [LICENSE](LICENSE). KataGo is by David J Wu (lightvector) and is not included in this repository.
