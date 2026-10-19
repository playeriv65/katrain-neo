"""Generate the parts of katrain_core that are data taken straight from KaTrain.

    python tools/port/generate.py --katrain <path to a KaTrain checkout>

- lib/src/constants.dart       every constant of katrain/core/constants.py
- lib/src/i18n/strings/*.dart  the translations, read from KaTrain's compiled .mo catalogues (what KaTrain loads)

Uses a Python environment with KaTrain's dependencies (it imports katrain.core.constants).
"""

import argparse
import gettext
import os
import sys
from pathlib import Path

os.environ["KIVY_NO_ARGS"] = "1"
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
REPO = HERE.parent.parent
CORE = REPO / "packages" / "katrain_core" / "lib" / "src"

from dart_literal import camel, dart_string, dart_value, header  # noqa: E402

SCRIPT = "tools/port/generate.py"


def generate_constants(katrain_path: Path):
    import katrain.core.constants as c

    names = [n for n in vars(c) if n.isupper() and not n.startswith("_")]
    lines = [header("katrain/core/constants.py", SCRIPT)]
    for name in names:
        value = getattr(c, name)
        if callable(value) or isinstance(value, type(os)):
            continue
        kind = "final" if isinstance(value, (list, dict, set, tuple, range)) else "const"
        if isinstance(value, float) and value != value:
            kind = "final"
        lines.append(f"{kind} {camel(name)} = {dart_value(value)};\n\n")
    out = CORE / "constants.dart"
    out.write_text("".join(lines).rstrip() + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {out} ({len(names)} constants)")


def generate_strings(katrain_path: Path):
    from katrain.core.lang import Lang

    locale_dir = katrain_path / "katrain" / "i18n" / "locales"
    out_dir = CORE / "i18n" / "strings"
    out_dir.mkdir(parents=True, exist_ok=True)
    langs = []
    for lang_dir in sorted(locale_dir.iterdir()):
        mo = lang_dir / "LC_MESSAGES" / "katrain.mo"
        if not mo.exists():
            continue
        with open(mo, "rb") as fh:
            catalog = gettext.GNUTranslations(fh)._catalog
        entries = {k: v for k, v in catalog.items() if isinstance(k, str) and k}
        lang = lang_dir.name
        langs.append(lang)
        body = "".join(f"  {dart_string(k)}: {dart_string(v)},\n" for k, v in sorted(entries.items()))
        text = header(f"katrain/i18n/locales/{lang}/LC_MESSAGES/katrain.mo", SCRIPT)
        text += f"const Map<String, String> strings{lang.capitalize()} = {{\n{body}}};\n"
        (out_dir / f"{lang}.dart").write_text(text, encoding="utf-8", newline="\n")
        print(f"wrote {out_dir / f'{lang}.dart'} ({len(entries)} strings)")
    index = header("katrain/i18n and katrain/core/lang.py", SCRIPT)
    index += "".join(f"import '{lang}.dart';\n" for lang in langs) + "\n"
    index += "/// Translations by language code, as KaTrain names its locale folders.\n"
    index += "const Map<String, Map<String, String>> translations = {\n"
    index += "".join(f"  '{lang}': strings{lang.capitalize()},\n" for lang in langs) + "};\n\n"
    index += "/// Fonts KaTrain uses for some languages (katrain/core/lang.py, Lang.FONTS).\n"
    index += f"const Map<String, String> languageFonts = {dart_value(Lang.FONTS)};\n"
    (out_dir / "all.dart").write_text(index, encoding="utf-8", newline="\n")
    print(f"wrote {out_dir / 'all.dart'}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--katrain", required=True, help="path to a KaTrain checkout")
    args = parser.parse_args()
    katrain_path = Path(args.katrain).resolve()
    sys.path.insert(0, str(katrain_path))
    generate_constants(katrain_path)
    generate_strings(katrain_path)


if __name__ == "__main__":
    main()
