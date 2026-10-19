"""AI fixtures: every strategy of katrain/core/ai.py, ai_rank_estimation and game_report.

Uses the operation script of game_fixtures.py. Positions are played with synthetic analyses; then each AI operation
seeds Python's random, runs generate_ai_move, and answers the extra queries some strategies send (handicap,
antimirror, human style) from a list in the operation: a result, a partial result first, an error, a discarded
query (as after a new game), or a result that arrives after the user navigated away.
"""

import copy

from game_fixtures import RecordingEngine, Script, node_path


class AnsweringEngine(RecordingEngine):
    """Records requests, and answers the AI's extra queries right away from the current operation's answers."""

    def __init__(self, host, config):
        super().__init__(host, config)
        self.query_generation = 0
        self.answers = []

    def request_analysis(self, analysis_node, callback, error_callback=None, **kwargs):
        from katrain.core.constants import PRIORITY_EXTRA_AI_QUERY

        super().request_analysis(analysis_node, callback, error_callback, **kwargs)
        if kwargs.get("priority") != PRIORITY_EXTRA_AI_QUERY or not self.answers:
            return
        answer = self.answers.pop(0)
        kind = answer["type"]
        if kind == "result":
            callback(copy.deepcopy(answer["result"]), False)
        elif kind == "partial_then_result":
            callback(copy.deepcopy(answer["result"]), True)
            callback(copy.deepcopy(answer["result"]), False)
        elif kind == "error":
            error_callback(copy.deepcopy(answer["error"]))
        elif kind == "discard":
            self.query_generation += 1
        elif kind == "navigate":
            self.host.game.set_current_node(analysis_node.parent)
            callback(copy.deepcopy(answer["result"]), False)
        else:
            raise ValueError(kind)

    def check_alive(self, os_error="", exception_if_dead=False, maybe_open_recovery=False):
        return True


