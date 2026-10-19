"""Generate lib/src/sgf/codecs/tables.dart: decoding tables taken from CPython's codecs.

KaTrain decodes SGF files with Python's `bytes.decode(encoding, errors="ignore")`. To give exactly the same text, the
port decodes with tables read from CPython itself: every single byte and every byte pair of each codec, and the
longer sequences of GB18030, EUC-JP and EUC-KR (make-up sequences). Errors in these codecs skip one byte, and a
sequence cut short by the end of the input drops the rest, which the decoder relies on (checked here). Also writes
charset_normalizer's most frequent CJK characters, for guessing encodings.

    python tools/port/codecs_gen.py      # with charset_normalizer installed, e.g. KaTrain's environment
"""

import base64
import codecs
import encodings.aliases
import gzip
import struct
import sys
from pathlib import Path

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parent.parent.parent
OUT = REPO / "packages" / "katrain_core" / "lib" / "src" / "sgf" / "codecs" / "tables.dart"

MULTIBYTE = ["gb2312", "gbk", "gb18030", "big5", "cp950", "shift_jis", "cp932", "euc_jp", "euc_kr", "cp949", "johab"]
SINGLE_BYTE = [
    "ascii", "latin_1", "cp437", "cp850", "cp852", "cp855", "cp857", "cp858", "cp860", "cp861", "cp862", "cp863",
    "cp865", "cp866", "cp869", "cp874", "cp1250", "cp1251", "cp1252", "cp1253", "cp1254", "cp1255", "cp1256",
    "cp1257", "cp1258", "iso8859_2", "iso8859_3", "iso8859_4", "iso8859_5", "iso8859_6", "iso8859_7", "iso8859_8",
    "iso8859_9", "iso8859_10", "iso8859_11", "iso8859_13", "iso8859_14", "iso8859_15", "iso8859_16", "koi8_r",
    "koi8_u", "mac_roman", "mac_cyrillic", "mac_greek", "mac_iceland", "mac_latin2", "mac_turkish", "tis_620",
]
OTHER = ["utf_8", "utf_8_sig", "utf_16", "utf_16_le", "utf_16_be", "utf_32", "utf_32_le", "utf_32_be"]

ILLEGAL = 0xFFFE  # error: skip this byte
LEAD = 0xFFFF  # the first byte of a longer sequence

spans = []


def _record(e):
    spans.append((e.start, e.end, e.reason))
    return ("", e.end)


codecs.register_error("katrain_neo_record", _record)


def decode(enc, data):
    spans.clear()
    return data.decode(enc, errors="katrain_neo_record"), list(spans)


def packed(values):
    raw = struct.pack(f"<{len(values)}H", *values)
    return base64.b64encode(gzip.compress(raw, compresslevel=9, mtime=0)).decode("ascii")


def single_table(enc):
    table = []
    for b in range(256):
        out, errs = decode(enc, bytes([b]))
        if not errs and len(out) == 1:
            table.append(ord(out))
        elif errs and errs[0][2].startswith("incomplete"):
            table.append(LEAD)
        else:
            assert errs and errs[0][1] - errs[0][0] == 1, (enc, b, errs)
            table.append(ILLEGAL)
    return table


def pair_table(enc, singles):
    """Leads 0x80-0xFF x trails 0x00-0xFF: the character, ILLEGAL (skip the lead), or LEAD (more bytes follow)."""
    table = []
    for lead in range(0x80, 0x100):
        for trail in range(256):
            if singles[lead] != LEAD:
                table.append(ILLEGAL)
                continue
            out, errs = decode(enc, bytes([lead, trail]))
            if errs and errs[0][0] == 0:
                if errs[0][2].startswith("incomplete"):
                    table.append(LEAD)
                else:
                    assert errs[0][1] == 1, (enc, lead, trail, errs)
                    table.append(ILLEGAL)
            else:
                assert len(out) >= 1 and ord(out[0]) < 0xFFFE, (enc, lead, trail, out)
                table.append(ord(out[0]))
    return table


