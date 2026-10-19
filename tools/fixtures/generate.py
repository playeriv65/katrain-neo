"""Generate differential test fixtures from Python KaTrain and pysgf.

The Dart port must reproduce these outputs exactly. Run with a Python environment that has KaTrain's dependencies
(e.g. a KaTrain checkout after `uv sync`):

    python tools/fixtures/generate.py --katrain <path to a KaTrain checkout> [--out <dir>]

Reads the records in packages/katrain_core/test/fixtures/inputs/ and writes next to them:
- sgf_parse.json   every node of every record as pysgf sees it, and the SGF it writes back
- rules_mainline.json  board and captures after every move of each record's main line (KaTrain BaseGame)
- rules_random.json    random move attempts on small boards under several rulesets, with legality and positions
"""

import argparse
import json
import os
import random
import sys
from pathlib import Path

os.environ["KIVY_NO_ARGS"] = "1"  # KaTrain imports Kivy, which otherwise parses our command line
HERE = Path(__file__).resolve().parent
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
    ]:
        with open(out / name, "w", encoding="utf-8", newline="\n") as fh:
            json.dump({"generated_by": meta, "data": data}, fh, ensure_ascii=False, indent=None, separators=(",", ":"))
        print(f"wrote {out / name}")


if __name__ == "__main__":
    main()
