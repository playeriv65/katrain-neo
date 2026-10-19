# Notes for coding agents

KaTrain Neo is a Flutter/Dart desktop app for Go with KataGo. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first.

## Rules

- `packages/katrain_core` stays pure Dart (no `package:flutter` imports) so it is testable with `dart test`.
- Every change to behaviour comes with tests of the behaviour (what a user or an agent sees), on the fakes in
  `packages/katrain_core/test/support` and `app/test/support` rather than recorded outputs. A bug found and not fixed yet is a skipped test
  with `skip: 'bug: ...'`.
- Keep the settings keys, the SGF analysis format (`KT`, `KTV`) and the local API's commands, arguments and JSON
  results compatible: settings files, game records and agents rely on them. Change them on purpose and say so.
- Comments say what the code does and why, not where it came from.
- Do not commit KataGo binaries or models, or assets under licences that do not allow it (see CREDITS.md).
- Never open app windows during checks: use `dart test`, `flutter test` (widget and golden tests render headlessly)
  and `flutter analyze`. Launch the app only when a person wants to look at it, or with `KATRAIN_NEO_HIDDEN=1`, which
  keeps its window hidden (e.g. to try a real KataGo end to end).
- Code comments and docs in English. Keep the style of the surrounding code; `dart format` with line length 120.

## Commands

```sh
flutter pub get
cd packages/katrain_core && dart test
cd packages/katrain_cli && dart test
dart compile exe packages/katrain_cli/bin/katrain_neo.dart -o katrain-neo   # the CLI as one program
cd app && flutter analyze --fatal-infos && flutter test
dart format -l 120 packages app/lib app/test
```

`app/test/render_test.dart` renders the main screen and every dialog to PNGs when `NEO_RENDER_SGF` (a game) and
`NEO_RENDER_OUT` (a folder) are set.

The test against a real KataGo runs only when `KATAGO_EXE`, `KATAGO_MODEL` and `KATAGO_CONFIG` point at a KataGo
binary, model and analysis config; otherwise it is skipped (as in CI).