def gb18030_four_byte():
    """Runs of (first linear index, first code point, length) for the four-byte sequences, and a check of errors."""
    runs = []
    for b1 in range(0x81, 0xFF):
        for b2 in range(0x30, 0x3A):
            for b3 in range(0x81, 0xFF):
                for b4 in range(0x30, 0x3A):
                    index = (((b1 - 0x81) * 10 + (b2 - 0x30)) * 126 + (b3 - 0x81)) * 10 + (b4 - 0x30)
                    try:
                        text = bytes([b1, b2, b3, b4]).decode("gb18030")
                    except UnicodeDecodeError as e:
                        assert (e.start, e.end) == (0, 1), (b1, b2, b3, b4, e)
                        continue
                    assert len(text) == 1, (b1, b2, b3, b4)
                    cp = ord(text)
                    if runs and runs[-1][0] + runs[-1][2] == index and runs[-1][1] + runs[-1][2] == cp:
                        runs[-1][2] += 1
                    else:
                        runs.append([index, cp, 1])
    # a broken four-byte sequence is an error on its first byte; one cut short by the end drops the rest
    for data in [b"\x81\x30\x20", b"\x81\x30\x81\x20"]:
        _, errs = decode("gb18030", data + b"ABCD")
        assert errs[0][:2] == (0, 1), (data, errs)
    for data in [b"\x81\x30\x81", b"\x81\x30", b"\x81"]:
        _, errs = decode("gb18030", b"A" + data)
        assert errs == [(1, 1 + len(data), "incomplete multibyte sequence")], (data, errs)
    return [v for run in runs for v in run]


def euc_jp_three_byte():
    """0x8F, then two bytes 0xA1-0xFE (JIS X 0212): the character or ILLEGAL."""
    table = []
    for b2 in range(0xA1, 0xFF):
        for b3 in range(0xA1, 0xFF):
            out, errs = decode("euc_jp", bytes([0x8F, b2, b3]))
            if errs:
                assert errs[0][:2] == (0, 1), (b2, b3, errs)
                table.append(ILLEGAL)
            else:
                table.append(ord(out))
    for data in [b"\x8f\x20", b"\x8f\xa1\x20", b"\x8f\x20\xa1"]:
        _, errs = decode("euc_jp", data + b"ABC")
        assert errs[0][:2] == (0, 1), (data, errs)
    for data in [b"\x8f\xa1", b"\x8f"]:
        _, errs = decode("euc_jp", b"A" + data)
        assert errs == [(1, 1 + len(data), "incomplete multibyte sequence")], (data, errs)
    return table


