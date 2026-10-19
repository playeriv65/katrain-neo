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
  and `flutter analyze`. Launch the app only when a person wants to look at it.
- Code comments and docs in English. Keep the style of the surrounding code; `dart format` with line length 120.

## Commands

```sh
flutter pub get
dart test packages/katrain_core
cd app && flutter analyze && flutter test
python tools/fixtures/generate.py --katrain <path to a KaTrain checkout>   # refresh differential fixtures
```
