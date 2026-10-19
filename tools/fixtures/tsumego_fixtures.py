"""Tsumego frame fixtures: KaTrain's tsumego_frame on problems in corners, on edges and in the centre, on square and
non-square boards, for both colours to play, with and without ko threats and with several margins."""

import random


def build(katrain):
    from pysgf import Move

    from katrain.core.game import BaseGame, KaTrainSGF
    from katrain.core.tsumego_frame import tsumego_frame, tsumego_frame_from_katrain_game

    rng = random.Random(1234)
    cases = []

    def problem(sx, sy, corner):
        """Random stones in a box near a corner, an edge or the centre."""
        w, h = rng.randint(3, 6), rng.randint(3, 6)
        x0 = {"left": 0, "right": sx - w, "centre": (sx - w) // 2}[corner[0]]
        y0 = {"bottom": 0, "top": sy - h, "centre": (sy - h) // 2}[corner[1]]
        x0 = max(0, min(sx - w, x0 + rng.randint(-1, 2)))
        y0 = max(0, min(sy - h, y0 + rng.randint(-1, 2)))
        points = [(x, y) for x in range(x0, x0 + w) for y in range(y0, y0 + h)]
        chosen = rng.sample(points, rng.randint(1, min(10, len(points))))
        blacks = [p for i, p in enumerate(chosen) if i % 2 == 0 or rng.random() < 0.2]
        whites = [p for p in chosen if p not in blacks]
        return blacks, whites

    sizes = [(19, 19), (13, 13), (9, 9), (19, 13), (11, 17)]
    corners = [(a, b) for a in ["left", "right", "centre"] for b in ["bottom", "top", "centre"]]
    for sx, sy in sizes:
        for corner in corners:
            while True:  # placements without liberties would make an invalid position
                blacks, whites = problem(sx, sy, corner)
                sz = f"{sx}" if sx == sy else f"{sx}:{sy}"
                ab = "".join(f"[{Move(p).sgf((sx, sy))}]" for p in blacks)
                aw = "".join(f"[{Move(p).sgf((sx, sy))}]" for p in whites)
                sgf = f"(;GM[1]FF[4]SZ[{sz}]" + (f"AB{ab}" if ab else "") + (f"AW{aw}" if aw else "") + ")"
                try:
                    BaseGame(katrain, move_tree=KaTrainSGF.parse_sgf(sgf))
                    break
                except Exception:
                    continue
            for komi, black_to_play, ko, margin in [(6.5, True, False, 4), (0.5, False, True, 2), (-7.5, True, True, 1)]:
                root = KaTrainSGF.parse_sgf(sgf)
                game = BaseGame(katrain, move_tree=root)
                bw_board = [[game.chains[c][0].player if c >= 0 else "-" for c in line] for line in game.board]
                blacks_ij, whites_ij, region = tsumego_frame(bw_board, komi, black_to_play, ko, margin)
                node, katrain_region = tsumego_frame_from_katrain_game(game, komi, black_to_play, ko, margin)
                cases.append(
                    {
                        "sgf": sgf,
                        "komi": komi,
                        "black_to_play": black_to_play,
                        "ko": ko,
                        "margin": margin,
                        "blacks": blacks_ij,
                        "whites": whites_ij,
                        "region": region or None,
                        "AB": node.get_list_property("AB"),
                        "AW": node.get_list_property("AW"),
                        "katrain_region": katrain_region or None,
                    }
                )
    # an empty board: no frame
    empty = [["-"] * 9 for _ in range(9)]
    cases.append({"bw_board": empty, "frame": [list(x) if isinstance(x, list) else x for x in tsumego_frame(empty, 6.5, True, False, 4)]})
    return {"cases": cases}
