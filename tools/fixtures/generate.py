"""Generate differential test fixtures from Python KaTrain and pysgf.

The Dart port must reproduce these outputs exactly. Run with a Python environment that has KaTrain's dependencies
(e.g. a KaTrain checkout after `uv sync`):

    python tools/fixtures/generate.py --katrain <path to a KaTrain checkout> [--out <dir>]

Reads the records in packages/katrain_core/test/fixtures/inputs/ and writes next to them:
- sgf_parse.json   every node of every record as pysgf sees it, and the SGF it writes back
- rules_mainline.json  board and captures after every move of each record's main line (KaTrain BaseGame)
- rules_random.json    random move attempts on small boards under several rulesets, with legality and positions
- utils.json           number formatting, half floats, random numbers, translations
- game_node.json       analysis merging, comments and SGF writing (game_node_fixtures.py)
- engine.json          KataGo queries and results (engine_fixtures.py)
- game.json            a script of game operations with the events and state after each (game_fixtures.py)

The output is reproducible: string hashes and the gzip time stamps in KT data are fixed.
"""

import argparse
import json
import os
import random
import sys
from pathlib import Path

os.environ["KIVY_NO_ARGS"] = "1"  # KaTrain imports Kivy, which otherwise parses our command line
if os.environ.get("PYTHONHASHSEED") != "0":
    # set iteration order (e.g. handicap stones) depends on string hashes: run again with fixed ones
    import subprocess

    sys.exit(subprocess.run([sys.executable, *sys.argv], env={**os.environ, "PYTHONHASHSEED": "0"}).returncode)
sys.dont_write_bytecode = True

import functools  # noqa: E402
import gzip  # noqa: E402

gzip.compress = functools.partial(gzip.compress, mtime=0)  # KT data without the time of writing in it
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
REPO = HERE.parent.parent


def node_info(node):
    return {
        "properties": {k: [str(v) for v in vs] for k, vs in node.properties.items()},
        "depth": node.depth,
        "move": node.move.gtp() if node.move else None,
        "moves": [f"{m.player}{m.gtp()}" for m in node.moves],
        "placements": sorted(f"{m.player}{m.gtp()}" for m in node.placements),
        "clear_placements": sorted(m.gtp() for m in node.clear_placements),
        "player": node.player,
        "next_player": node.next_player,
        "is_pass": bool(node.is_pass),
        "children": len(node.children),
    }


def preorder(root):
    stack = [root]
    while stack:
        node = stack.pop()
        yield node
        stack.extend(reversed(node.children))


