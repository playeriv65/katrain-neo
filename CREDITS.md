# Credits

KaTrain Neo is a rewrite of **[KaTrain](https://github.com/sanderland/katrain)** by Sander Land and contributors, under
the MIT License. Its design, game logic, AI strategies and their calibration, teaching features, assets and
translations are the work of the KaTrain authors. KaTrain credits, among others:

- "bale-go" for the calibrated rank AI and rank estimation.
- "kaorahi" for the tsumego frame code (ported from LizGoban), bug fixes and SGF parser improvements.
- "nimets123" for the timer sounds and board/stone graphics, Jordan Seaward for the stone sounds, "waltheri" for a
  wooden board texture.
- The translators of KaTrain's languages.

The full list of KaTrain contributors and translators is in KaTrain's
[CONTRIBUTIONS.md](https://github.com/sanderland/katrain/blob/master/CONTRIBUTIONS.md).

Reused from KaTrain (MIT): the board, stone, evaluation dot and graph textures and the sounds, in `app/assets`.
The board's text uses Roboto (Apache License 2.0, `app/assets/fonts/LICENSE-Roboto.txt`), the copy Kivy ships.

Not reused from KaTrain: its menu icons and flags (from Flaticon, used by KaTrain with permission) and the DIGITAL-7 font
(free for non-commercial use only).

**[KataGo](https://github.com/lightvector/KataGo)** is by David J Wu (lightvector) and contributors. It is not part of
this repository.

The SGF parser is ported from **[pysgf](https://github.com/sanderland/pysgf)** (MIT, © 2020 Sander Land), which KaTrain
uses. The test game records in `packages/katrain_core/test/fixtures/inputs/` other than the `edge_*.sgf` files are KaTrain's own test data.

Reading SGF files in legacy encodings (GBK, Big5, Shift_JIS, EUC-KR and others) uses decoding tables generated from
**CPython**'s codecs (`tools/port/codecs_gen.py`), so the text is exactly what KaTrain reads; CPython is
Copyright (c) 2001 Python Software Foundation, under the PSF License. Guessing the encoding of files without a `CA`
property uses the most frequent Chinese, Japanese and Korean characters from
**[charset_normalizer](https://github.com/jawah/charset_normalizer)** (MIT, (c) TAHRI Ahmed R.). KaTrain (through
pysgf) guesses with chardet, which is LGPL and not used here.

When content from KaTrain is ported, the file or the commit says where it comes from.
