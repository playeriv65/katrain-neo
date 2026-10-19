# KaTrain Neo

> **Unofficial.** KaTrain Neo is an independent rewrite of [KaTrain](https://github.com/sanderland/katrain) in
> Flutter and Dart. It is not affiliated with or endorsed by the KaTrain project. The logic is ported from KaTrain,
> whose copyright notice and credits are kept (see [CREDITS.md](CREDITS.md)).

The goal is everything KaTrain does — game review with KataGo, playing against calibrated AIs, teaching mode — with
the same layout and settings, in a smoother, modern desktop app. It talks to a local KataGo process or a remote KataGo
over WebSocket.

**Status:** early development. Nothing is usable yet; see [docs/DESIGN.md](docs/DESIGN.md) for the plan and the parity
checklist. Ported to the core so far, each tested against Python KaTrain: SGF reading and writing, board rules,
constants and translations, the game tree with analysis data, the KataGo engine (local and remote), and the game
logic (navigation, insert mode, extra analysis modes, self-play, teaching undo, scoring, saving), and the AIs (all
strategies, rank estimation, game report), the tsumego frame, settings, and SGF files in legacy encodings. The app has its main screen (board with hints, territory, policy and variations;
players, clock, move tree, graph, stats, comments; menus), all of KaTrain's popups as dialogs (new game, timer,
teacher, AI, general and engine settings with model and KataGo downloads, load and save, re-analysis, report, tsumego
frame, engine recovery), its keyboard shortcuts, sounds, drag and drop, and window placement. The agent API and CLI,
and installers, come next.

## Layout

| Path | What |
| --- | --- |
| `app/` | The Flutter desktop app (UI). |
| `packages/katrain_core/` | Pure Dart core: rules, SGF, game tree, KataGo protocol, AIs. No Flutter imports. |
| `tools/` | Scripts, e.g. generating test fixtures from Python KaTrain. |
| `docs/` | Design and notes. |

## Development

Requires Flutter 3.47 (stable) with desktop support for your platform.

```sh
flutter pub get                               # resolves the whole workspace
cd packages/katrain_core && dart test          # core tests (fixtures are relative to the package)
cd app && flutter analyze && flutter test     # app checks
cd app && flutter run -d windows              # run (or macos / linux)
```

## License

MIT, see [LICENSE](LICENSE). KataGo is by David J Wu (lightvector) and is not included in this repository.
