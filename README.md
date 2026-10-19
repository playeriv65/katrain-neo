# KaTrain Neo

> **Unofficial.** KaTrain Neo is an independent rewrite of [KaTrain](https://github.com/sanderland/katrain) in
> Flutter and Dart. It is not affiliated with or endorsed by the KaTrain project. The logic is ported from KaTrain,
> whose copyright notice and credits are kept (see [CREDITS.md](CREDITS.md)).

The goal is everything KaTrain does — game review with KataGo, playing against calibrated AIs, teaching mode — with
the same layout and settings, in a smoother, modern desktop app. It talks to a local KataGo process or a remote KataGo
over WebSocket.

**Status:** early development. Nothing is usable yet; see [docs/DESIGN.md](docs/DESIGN.md) for the plan and the parity
checklist.

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
dart test packages/katrain_core               # core tests
cd app && flutter analyze && flutter test     # app checks
cd app && flutter run -d windows              # run (or macos / linux)
```

## License

MIT, see [LICENSE](LICENSE). KataGo is by David J Wu (lightvector) and is not included in this repository.
