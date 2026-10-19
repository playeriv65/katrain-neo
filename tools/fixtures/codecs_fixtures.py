"""Codec fixtures: Python's bytes.decode(errors="ignore") on random byte strings for every codec the port has, codec
name lookup, encoding guesses for SGF files without CA, and pysgf's parse_file on files with CA.

The guesses are the port's own (pysgf uses chardet, which is not ported); chardet's answer is recorded next to them
for reference only.
"""

import codecs
import os
import random
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "port"))

from codecs_gen import MULTIBYTE, OTHER, SINGLE_BYTE  # noqa: E402

_errors = []


def _count(e):
    _errors.append((e.start, e.end))
    return ("", e.end)


codecs.register_error("katrain_neo_count", _count)


def decode(data, codec):
    _errors.clear()
    text = data.decode(codec, errors="katrain_neo_count")
    return text, len(_errors)


def build():
    import chardet

    from katrain.core.game import KaTrainSGF

    rng = random.Random(4321)

    def valid_sequences(codec):
        """Byte sequences that decode to one character, sampled from all pairs (and longer sequences)."""
        seqs = []
        for lead in range(0x80, 0x100):
            for trail in range(0x30, 0x100):
                data = bytes([lead, trail])
                try:
                    if len(data.decode(codec)) == 1:
                        seqs.append(data)
                except UnicodeDecodeError:
                    pass
        if codec == "gb18030":
            seqs += [bytes([rng.randint(0x81, 0x84), rng.randint(0x30, 0x39), rng.randint(0x81, 0xFE),
                            rng.randint(0x30, 0x39)]) for _ in range(300)]
            seqs += [bytes([rng.randint(0x90, 0xE3), rng.randint(0x30, 0x39), rng.randint(0x81, 0xFE),
                            rng.randint(0x30, 0x39)]) for _ in range(100)]
        if codec == "euc_jp":
            seqs += [bytes([0x8F, rng.randint(0xA1, 0xFE), rng.randint(0xA1, 0xFE)]) for _ in range(300)]
        if codec == "euc_kr":
            jamo = [bytes([0xA4, 0xD4, 0xA4, rng.randint(0xA1, 0xBE), 0xA4, rng.randint(0xBF, 0xD3), 0xA4,
                           rng.choice([0xD4, rng.randint(0xA1, 0xBE)])]) for _ in range(100)]
            seqs += jamo
        return seqs

    def random_bytes(seqs, length):
        out = bytearray()
        while len(out) < length:
            r = rng.random()
            if seqs and r < 0.55:
                out += rng.choice(seqs)
            elif r < 0.75:
                out += bytes([rng.randint(0x20, 0x7E)])
            else:
                out += bytes([rng.randint(0, 255)])
        if rng.random() < 0.3:
            out = out[: rng.randint(0, len(out))]  # cut anywhere, also inside a sequence
        return bytes(out)

    decoding = []
    for codec in MULTIBYTE + SINGLE_BYTE + OTHER:
        if codec in MULTIBYTE:
            seqs = valid_sequences(codec)
        elif codec.startswith("utf"):
            chars = [chr(rng.choice([rng.randint(0x80, 0x7FF), rng.randint(0x800, 0xD7FF), rng.randint(0xE000, 0xFFFD),
                                     rng.randint(0x10000, 0x10FFFF)])) for _ in range(200)]
            base = codec.replace("_sig", "")
            seqs = [c.encode(base if base not in ("utf_16", "utf_32") else base + "_le") for c in chars]
        else:
            seqs = []
        for _ in range(60):
            data = random_bytes(seqs, rng.randint(1, 60))
            if codec in ("utf_8_sig", "utf_16", "utf_32") and rng.random() < 0.5:
                data = {"utf_8_sig": b"\xef\xbb\xbf", "utf_16": b"\xfe\xff", "utf_32": b"\x00\x00\xfe\xff"}[codec] + data
            text, errors = decode(data, codec)
            decoding.append({"codec": codec, "bytes": data.hex(), "text": text, "errors": errors})

    names = [
        "UTF-8", "utf8", "UTF_8", " utf-8 ", "U8", "utf-8-sig", "GB2312", "gb2312-80", "GBK", "CP936", "ms936",
        "GB18030", "gb18030-2000", "Big5", "big5-tw", "csbig5", "cp950", "ms950", "SJIS", "Shift-JIS", "Shift_JIS",
        "ms_kanji", "csshiftjis", "cp932", "Windows-31J", "EUC-JP", "eucjp", "EUC-KR", "euckr", "KS_C_5601-1987",
        "ksc5601", "cp949", "uhc", "johab", "ISO-8859-1", "latin1", "Latin-1", "l1", "iso_8859_1", "Windows-1252",
        "cp1252", "windows-1251", "koi8-r", "US-ASCII", "ascii", "646", "UTF-16", "utf-16le", "UTF-32BE", "mac-roman",
        "macintosh", "tis-620", "ISO-8859-15", "latin9", "no-such-codec", "", "utf 8", "utf--8", ".utf8", "UTF8.",
    ]
    sample = bytes(range(256)) + "棋譜 바둑 囲碁 Go".encode("utf-8")
    lookups = []
    for name in names:
        try:
            info = codecs.lookup(name)
        except LookupError:
            lookups.append({"name": name, "text": None})
            continue
        lookups.append({"name": name, "codec": info.name, "text": decode(sample, name)[0]})

    def sgf(text, ca=None):
        fields = f"PB[{text[0]}]PW[{text[1]}]" + (f"EV[{text[2]}]" if len(text) > 2 else "")
        fields += f"C[{text[3]}]" if len(text) > 3 else ""
        return f"(;GM[1]FF[4]{'CA[' + ca + ']' if ca else ''}SZ[19]{fields};B[pd];W[dp])"

    samples = [
        ("zh", "gb18030", ("柯洁", "古力", "第二十届三星杯世界围棋大师赛决赛", "黑中盘胜。这一步是本局的败着，白棋抓住机会")),
        ("zh-names", "gb18030", ("柯洁", "古力")),
        ("zh-names-2", "gb18030", ("芈昱廷", "辜梓豪")),
        ("zh-trad", "cp950", ("周俊勳", "林至涵", "第二十屆三星杯世界圍棋大師賽決賽", "黑中盤勝。這一步是本局的敗著")),
        ("ja", "cp932", ("井山裕太", "芝野虎丸", "第45期名人戦七番勝負第3局", "黒中押し勝ち。この手が敗着でした")),
        ("ja-kanji", "cp932", ("井山裕太", "一力遼", "第45期名人戦")),
        ("ja-euc", "euc_jp", ("井山裕太", "芝野虎丸", "第45期名人戦七番勝負第3局", "黒中押し勝ち。この手が敗着でした")),
        ("ko", "cp949", ("이세돌", "박정환", "제25회 삼성화재배 월드바둑마스터스 결승", "흑 불계승. 이 수가 패착입니다")),
        ("latin", "cp1252", ("Müller", "Ørsted", "Européen Championnat à Zürich", "Très bon coup ! Ça gagne.")),
        ("utf8", "utf_8", ("柯洁", "이세돌", "井山裕太 vs Müller")),
    ]
    guesses = []
    for name, codec, text in samples:
        data = sgf(text).encode(codec if codec != "gb18030" else "gbk")
        guesses.append({"name": name, "bytes": data.hex(), "expected": codec, "text": data.decode(codec),
                        "chardet": chardet.detect(data[:300])["encoding"]})
    for name, bom, codec in [("utf8-bom", b"\xef\xbb\xbf", "utf_8_sig"), ("utf16-le", b"\xff\xfe", "utf_16"),
                             ("utf16-be", b"\xfe\xff", "utf_16")]:
        text = sgf(("柯洁", "Müller"))
        base = {"utf_8_sig": "utf_8", "utf_16": "utf_16_le" if bom == b"\xff\xfe" else "utf_16_be"}[codec]
        data = bom + text.encode(base)
        guesses.append({"name": name, "bytes": data.hex(), "expected": codec, "text": text, "chardet": None})

    # files with CA (and Fox files, read as UTF-8): pysgf's parse_file, exactly
    files = []
    for ca, codec, text in [
        ("GB2312", "gb2312", ("柯洁", "古力", "三星杯")), ("gbk", "gbk", ("柯洁", "古力", "三星杯")),
        ("Big5", "big5", ("周俊勳", "林至涵", "決賽")), ("SJIS", "shift_jis", ("井山裕太", "芝野虎丸", "名人戦")),
        ("EUC-KR", "euc_kr", ("이세돌", "박정환", "결승")), ("UTF-8", "utf_8", ("柯洁", "이세돌", "井山")),
        ("ISO-8859-1", "latin_1", ("Müller", "Ørsted", "café")), ("no-such-codec", "utf_8", ("柯洁", "a", "b")),
        ("cp1252", "cp1252", ("Müller", "Œuvre", "€uro")), ("gb2312", "gbk", ("柯洁", "镕", "碁")),
    ]:
        data = sgf(text, ca).encode(codec)
        files.append(("game.sgf", data))
    files.append(("game.sgf", b"(;GM[1]FF[4]AP[foxwq]CA[gb2312]PB[" + "柯洁".encode("utf-8") + b"]SZ[19];B[pd])"))
    files.append(("game.sgf", b"(;GM[1]CA[GB\r2312]PB[" + "柯洁".encode("gbk") + b"])"))  # \r inside the value
    files.append(("game.sgf", b"(;GM[1]CA[g\xffb\xfek]PB[" + "柯洁".encode("gbk") + b"])"))  # non-ASCII in the value
    parsed = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, (file_name, data) in enumerate(files):
            path = os.path.join(tmp, f"{i}_{file_name}")
            with open(path, "wb") as fh:
                fh.write(data)
            root = KaTrainSGF.parse_file(path)
            parsed.append({"file_name": file_name, "bytes": data.hex(), "PB": root.get_property("PB"),
                           "PW": root.get_property("PW"), "EV": root.get_property("EV")})
    return {"decoding": decoding, "lookups": lookups, "guesses": guesses, "files": parsed}