def build(katrain_base):
    import random

    from katrain.core.ai import ai_rank_estimation, game_report, generate_ai_move

    s = Script(katrain_base, engine_class=AnsweringEngine, seed=77, normalize_policy=True)
    engine = s.engine

    def run_ai(op):
        engine.answers = copy.deepcopy(op["answers"])
        random.seed(op["seed"])
        try:
            move, node = generate_ai_move(s.game, op["mode"], copy.deepcopy(op["settings"]))
        finally:
            engine.answers = []
        s.host.events.append(["ai_result", f"{move.player}{move.gtp()}" if move else None, node_path(node)])

    def run_rank(op):
        s.host.events.append(["rank", ai_rank_estimation(op["strategy"], op["settings"])])

    def run_report(op):
        sum_stats, histogram, player_ptloss = game_report(s.game, op["thresholds"], depth_filter=op["depth_filter"])
        s.host.events.append(["report", sum_stats, histogram, player_ptloss])

    s.handlers.update({"ai": run_ai, "rank": run_rank, "report": run_report})
    ai_config = s.config["ai"]

    def settings(mode, **changes):
        return {**ai_config.get(mode, {}), **changes}

    def ai(mode, seed, answers=(), **changes):
        path = node_path(s.game.current_node)
        s.do("ai", mode=mode, settings=settings(mode, **changes), seed=seed, answers=list(answers))
        s.do("goto", path=path)  # back to the same position for the next strategy

    def result_for(node, **kwargs):
        return {"type": "result", "result": s.fake_result(node, **kwargs)}

    def human_policy(node, pass_weight=0.01):
        sx, sy = node.board_size
        hp = [0.0] * (sx * sy + 1)
        for x, y in s.legal_points(node):
            hp[(sy - 1 - y) * sx + x] = round(s.rng.random() ** 2, 6)
        hp[-1] = pass_weight
        result = s.fake_result(node)
        result["humanPolicy"] = hp
        return result

    # -- a 9x9 game with analyses that have per-move ownership --
    s.do("seed", seed=3)
    s.do("new_game", sgf=None, props={"SZ": 9}, analyze_fast=False)
    root = s.game.root
    s.feed(0, root, root_score=0.3, move_ownership=True, n_moves=8)
    # the first move: no previous move for local and tenuki
    for mode in ["ai:p:local", "ai:p:tenuki"]:
        ai(mode, seed=11)
    for i in range(12):
        s.play(move_ownership=True, n_moves=8, spread=1.0 if i % 2 else 3.0)

    # -- every strategy on the same position, with a few seeds --
    for seed in [1, 2]:
        for mode in ["ai:default", "ai:jigo", "ai:scoreloss", "ai:policy", "ai:p:weighted", "ai:p:pick", "ai:p:local",
                     "ai:p:tenuki", "ai:p:influence", "ai:p:territory", "ai:p:rank"]:
            ai(mode, seed=seed)
    ai("ai:simple", seed=1)
    ai("ai:settle", seed=1, **ai_config["ai:simple"])
    ai("ai:simple", seed=1, max_points_lost=0.0)  # nothing qualifies: KaTrain raises
    cn = s.game.current_node
    ai("ai:handicap", seed=1, answers=[result_for(cn)])
    ai("ai:handicap", seed=1, answers=[result_for(cn)], automatic=False, pda=0.5)
    ai("ai:handicap", seed=1, answers=[{"type": "error", "error": {"error": "boom", "id": "QUERY:9"}}])
    ai("ai:antimirror", seed=1, answers=[result_for(cn)])
    ai("ai:antimirror", seed=1, answers=[{"type": "partial_then_result", "result": s.fake_result(cn)}])
    ai("ai:human", seed=4, answers=[{"type": "result", "result": human_policy(cn)}])
    ai("ai:human", seed=5, answers=[{"type": "partial_then_result", "result": human_policy(cn)}], modern_style=True,
       human_kyu_rank=-2)
    ai("ai:pro", seed=6, answers=[{"type": "result", "result": human_policy(cn, pass_weight=0.0)}])
    ai("ai:human", seed=4, answers=[{"type": "error", "error": {"error": "no human model"}}])
    no_human = s.fake_result(cn)
    ai("ai:human", seed=4, answers=[{"type": "result", "result": no_human}])  # KaTrain raises
    ai("ai:handicap", seed=1, answers=[{"type": "discard"}])
    ai("ai:human", seed=1, answers=[{"type": "discard"}])
    ai("ai:antimirror", seed=1, answers=[{"type": "navigate", "result": s.fake_result(cn)}])
    ai("ai:no-such-strategy", seed=1)
    # settings that take the other paths
    ai("ai:policy", seed=1, opening_moves=30)
    ai("ai:p:weighted", seed=1, pick_override=0.0)
    ai("ai:p:weighted", seed=1, lower_bound=0.99)
    ai("ai:p:pick", seed=3, pick_override=0.0)
    ai("ai:p:pick", seed=3, pick_override=1.0, pick_override_two=0.01)
    ai("ai:p:pick", seed=3, pick_frac=None)
    for mode in ["ai:p:local", "ai:p:tenuki", "ai:p:influence", "ai:p:territory"]:
        ai(mode, seed=9, endgame=0.05)  # endgame by move number
    ai("ai:p:influence", seed=2, threshold=3, line_weight=1.5)
    ai("ai:p:territory", seed=2, threshold=2, line_weight=3)
    ai("ai:p:local", seed=2, stddev=2)
    for rank in [0.0, 4.0, 12.0, 18.0]:
        ai("ai:p:rank", seed=5, kyu_rank=rank)
    ai("ai:scoreloss", seed=2, strength=2.0)
    ai("ai:jigo", seed=1, target_score=-3.5)

    # -- a position where pass is popular --
    passing = s.fake_result(cn, move_ownership=True, n_moves=6)
    passing["policy"][-1] = 0.9
    passing["moveInfos"][0]["move"] = "pass"
    s.do("reset_analysis")  # a new query for this node
    s.do("feed", query=s.last_query(), result=passing, partial=False)
    for mode in ["ai:scoreloss", "ai:simple", "ai:policy", "ai:p:weighted", "ai:p:pick", "ai:p:rank"]:
        ai(mode, seed=1)
    # the picked moves are rated below pass
    low = s.fake_result(cn, move_ownership=True)
    low["policy"] = [p * 0.01 if p > 0 else p for p in low["policy"][:-1]] + [0.5]
    s.do("reset_analysis")  # a new query for this node
    s.do("feed", query=s.last_query(), result=low, partial=False)
    ai("ai:p:pick", seed=1, pick_override=1.0)
    # one visit: no candidate moves, only policy
    single = s.fake_result(cn)
    single["moveInfos"] = []
    s.do("reset_analysis")  # a new query for this node
    s.do("feed", query=s.last_query(), result=single, partial=False)
    for mode in ["ai:default", "ai:jigo", "ai:scoreloss"]:
        ai(mode, seed=1)

    # -- AI moves played in a row, as in a game --
    for i, mode in enumerate(["ai:p:rank", "ai:default", "ai:p:weighted", "ai:simple"] * 2):
        s.do("ai", mode=mode, settings=settings(mode), seed=100 + i, answers=[])
        s.feed(s.last_query(), s.game.current_node, move_ownership=True, n_moves=6)

    # -- handicap stones for the automatic PDA --
    s.do("new_game", sgf="(;GM[1]FF[4]SZ[9]HA[3]KM[0.5]AB[cc][gg][cg])", props=None, analyze_fast=False)
    s.feed(0, s.game.root, move_ownership=True)
    cn = s.game.current_node
    ai("ai:handicap", seed=1, answers=[result_for(cn)])
    s.do("new_game", sgf="(;GM[1]FF[4]SZ[9]HA[9]KM[-40]AB[cc][gg][cg][gc][ee][ce][ge][ec][eg])", props=None,
         analyze_fast=False)
    s.feed(0, s.game.root, move_ownership=True)
    ai("ai:handicap", seed=1, answers=[result_for(s.game.current_node)])

    # -- rank estimation --
    for strategy in ai_config:
        s.do("rank", strategy=strategy, settings=ai_config[strategy])
    for strategy, changes in [("ai:p:weighted", {"weaken_fac": 0.1}), ("ai:p:weighted", {"weaken_fac": 9}),
                              ("ai:scoreloss", {"strength": 0.0}), ("ai:scoreloss", {"strength": 5}),
                              ("ai:p:pick", {"pick_frac": 0.6, "pick_n": 30}), ("ai:p:local", {"pick_frac": 1.0, "pick_n": 0}),
                              ("ai:p:rank", {"kyu_rank": -3}), ("ai:human", {"human_kyu_rank": 20}),
                              ("ai:simple", {}), ("ai:settle", {})]:
        s.do("rank", strategy=strategy, settings=settings(strategy, **changes))

    # -- game report on a longer game --
    s.do("seed", seed=8)
    s.do("new_game", sgf=None, props={"SZ": 9}, analyze_fast=False)
    s.feed(0, s.game.root, root_score=0.5)
    for i in range(30):
        s.play(spread=6.0 if i % 5 == 0 else 1.5, partial_first=i % 7 == 0)
    s.do("undo", n=10, stop=None)
    s.play()  # a branch: the report follows the first children
    thresholds = s.config["trainer"]["eval_thresholds"]
    for depth_filter in [None, [0, 0.1], [0.1, 0.3], [0.3, 1e9], [0.5, 0.6]]:
        s.do("report", thresholds=thresholds, depth_filter=depth_filter)
    s.do("report", thresholds=[10, 5, 2, 0], depth_filter=None)
    s.do("goto", path="")
    s.do("report", thresholds=thresholds, depth_filter=None)

    return s.result()