def euc_kr_make_up():
    """KS X 1001 Annex 3 make-up sequences: A4 D4 A4 c A4 v A4 f is one syllable. The index of each jamo byte
    0xA1-0xFE (or -1) in the choseong, jungseong and jongseong positions, read from Python's decoder."""

    def syllable(c, v, f):
        out, errs = decode("euc_kr", bytes([0xA4, 0xD4, 0xA4, c, 0xA4, v, 0xA4, f]))
        return None if errs else ord(out[0])

    base = (0xA1, 0xBF, 0xD4)  # a valid choseong, jungseong and an empty jongseong
    assert syllable(*base) == 0xAC00
    cho = [-1 if (s := syllable(b, base[1], base[2])) is None else (s - 0xAC00) // 588 for b in range(0xA1, 0xFF)]
    jung = [-1 if (s := syllable(base[0], b, base[2])) is None else (s - 0xAC00) // 28 for b in range(0xA1, 0xFF)]
    jong = [-1 if (s := syllable(base[0], base[1], b)) is None else s - 0xAC00 for b in range(0xA1, 0xFF)]
    # the three are independent: check every combination against Python
    for i, c in enumerate(range(0xA1, 0xFF)):
        for j, v in enumerate(range(0xA1, 0xFF)):
            for k, f in enumerate(range(0xA1, 0xFF)):
                expected = syllable(c, v, f)
                ours = None if -1 in (cho[i], jung[j], jong[k]) else 0xAC00 + cho[i] * 588 + jung[j] * 28 + jong[k]
                assert ours == expected, (hex(c), hex(v), hex(f), expected, ours)
    # an invalid sequence skips its first byte, a short one at the end of the input drops the rest
    _, errs = decode("euc_kr", b"\xa4\xd4\xa4\xa1\xa4\x41\xa4\xd4QRST")
    assert errs[0][:2] == (0, 1), errs
    _, errs = decode("euc_kr", b"\xa4\xd4\xa4\xa1A")
    assert errs == [(0, 5, "incomplete multibyte sequence")], errs
    return cho, jung, jong


def aliases():
    """Normalized names KaTrain's CA values can use, to the codec names supported here."""
    supported = set(MULTIBYTE + SINGLE_BYTE + OTHER)
    result = {}
    for alias, target in sorted(encodings.aliases.aliases.items()):
        if target in supported:
            result[alias] = target
    for name in supported:
        result.setdefault(name, name)
    return dict(sorted(result.items()))


def main():
    lines = [
        "// GENERATED by tools/port/codecs_gen.py from CPython's codecs (Python "
        + ".".join(map(str, sys.version_info[:3]))
        + "). Do not edit; regenerate instead.",
        "// ignore_for_file: lines_longer_than_80_chars",
        "",
        "/// Python's aliases of the supported codecs (`encodings.aliases`), by normalized name.",
        "const Map<String, String> codecAliases = {",
    ]
    lines += [f"  '{k}': '{v}'," for k, v in aliases().items()]
    lines += ["};", "", "/// Single byte codecs: 256 code points, 0xFFFE where Python reports an error (gzip, base64).",
              "const Map<String, String> singleByteTables = {"]
    for enc in SINGLE_BYTE:
        table = single_table(enc)
        assert LEAD not in table, enc
        lines.append(f"  '{enc}': '{packed(table)}',")
    lines += ["};", "", "/// CJK codecs: the 256 single bytes (0xFFFF: a lead byte), then leads 0x80-0xFF x trails",
              "/// 0x00-0xFF (0xFFFE: an error that skips the lead, 0xFFFF: more bytes follow), gzip, base64.",
              "const Map<String, (String, String)> multiByteTables = {"]
    for enc in MULTIBYTE:
        singles = single_table(enc)
        pairs = pair_table(enc, singles)
        lines.append(f"  '{enc}': ('{packed(singles)}', '{packed(pairs)}'),")
    lines += ["};", "", "/// GB18030 four-byte sequences as runs of (linear index, first code point, length), gzip, base64.",
              "/// The linear index of b1 b2 b3 b4 is (((b1 - 0x81) * 10 + b2 - 0x30) * 126 + b3 - 0x81) * 10 + b4 - 0x30."]
    runs = gb18030_four_byte()
    raw = struct.pack(f"<{len(runs)}I", *runs)
    lines.append(f"const String gb18030FourByteRuns = '{base64.b64encode(gzip.compress(raw, 9, mtime=0)).decode()}';")
    lines += ["", "/// EUC-JP 0x8F b2 b3 (JIS X 0212), b2 and b3 from 0xA1 to 0xFE: 94 x 94 code points, 0xFFFE for errors.",
              f"const String eucJpThreeByte = '{packed(euc_jp_three_byte())}';", ""]
    from charset_normalizer.constant import FREQUENCIES

    lines += ["/// The most frequent characters of Chinese, Japanese and Korean text, from charset_normalizer",
              "/// (https://github.com/jawah/charset_normalizer, MIT, (c) TAHRI Ahmed R.), to guess encodings.",
              "const Map<String, String> frequentCharacters = {"]
    for language in ["Chinese", "Japanese", "Korean"]:
        chars = "".join(FREQUENCIES[language])
        if language == "Japanese":
            chars += "".join(FREQUENCIES["Japanese—"]) + "".join(FREQUENCIES["Japanese——"])
        assert "'" not in chars and "\\" not in chars and "$" not in chars
        lines.append(f"  '{language.lower()}': '{chars}',")
    lines += ["};", ""]
    cho, jung, jong = euc_kr_make_up()
    lines += ["/// EUC-KR make-up sequences A4 D4 A4 c A4 v A4 f: the jamo index of each byte 0xA1-0xFE, -1 if invalid.",
              f"const List<int> eucKrChoseong = {cho};", f"const List<int> eucKrJungseong = {jung};",
              f"const List<int> eucKrJongseong = {jong};", ""]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
