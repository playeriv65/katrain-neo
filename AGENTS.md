# Notes for coding agents

KaTrain Neo is a Flutter/Dart rewrite of KaTrain aiming for parity. Read [docs/DESIGN.md](docs/DESIGN.md) first.

## Rules

- Parity first: when porting, behave exactly like KaTrain (`https://github.com/sanderland/katrain`, `katrain/core`).
  Do not "improve" logic while porting; note differences you find instead. New ideas go to the "Later" list in the
  design doc.
- `packages/katrain_core` stays pure Dart (no `package:flutter` imports) so it is testable with `dart test`.
- Every ported module gets tests. Where KaTrain's behaviour is the reference, use the differential fixtures generated
  from Python KaTrain (`tools/fixtures/`), not hand-written expectations.
- Say where ported code comes from in a short header comment (KaTrain file and function).
- Do not commit KataGo binaries or models, or anything from KaTrain that is not MIT (its Flaticon icons, the
  DIGITAL-7 font). See CREDITS.md.
- Never open app windows during checks: use `dart test`, `flutter test` (widget and golden tests render headlessly)
  and `flutter analyze`. Launch the app only when a person wants to look at it, or with `KATRAIN_NEO_HIDDEN=1`, which
  keeps its window hidden (e.g. to try a real KataGo end to end).
- Code comments and docs in English. Keep the style of the surrounding code; `dart format` with line length 120.

## Commands

```sh
flutter pub get
cd packages/katrain_core && dart test
cd app && flutter analyze && flutter test
python tools/fixtures/generate.py --katrain <path to a KaTrain checkout>   # refresh differential fixtures
python tools/port/generate.py --katrain <path to a KaTrain checkout>       # regenerate constants, translations, defaults
python tools/port/codecs_gen.py                                            # regenerate the codec tables (needs charset_normalizer)
dart format -l 120 packages/katrain_core/lib                               # the generators do not format
```

`app/test/render_test.dart` renders the main screen and every popup to PNGs when `NEO_RENDER_SGF` (a game) and
`NEO_RENDER_OUT` (a folder) are set, to compare with screenshots of KaTrain.

The test against a real KataGo runs only when `KATAGO_EXE`, `KATAGO_MODEL` and `KATAGO_CONFIG` point at a KataGo
binary, model and analysis config; otherwise it is skipped (as in CI).