def board_string(game):
    return "\n".join(
        "".join(game.chains[c][0].player if c >= 0 else "-" for c in line) for line in reversed(game.board)
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--katrain", required=True, help="path to a KaTrain checkout")
    parser.add_argument("--out", default=str(REPO / "packages" / "katrain_core" / "test" / "fixtures"))
    args = parser.parse_args()
    sys.path.insert(0, str(Path(args.katrain).resolve()))

    import pysgf
    from pysgf import GoGame, Move

    from katrain.core.base_katrain import KaTrainBase
    from katrain.core.game import BaseGame, IllegalMoveException, KaTrainSGF
    from katrain.core.game_node import GameNode

    class MockKaTrain(KaTrainBase):
        pass

    katrain = MockKaTrain(force_package_config=True)

    out = Path(args.out)
    files = sorted((out / "inputs").iterdir())

    # -- SGF parsing, with plain pysgf nodes
    parse_results = {}
    for f in files:
        root = GoGame.parse_file(str(f))
        parse_results[f.name] = {
            "board_size": list(root.board_size),
            "komi": root.komi,
            "handicap": root.handicap,
            "ruleset": root.ruleset,
            "initial_player": root.initial_player,
            "nodes": [node_info(n) for n in preorder(root)],
            "nodes_in_tree": len(root.nodes_in_tree),
            "sgf": root.sgf(),
        }

    # -- rules along each record's main line, with KaTrain's BaseGame on KaTrain nodes
    mainline = {}
    for f in files:
        root = KaTrainSGF.parse_file(str(f))
        game = BaseGame(katrain, move_tree=root)
        steps = []
        node = game.root
        while True:
            game.set_current_node(node)
            steps.append({"board": board_string(game), "prisoners": game.prisoner_count, "stones": len(game.stones)})
            if not node.children:
                break
            node = node.children[0]
        mainline[f.name] = {"root_ab": sorted(game.root.get_list_property("AB", [])), "steps": steps}

    # -- random move attempts
    rulesets = ["japanese", "tromp-taylor", "new zealand", '{"suicide": true, "ko": "SIMPLE"}']
    scenarios = []
    rng = random.Random(20261019)
    for size in [5, 7, 9, 13]:
        for rules in rulesets:
            for _ in range(3):
                root = GameNode(properties={"SZ": size, "RU": rules, "KM": 6.5})
                game = BaseGame(katrain, move_tree=root)
                attempts = []
                for _ in range(260 if size <= 9 else 400):
                    player = game.current_node.next_player
                    empty = [(x, y) for y in range(size) for x in range(size) if game.board[y][x] == -1]
                    r = rng.random()
                    if len(game.last_capture) == 1 and r < 0.5:
                        # try to take back at once: ko, or a snapback
                        move = Move(game.last_capture[0].coords, player=player)
                    elif r < 0.03 or not empty:
                        move = Move(None, player=player)
                    elif r < 0.07:
                        move = Move((rng.randrange(size), rng.randrange(size)), player=player)
                    else:
                        move = Move(rng.choice(empty), player=player)
                    try:
                        game.play(move)
                        result = "ok"
                    except IllegalMoveException as e:
                        result = str(e)
                    attempts.append(
                        {
                            "move": f"{player}{move.gtp()}",
                            "result": result,
                            "board": board_string(game),
                            "prisoners": game.prisoner_count,
                        }
                    )
                scenarios.append({"size": size, "rules": rules, "attempts": attempts})

    # -- utils: number formatting, half floats, random numbers, translations
    import struct

    from katrain.core.lang import i18n, rank_label
    from katrain.core.utils import (
        evaluation_class,
        format_visits,
        pack_floats,
        unpack_floats,
        var_to_grid,
        weighted_selection_without_replacement,
    )

    value_rng = random.Random(7)
    specials = [0.0, -0.0, 0.5, 1.5, 2.5, -0.5, -1.5, 0.125, 0.375, 2.675, -0.04, 0.05, 0.15, 0.25, 1e-5, 1.23e-7,
                1e16, 1.5e16, 123456789.125, 99.95, -99.95, 0.995, -0.995, 0.005, 1 / 3, 2 / 3, 1e300, 5e-324,
                9.9995, 9.9996, 9.9995e-5, 1.0625, 1e-310, 1e100, 1e-100]
    values = specials + [value_rng.uniform(-100, 100) for _ in range(300)] + [value_rng.uniform(-1, 1) * 10 ** value_rng.randint(-8, 6) for _ in range(300)]
    formats = []
    for x in values:
        formats.append({
            "x": struct.pack("<d", x).hex(),
            "repr": repr(x),
            "f0": f"{x:.0f}", "f1": f"{x:.1f}", "f2": f"{x:.2f}", "f6": f"{x:.6f}", "p1f": f"{x:+.1f}",
            "e0": f"{x:.0e}", "e3": f"{x:.3e}",
            "pc1": f"{x:.1%}", "pc2": f"{x:.2%}", "ppc1": f"{x:+.1%}",
            "round": round(x) if abs(x) < 1e15 else None,
            "round1": repr(round(x, 1)), "round2": repr(round(x, 2)),
        })
    half_lists = [[v for v in specials if abs(v) < 65504], [value_rng.uniform(-1, 1) for _ in range(200)], [value_rng.uniform(0, 1e-3) for _ in range(100)],
                  [1 + 2 ** -11, 1 + 3 * 2 ** -11, 2 ** -24, 2 ** -25, 3 * 2 ** -26, 2 ** -15, 65504.0, 65519.0]]
    halves = [{"values": [struct.pack("<d", v).hex() for v in vs], "packed": pack_floats(vs).hex(),
               "unpacked": [repr(v) for v in unpack_floats(pack_floats(vs), len(vs))]} for vs in half_lists]
    randoms = {}
    for seed in [0, 1, 42, 2 ** 40 + 5, 20261019, 2 ** 70 + 3]:
        r = random.Random(seed)
        randoms[str(seed)] = [repr(r.random()) for _ in range(30)]
    selections = []
    for seed in [3, 11, 2026]:
        items = [(f"m{i}", value_rng.uniform(0, 1) ** 3) for i in range(40)]
        for n in [1, 5, 40, 50]:
            random.seed(seed)
            picked = weighted_selection_without_replacement(items, n)
            selections.append({"seed": seed, "n": n, "items": [[k, struct.pack("<d", w).hex()] for k, w in items],
                               "picked": [k for k, _ in picked]})
    json_values = [
        {"moves": {"D4": {"visits": 12, "winrate": 0.5, "pv": ["D4", "Q16"], "prior": 1e-05}}, "root": None, "ok": True},
        ["caf\u00e9 \u56f4\u68cb \U0001f600", "quote \" backslash \\ tab \t nl \n cr \r bell \x07 del \x7f", [], {}],
        [1.0, -0.0, 123456789012345678, 1e16, 2.5e-07, 0.1 + 0.2],
    ]
    misc = {
        "json_dumps": [[v, json.dumps(v)] for v in json_values],
        "var_to_grid": var_to_grid(list(range(12)), (4, 3)),
        "evaluation_class": [[pl, evaluation_class(pl, [12, 6, 3, 1.5, 0.5, 0])] for pl in [-1, 0, 0.3, 0.5, 1, 1.5, 2.9, 3, 5, 6, 11.9, 12, 40]],
        "format_visits": [[n, format_visits(n)] for n in [0, 5, 999, 1000, 1049, 1050, 1250, 99949, 99950, 100000, 125500, 999999, 1000000, 1500000, 2500000]],
    }
    ranks = [None, -20, -10.4, -0.6, -0.5, 0, 0.4, 0.5, 0.6, 1.5, 2.5, 3.49, 9]
    translations = {}
    sample_keys = ["menu:newgame", "strength:kyu", "strength:dan", "board-pass", "Info:point loss", "no such key"]
    for lang in ["en", "cn", "tw", "jp", "ko", "de", "fr", "ru", "tr", "ua", "es"]:
        i18n.switch_lang(lang)
        translations[lang] = {"keys": {k: i18n._(k) for k in sample_keys}, "rank_labels": [rank_label(r) for r in ranks]}
    i18n.switch_lang("en")
    utils_data = {"formats": formats, "halves": halves, "randoms": randoms, "selections": selections, "misc": misc,
                  "ranks": ranks, "translations": translations}

    import game_node_fixtures

    game_node_data = game_node_fixtures.build(katrain)

    import engine_fixtures

    engine_data = engine_fixtures.build()

    import game_fixtures

    game_data = game_fixtures.build(katrain)

    import subprocess
    from importlib.metadata import version

    from katrain.core.constants import VERSION

    commit = subprocess.run(
        ["git", "-C", args.katrain, "rev-parse", "HEAD"], capture_output=True, text=True, check=False
    ).stdout.strip()
    # versions only, no local paths: the fixtures are committed
    meta = {"pysgf": version("pysgf"), "katrain": VERSION, "katrain_commit": commit or "unknown"}
    for name, data in [
        ("sgf_parse.json", parse_results),
        ("rules_mainline.json", mainline),
        ("rules_random.json", {"scenarios": scenarios}),
        ("utils.json", utils_data),
        ("game_node.json", game_node_data),
        ("engine.json", engine_data),
        ("game.json", game_data),
    ]:
        with open(out / name, "w", encoding="utf-8", newline="\n") as fh:
            json.dump({"generated_by": meta, "data": data}, fh, ensure_ascii=False, indent=None, separators=(",", ":"))
        print(f"wrote {out / name}")


if __name__ == "__main__":
    main()
