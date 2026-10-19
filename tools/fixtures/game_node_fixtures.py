"""GameNode fixtures: analysis merging, candidate moves, comments, SGF writing and KT data.

A 9x9 tree is played at random, then every node gets synthetic KataGo results through KaTrain's set_analysis, in
sequences like the GUI produces (partial and final results, refined moves, extra candidates, region analyses). The
calls are recorded so the Dart test can replay exactly the same ones.
"""

import copy
import json
import random


def build(katrain):
    import katrain.core.game_node as game_node_module
    from pysgf import Move

    from katrain.core.game import BaseGame, IllegalMoveException
    from katrain.core.game_node import GameNode, analysis_dumps
    from katrain.core.lang import i18n

    # the port writes its own name; KaTrain only checks that AP contains "KaTrain"
    game_node_module.PROGRAM_NAME = "KaTrain Neo"
    game_node_module.VERSION = "0.1.0"
    i18n.switch_lang("en")

    rng = random.Random(99)
    size = 9
    squares = size * size
    root = GameNode(properties={"SZ": size, "KM": 6.5, "RU": "japanese"})
    game = BaseGame(katrain, move_tree=root)

    def random_line(start, n):
        game.set_current_node(start)
        played = []
        for _ in range(n):
            for _ in range(200):
                player = game.current_node.next_player
                empty = [(x, y) for y in range(size) for x in range(size) if game.board[y][x] == -1]
                move = Move(rng.choice(empty), player=player) if rng.random() > 0.02 else Move(None, player=player)
                try:
                    played.append(game.play(move))
                    break
                except IllegalMoveException:
                    pass
        return played

    main_line = random_line(root, 40)
    random_line(main_line[9], 5)
    random_line(main_line[19], 6)
    tree_sgf = root.sgf()

    def preorder(node):
        stack = [node]
        while stack:
            n = stack.pop()
            yield n
            stack.extend(reversed(n.children))

    nodes = list(preorder(root))
    points = [(x, y) for y in range(size) for x in range(size)]

    def fake_result(node, n_moves, base_visits, partial):
        chosen = rng.sample(points, n_moves)
        gtps = [Move(p).gtp() for p in chosen] + (["pass"] if rng.random() < 0.3 else [])
        moves = []
        for i, gtp in enumerate(gtps):
            pv = [gtp] + [Move(rng.choice(points)).gtp() for _ in range(rng.randint(0, 6))]
            moves.append(
                {
                    "move": gtp,
                    "order": i,
                    "visits": max(1, base_visits // (i + 1) + rng.randint(0, 9)),
                    "winrate": rng.random(),
                    "scoreLead": round(rng.uniform(-30, 30), 6),
                    "prior": rng.random() / (i + 1),
                    "lcb": rng.random(),
                    "pv": pv,
                    "ownership": [round(rng.uniform(-1, 1), 6) for _ in range(squares)],
                }
            )
        return {
            "id": "QUERY:1",
            "isDuringSearch": partial,
            "turnNumber": node.depth,
            "rootInfo": {
                "visits": base_visits,
                "winrate": rng.random(),
                "scoreLead": round(rng.uniform(-20, 20), 6),
                "scoreStdev": rng.uniform(5, 15),
                "utility": rng.uniform(-1, 1),
            },
            "moveInfos": moves,
            "ownership": [round(rng.uniform(-1, 1), 6) for _ in range(squares)],
            "policy": [round(rng.random() ** 3, 6) if rng.random() > 0.2 else -1.0 for _ in range(squares + 1)],
        }

    calls = []
    for ix, node in enumerate(nodes):
        if rng.random() < 0.12:
            continue  # some nodes stay unanalysed
        sequence = [
            (fake_result(node, 4, 20, True), None, False, None, True),
            (fake_result(node, 6, 400, False), None, False, None, False),
        ]
        if rng.random() < 0.3:
            target = Move(rng.choice(points), player=node.next_player)
            sequence.append((fake_result(node, 3, 300, False), target, False, None, False))
        if rng.random() < 0.3:
            sequence.append((fake_result(node, 3, 200, False), None, True, None, False))
        if rng.random() < 0.2:
            sequence.append((fake_result(node, 3, 250, False), None, False, [1, 5, 2, 6], False))
        for result, refine, additional, region, partial in sequence:
            calls.append(
                {
                    "node": ix,
                    "json": copy.deepcopy(result),
                    "refine_move": refine.gtp() if refine else None,
                    "refine_player": refine.player if refine else None,
                    "additional": additional,
                    "region": region,
                    "partial": partial,
                }
            )
            node.set_analysis(result, refine, additional, region, partial)
        if rng.random() < 0.3:
            node.auto_undo = rng.random() < 0.5
        if rng.random() < 0.2:
            node.ai_thoughts = f"thinking about node {ix}"
        if rng.random() < 0.15:
            node.note = f"note {ix}\nsecond line"
    extras = [{"node": ix, "auto_undo": n.auto_undo, "ai_thoughts": n.ai_thoughts, "note": n.note} for ix, n in enumerate(nodes)]

    def dumpable(v):
        return json.loads(json.dumps(v, default=list))

    outputs = []
    for node in nodes:
        out = {
            "analysis": dumpable(node.analysis),
            "candidate_moves": dumpable(node.candidate_moves),
            "points_lost": node.points_lost,
            "parent_realized_points_lost": node.parent_realized_points_lost,
            "policy_ranking": [[p, m.gtp()] for p, m in (node.policy_ranking or [])[:15]],
            "move_policy_stats": list(node.move_policy_stats()[:2]),
            "format_score": node.format_score(),
            "format_winrate": node.format_winrate(),
            "ordered_children": [nodes.index(c) for c in node.ordered_children],
            "comments": {},
        }
        for lang in ["en", "cn"]:
            i18n.switch_lang(lang)
            out["comments"][lang] = {
                "default": node.comment(),
                "sgf": node.comment(sgf=True, interactive=False),
                "details": node.comment(details=True),
                "teach": node.comment(teach=True),
            }
        i18n.switch_lang("en")
        outputs.append(out)

    thresholds = [12, 6, 3, 1.5, 0.5, 0]
    options = {
        "default": {},
        "comments": {"save_comments_player": {"B": True, "W": True}, "save_comments_class": [True] * 6, "eval_thresholds": thresholds},
        "comments_some": {
            "save_comments_player": {"B": True, "W": False},
            "save_comments_class": [True, True, False, False, False, False],
            "eval_thresholds": thresholds,
        },
        "marks": {
            "save_comments_player": {"B": True, "W": True},
            "save_comments_class": [True] * 6,
            "eval_thresholds": thresholds,
            "save_marks": True,
        },
    }
    sgf_variants = {name: root.sgf(**kw) for name, kw in options.items()}

    # KT data written by Python, and the analysis Python reads back from it
    kt = []
    for ix, node in enumerate(nodes):
        if node.analysis_complete and ix % 4 == 0:
            values = analysis_dumps(node.analysis)
            probe = GameNode(properties={"SZ": size})
            probe.analysis_from_sgf = values
            assert probe.load_analysis()
            kt.append({"node": ix, "values": values, "loaded": dumpable(probe.analysis)})

    return {"tree_sgf": tree_sgf, "calls": calls, "extras": extras, "nodes": outputs, "sgf": sgf_variants, "kt": kt}
