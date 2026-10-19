"""Game fixtures: navigation, insert mode, analysis requests, extra analysis modes, self-play, teaching undo, scoring
and saving.

KaTrain's Game is driven by a script of operations, with a stand-in for KaTrain itself (settings, players, status
line, move tree) and an engine that records requests instead of running KataGo. Synthetic results are fed to the
recorded requests. For every operation the events (requests, status messages, log lines, ...) and the state after it
are recorded, so the Dart test can run the same script on the port and compare.
"""

import copy
import datetime as datetime_module
import os
import random
import re
import tempfile
import threading
import types

SIZE = 9
NOW = (2026, 10, 19, 12, 34, 56)


def node_path(node):
    """Child indices from the root, e.g. "0.0.1"; "" for the root."""
    if node is None:
        return None
    parts = []
    while node.parent is not None:
        parts.append(node.parent.children.index(node))
        node = node.parent
    return ".".join(str(p) for p in reversed(parts))


def node_at(root, path):
    node = root
    for part in path.split(".") if path else []:
        node = node.children[int(part)]
    return node


def normalize_shortcut_ids(sgf):
    """KaTrain writes id(node) as shortcut ids, the port a serial number: number them by first appearance."""
    ids = {}
    return re.sub(r"(KTSID|KTSF)\[(\d+)\]", lambda m: f"{m[1]}[{ids.setdefault(m[2], len(ids) + 1)}]", sgf)


def preorder(root):
    stack = [root]
    while stack:
        node = stack.pop()
        yield node
        stack.extend(reversed(node.children))


class _MoveTree:
    def __init__(self, host):
        self.host = host
        self._insert_node = None

    @property
    def insert_node(self):
        return self._insert_node

    @insert_node.setter
    def insert_node(self, node):
        self.host.events.append(["insert_node", node_path(node)])
        self._insert_node = node

    def redraw(self):
        self.host.events.append(["redraw_tree"])

    def redraw_tree_trigger(self):
        self.host.events.append(["redraw_tree"])


class _Controls:
    def __init__(self, host):
        self.host = host
        self.move_tree = _MoveTree(host)

    def set_status(self, msg, status_type, at_node=None, check_level=True):
        self.host.events.append(["status", msg, status_type, node_path(at_node)])


class Host:
    """What Game uses of KaTrain."""

    def __init__(self, config, players_info):
        self.events = []
        self._config = config
        self.players_info = players_info
        self.game = None
        self._pondering = True
        self.controls = _Controls(self)

    @property
    def pondering(self):
        return self._pondering

    @pondering.setter
    def pondering(self, value):
        self.events.append(["pondering", value])
        self._pondering = value

    def config(self, setting, default=None):
        if "/" in setting:
            cat, key = setting.split("/")
            return self._config.get(cat, {}).get(key, default)
        return self._config.get(setting, default)

    def log(self, message, level=0):
        self.events.append(["log", message, level])

    def update_state(self, redraw_board=False):
        self.events.append(["update_state", redraw_board])


class RecordingEngine:
    """Records analysis requests like KataGoEngine.request_analysis receives them, and keeps the callbacks."""

    DEFAULTS = {
        "visits": None,
        "analyze_fast": False,
        "time_limit": True,
        "find_alternatives": False,
        "region_of_interest": None,
        "priority": 0,
        "ponder": False,
        "ownership": None,
        "next_move": None,
        "extra_settings": None,
        "include_policy": True,
        "report_every": None,
    }

    def __init__(self, host, config):
        self.host = host
        self.config = config
        self.callbacks = []

    def request_analysis(self, analysis_node, callback, error_callback=None, **kwargs):
        if any(n.clear_placements for n in analysis_node.nodes_from_root):
            self.host.events.append(["query_skipped", node_path(analysis_node)])  # KataGoEngine does not analyse AE
            return
        args = {**self.DEFAULTS, **kwargs}
        next_move = args["next_move"]
        args["next_move"] = [next_move.player, next_move.gtp()] if next_move else None
        args["find_alternatives"] = bool(args["find_alternatives"])
        self.host.events.append(["query", len(self.callbacks), node_path(analysis_node), args])
        self.callbacks.append(callback)
        # the bookkeeping KataGoEngine.request_analysis does on the node
        visits = args["visits"]
        if visits is None:
            visits = self.config["max_visits"]
            if args["analyze_fast"] and self.config.get("fast_visits"):
                visits = self.config["fast_visits"]
        analysis_node.analysis_visits_requested = max(analysis_node.analysis_visits_requested, visits)

    def terminate_queries(self, only_for_node=None):
        self.host.events.append(["terminate", node_path(only_for_node)])

    def stop_pondering(self):
        self.host.events.append(["stop_pondering"])


def patch_katrain():
    """Makes KaTrain deterministic for the fixtures: a fixed clock, and the analysis thread run in place."""
    import katrain.core.game as game_module
    import katrain.core.game_node as game_node_module
    from katrain.core.lang import i18n

    # the port writes its own name into AP; KaTrain only checks that AP contains "KaTrain"
    game_node_module.PROGRAM_NAME = "KaTrain Neo"
    game_node_module.VERSION = "0.1.0"
    i18n.switch_lang("en")

    class FixedDatetime(datetime_module.datetime):
        @classmethod
        def now(cls, tz=None):
            return cls(*NOW)

    class SyncThread:
        """Runs the analysis KaTrain starts on a thread right away; the port runs it as the next event."""

        def __init__(self, target, daemon=None):
            self.target = target

        def start(self):
            self.target()

    game_module.datetime = FixedDatetime
    game_module.threading = types.SimpleNamespace(Thread=SyncThread, RLock=threading.RLock)


class Script:
    """Runs operations on KaTrain's Game and records them with their events and the state after each."""

    def __init__(self, katrain_base, engine_class=None, seed=2024, normalize_policy=False):
        from katrain.core.base_katrain import Player

        patch_katrain()
        self.config_at_start = copy.deepcopy(katrain_base._config)
        self.config = copy.deepcopy(katrain_base._config)
        self.players = {"B": Player("B"), "W": Player("W")}
        self.host = Host(self.config, self.players)
        self.engine = (engine_class or RecordingEngine)(self.host, self.config["engine"])
        self.rng = random.Random(seed)
        self.ops = []
        self.outputs = []
        self.game = None
        self.handlers = {}  # more kinds of operations: kind -> function(op)
        self.normalize_policy = normalize_policy  # policies that sum to 1, as KataGo's do

    def result(self):
        return {"config": self.config_at_start, "now": list(NOW), "ops": self.ops, "outputs": self.outputs}

    def legal_points(self, node):
        """Empty points next to another empty point (so never suicide or ko) in the position at node."""
        from katrain.core.game import BaseGame

        scratch = BaseGame.__new__(BaseGame)
        scratch._lock = threading.RLock()
        scratch.root = node.root
        scratch.current_node = node
        scratch._calculate_groups()
        sx, sy = scratch.board_size
        points = []
        for y in range(sy):
            for x in range(sx):
                if scratch.board[y][x] != -1:
                    continue
                if any(
                    0 <= x + dx < sx and 0 <= y + dy < sy and scratch.board[y + dy][x + dx] == -1
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
                ):
                    points.append((x, y))
        return points

    def fake_result(
        self, node, n_moves=5, visits=400, root_score=None, spread=4.0, ownership=None, first=None, move_ownership=False
    ):
        from pysgf import Move

        rng = self.rng
        sx, sy = node.board_size
        squares = sx * sy
        sign = 1 if node.next_player == "B" else -1
        points = self.legal_points(node)
        chosen = [Move(p).gtp() for p in rng.sample(points, min(n_moves, len(points)))]
        if first is not None:
            chosen = [first] + [c for c in chosen if c != first]
        if root_score is None:
            root_score = round(rng.uniform(-12, 12), 4)
        moves = []
        for i, gtp in enumerate(chosen):
            loss = 0.0 if i == 0 else round(rng.uniform(0, spread) * i, 4)
            move = {
                "move": gtp,
                "order": i,
                "visits": max(1, visits // (i + 2)),
                "winrate": round(rng.random(), 6),
                "scoreLead": round(root_score - sign * loss, 4),
                "prior": round(rng.random() / (i + 1), 6),
                "pv": [gtp] + [Move(rng.choice(points)).gtp() for _ in range(rng.randint(0, 4))],
            }
            if move_ownership:
                move["ownership"] = [round(rng.uniform(-1, 1), 4) for _ in range(squares)]
            moves.append(move)
        if ownership is None:
            ownership = [round(rng.uniform(-1, 1), 4) for _ in range(squares)]
        policy = [-1.0] * (squares + 1)
        for x, y in points:
            policy[(sy - 1 - y) * sx + x] = round(rng.random() ** 3, 6)
        policy[squares] = round(rng.random() / 10, 6)
        if self.normalize_policy:
            total = sum(p for p in policy if p > 0)
            policy = [round(p / total, 6) if p > 0 else p for p in policy]
        return {
            "id": "QUERY:0",
            "turnNumber": node.depth,
            "rootInfo": {"visits": visits, "winrate": round(rng.random(), 6), "scoreLead": root_score},
            "moveInfos": moves,
            "ownership": ownership,
            "policy": policy,
        }

    def snapshot(self):
        game = self.game
        if game is None:
            return None
        tree = []
        for node in preorder(game.root):
            tree.append(
                [
                    node_path(node),
                    f"{node.move.player}{node.move.gtp()}" if node.move else None,
                    len(node.placements),
                    None if node.auto_undo is None else bool(node.auto_undo),  # KaTrain may store 0 for False
                    node.ai_thoughts,
                    node.analysis_visits_requested,
                    node.analysis_complete,
                    node_path(node.shortcut_from),
                    [node_path(to) for to, _via in node.shortcuts_to],
                ]
            )
        board = "\n".join(
            "".join(game.chains[c][0].player if c >= 0 else "-" for c in line) for line in reversed(game.board)
        )
        return {
            "current": node_path(game.current_node),
            "board": board,
            "prisoners": game.prisoner_count,
            "insert_mode": game.insert_mode,
            "insert_after": node_path(getattr(game, "insert_after", None)),
            "region_of_interest": game.region_of_interest,
            "external": game.external_game,
            "tree": tree,
        }

    def run(self, op):
        import katrain.core.game as game_module
        from pysgf import Move

        from katrain.core.game import Game

        game, host, engine, config, players = self.game, self.host, self.engine, self.config, self.players
        kind = op["op"]
        if kind in self.handlers:
            self.handlers[kind](op)
        elif kind == "seed":
            random.seed(op["seed"])
        elif kind == "config":
            cat, key = op["key"].split("/")
            config[cat][key] = copy.deepcopy(op["value"])
        elif kind == "player":
            info = players[op["bw"]]
            info.update(op["type"], op["subtype"])
            info.calculated_rank = op["rank"]
            info.name = op["name"]
        elif kind == "new_game":
            move_tree = game_module.KaTrainSGF.parse_sgf(op["sgf"]) if op["sgf"] is not None else None
            engine.callbacks.clear()
            game = Game(host, engine, move_tree=move_tree, analyze_fast=op["analyze_fast"], game_properties=op["props"])
            host.game = self.game = game
        elif kind == "play":
            player = op["player"] or game.current_node.next_player
            game.play(Move.from_gtp(op["move"], player=player), ignore_ko=op["ignore_ko"], analyze=op["analyze"])
        elif kind == "sync":
            node = game.sync_branch([Move.from_gtp(m[1:], player=m[0]) for m in op["moves"]])
            host.events.append(["synced", node_path(node)])
        elif kind == "undo":
            game.undo(op["n"], stop_on_mistake=op["stop"])
        elif kind == "redo":
            game.redo(op["n"], stop_on_mistake=op["stop"])
        elif kind == "goto":
            game.set_current_node(node_at(game.root, op["path"]))
        elif kind == "insert":
            game.set_insert_mode(op["mode"])
        elif kind == "roi":
            game.set_region_of_interest(op["region"])
        elif kind == "extra":
            game.analyze_extra(op["mode"], **op["kwargs"])
        elif kind == "reset_analysis":
            game.reset_current_analysis()
        elif kind == "analyze_all":
            game.analyze_all_nodes(
                priority=op["priority"], analyze_fast=op["analyze_fast"], even_if_present=op["even_if_present"]
            )
        elif kind == "feed":
            engine.callbacks[op["query"]](copy.deepcopy(op["result"]), op["partial"])
        elif kind == "undo_threshold":
            node_at(game.root, op["path"]).undo_threshold = op["value"]
        elif kind == "analyze_undo":
            game.analyze_undo(node_at(game.root, op["path"]))
        elif kind == "selfplay":
            game.selfplay(op["until"], target_b_advantage=op["target"])
        elif kind == "manual_score":
            host.events.append(["result", game.manual_score, game.end_result])
        elif kind == "end_state":
            game.current_node.end_state = op["value"]
        elif kind == "save":
            with tempfile.TemporaryDirectory() as tmp:
                filename = os.path.join(tmp, "out", "game.sgf")
                message = game.write_sgf(filename, trainer_config=op["trainer"])
                with open(filename, encoding="utf-8") as fh:  # universal newlines undo Windows' CRLF
                    sgf = fh.read()
            host.events.append(["sgf", normalize_shortcut_ids(sgf), message.replace(filename, "<file>")])
            host.events.append(["filename", game.generate_filename()])
        else:
            raise ValueError(kind)

    def do(self, kind, **args):
        from katrain.core.game import IllegalMoveException

        op = {"op": kind, **copy.deepcopy(args)}
        self.ops.append(op)
        self.host.events = []
        error = None
        try:
            self.run(op)
        except IllegalMoveException as e:
            error = str(e)
        except Exception as e:  # noqa: BLE001 - KaTrain raises plain exceptions, e.g. from the AI strategies
            if kind not in self.handlers:
                raise
            error = str(e)
        self.outputs.append({"events": self.host.events, "error": error, "state": self.snapshot()})
        self.host.events = []
        return error

    def last_query(self):
        return len(self.engine.callbacks) - 1

    def feed(self, query, node, partial=False, **kwargs):
        self.do("feed", query=query, result=self.fake_result(node, **kwargs), partial=partial)

    def play(self, gtp=None, analyze=True, feed_it=True, partial_first=False, ignore_ko=False, player=None, **kwargs):
        from pysgf import Move

        g = self.game
        if gtp is None:
            gtp = Move(self.rng.choice(self.legal_points(g.current_node))).gtp()
        error = self.do("play", move=gtp, player=player, analyze=analyze, ignore_ko=ignore_ko)
        if error is None and analyze and feed_it:
            node = g.current_node
            if partial_first:
                self.feed(self.last_query(), node, partial=True, visits=40, **kwargs)
            self.feed(self.last_query(), node, **kwargs)
        return error

    def saved_sgf(self):
        return next(e[1] for e in self.outputs[-1]["events"] if e[0] == "sgf")

    def default_player(self, bw):
        self.do("player", bw=bw, type="player:human", subtype="game:normal", rank=None, name="")


def build(katrain_base):
    from pysgf import Move

    s = Script(katrain_base)
    do, feed, play, last_query = s.do, s.feed, s.play, s.last_query
    saved_sgf, default_player, fake_result, rng = s.saved_sgf, s.default_player, s.fake_result, s.rng
    legal_points, outputs, config = s.legal_points, s.outputs, s.config

    def game():
        return s.game


    # -- 1. a game played move by move, with analysis --
    do("seed", seed=1)
    do("new_game", sgf=None, props={"SZ": SIZE}, analyze_fast=False)
    feed(0, game().root, root_score=0.5)
    for i in range(14):
        # a few big mistakes for stop-on-mistake and the game analysis modes
        play(partial_first=i % 3 == 0, spread=8.0 if i % 4 == 1 else 3.0)
    do("manual_score")
    do("undo", n=1, stop=None)
    do("undo", n=3, stop=None)
    do("redo", n=2, stop=None)
    do("redo", n=20, stop=4.0)
    do("redo", n=20, stop=None)
    do("undo", n=20, stop=4.0)
    do("player", bw="B", type="player:ai", subtype="ai:default", rank=4.0, name="")
    do("undo", n=20, stop=4.0)
    do("undo", n=20, stop=0.5)
    default_player("B")
    do("goto", path=".".join(["0"] * 6))
    play()
    play()
    do("redo", n=1, stop=None)
    play()
    do("undo", n="branch", stop=None)
    do("goto", path=".".join(["0"] * 6 + ["1", "0", "0"]))
    do("undo", n="main-branch", stop=None)
    do("undo", n="main-branch", stop=None)
    do("undo", n=99, stop=None)
    do("redo", n=99, stop=None)
    do("play", move="A1", player=None, analyze=False, ignore_ko=False)
    occupied = game().stones[0]
    do("play", move=occupied.gtp(), player=None, analyze=False, ignore_ko=False)
    do("sync", moves=[])
    do("sync", moves=["BC3", "WD4", "BE5"])

    # -- 2. extra analysis modes --
    do("goto", path=".".join(["0"] * 8))
    do("extra", mode="extra", kwargs={})
    do("extra", mode="ponder", kwargs={})
    do("extra", mode="sweep", kwargs={})
    do("extra", mode="equalize", kwargs={})
    do("extra", mode="alternative", kwargs={})
    do("extra", mode="local", kwargs={})
    do("extra", mode="game", kwargs={})
    do("extra", mode="game", kwargs={"mistakes_only": True})
    do("extra", mode="game", kwargs={"move_range": [2, 5]})
    do("extra", mode="game", kwargs={"move_range": [3, 3], "visits": 1234})
    do("extra", mode="game", kwargs={"visits": 77, "mistakes_only": True})
    do("goto", path=".".join(["0"] * 6 + ["1"]))
    do("reset_analysis")
    do("extra", mode="equalize", kwargs={})
    do("extra", mode="alternative", kwargs={})
    do("extra", mode="sweep", kwargs={})
    do("extra", mode="stop", kwargs={})
    do("analyze_all", priority=-50, analyze_fast=True, even_if_present=True)

    # -- 3. region of interest --
    do("goto", path=".".join(["0"] * 10))
    do("roi", region=[5, 2, 7, 3])
    do("extra", mode="ponder", kwargs={})
    do("extra", mode="extra", kwargs={})
    play()
    do("roi", region=[4, 4, 6, 6])
    do("roi", region=[0, 8, 8, 0])
    do("roi", region=[1, 3, 1, 3])
    play()
    do("roi", region=[3, 3, 3, 3])

    # -- 4. insert mode --
    do("goto", path=".".join(["0"] * 4))
    do("insert", mode=True)
    do("insert", mode=True)
    play(analyze=False)
    play(feed_it=False)
    do("goto", path="")
    do("redo", n=1, stop=None)
    do("undo", n=1, stop=None)
    do("undo", n=1, stop=None)
    do("undo", n=1, stop=None)
    play(feed_it=False)
    play(feed_it=False)
    do("insert", mode="toggle")
    do("insert", mode=False)
    # inserting nothing
    do("goto", path=".".join(["0"] * 3))
    do("insert", mode="toggle")
    do("insert", mode="toggle")
    # at a leaf there is nothing to insert before
    do("redo", n=99, stop=None)
    do("insert", mode=True)
    # an inserted move that makes the rest of the line illegal
    do("goto", path=".".join(["0"] * 2))
    do("insert", mode=True)
    next_line = game().current_node.ordered_children[0].ordered_children[0]
    do("play", move=next_line.move.gtp(), player=next_line.move.player, analyze=False, ignore_ko=False)
    do("play", move="pass", player=None, analyze=False, ignore_ko=False)
    do("insert", mode=False)

    # -- 5. teaching undo --
    do("seed", seed=5)
    do("new_game", sgf=None, props={"SZ": SIZE, "KM": 7.5}, analyze_fast=True)
    feed(0, game().root, root_score=-1.0)
    for _ in range(4):
        play(root_score=-1.0 + rng.uniform(-0.3, 0.3))
    do("player", bw="B", type="player:human", subtype="game:teach", rank=None, name="Alice")
    for target_loss, threshold in [(15.0, 0.5), (4.0, 0.9), (2.0, 0.2), (2.0, 0.8), (0.7, 0.1), (0.1, 0.1)]:
        g = game()
        while g.current_node.next_player != "B":
            play(root_score=g.current_node.score)
        parent_score = g.current_node.score
        error = play(feed_it=False)
        node = g.current_node
        do("analyze_undo", path=node_path(node))  # not analysed yet: nothing happens
        feed(last_query(), node, root_score=round(parent_score - target_loss, 4))
        do("undo_threshold", path=node_path(node), value=threshold)
        do("analyze_undo", path=node_path(node))
        do("analyze_undo", path=node_path(node))  # only once per node
    do("goto", path="0")
    do("analyze_undo", path="0.0")  # not the current node
    do("config", key="trainer/num_undo_prompts", value=[2, 1, 0.5, 0.5, 0, 0])
    while game().current_node.next_player != "B":
        play(root_score=game().current_node.score)
    for _ in range(3):
        parent_score = game().current_node.score
        play(feed_it=False)
        node = game().current_node
        feed(last_query(), node, root_score=round(parent_score - 20, 4))
        do("analyze_undo", path=node_path(node))
    default_player("B")

    # -- 6. scoring at the end, results, saving --
    ownership_b = [0.97 if (i % SIZE) < 4 else -0.96 for i in range(SIZE * SIZE)]
    do("play", move="pass", player=None, analyze=True, ignore_ko=False)
    feed(last_query(), game().current_node, ownership=ownership_b, root_score=2.25)
    do("manual_score")
    do("play", move="pass", player=None, analyze=True, ignore_ko=False)
    feed(last_query(), game().current_node, ownership=[o * 0.99 for o in ownership_b], root_score=2.75)
    do("manual_score")
    do("end_state", value="B+R")
    do("manual_score")
    do("end_state", value=None)
    do("player", bw="W", type="player:ai", subtype="ai:p:weighted", rank=-3.0, name="")
    do("player", bw="B", type="player:human", subtype="game:normal", rank=None, name='Bo<b> "x"/y')
    trainer = copy.deepcopy(config["trainer"])
    do("save", trainer=None)
    trainer.update({"save_analysis": True, "save_marks": True, "eval_show_ai": False})
    do("save", trainer=trainer)
    saved_with_analysis = saved_sgf()
    # loading it again: the stored analysis is used, nothing is analysed
    do("new_game", sgf=saved_with_analysis, props=None, analyze_fast=False)
    do("redo", n=99, stop=None)
    do("manual_score")
    do("save", trainer=None)
    default_player("B")
    default_player("W")

    # chinese rules: KataGo's score, rounded to half points
    do("new_game", sgf="(;GM[1]FF[4]SZ[9]KM[7]RU[chinese];B[ee];W[cc];B[];W[])", props=None, analyze_fast=False)
    for q in range(5):
        feed(q, node_at(game().root, ".".join(["0"] * q)), root_score=1.3 + q)
    do("redo", n=99, stop=None)
    do("manual_score")
    feed(4, game().current_node, root_score=0.0)
    do("manual_score")

    # -- 7. self-play to the end, as shortcuts --
    do("seed", seed=7)
    do("new_game", sgf=None, props={"SZ": SIZE}, analyze_fast=False)
    feed(0, game().root, root_score=0.5)
    for _ in range(3):
        play()
    def newest():
        return max(game().root.nodes_in_tree, key=lambda n: n.depth)

    do("selfplay", until="end", target=None)
    for i in range(6):
        node = game().current_node if i == 0 else newest()
        feed(last_query(), node, first="pass" if i == 5 else None)
    do("redo", n=1, stop=None)
    do("undo", n=1, stop=None)
    do("undo", n=1, stop=None)
    do("redo", n=99, stop=None)
    # self-play again from an earlier node replaces the shortcut
    do("undo", n=2, stop=None)
    do("selfplay", until="end", target=None)
    for i in range(3):
        node = game().current_node if i == 0 else newest()
        feed(last_query(), node, first="pass" if i == 2 else None)
    do("save", trainer=None)
    with_shortcuts = saved_sgf()
    do("new_game", sgf=with_shortcuts, props=None, analyze_fast=True)
    do("redo", n=99, stop=None)
    do("undo", n=2, stop=None)

    # -- 8. self-play to set up a position --
    do("seed", seed=8)
    do("new_game", sgf=None, props={"SZ": SIZE}, analyze_fast=False)
    feed(0, game().root, root_score=0.5)
    do("selfplay", until=9, target=4.5)
    feed(last_query(), game().root, root_score=0.5)
    scores = [1.0, 30.0, 2.5, -20.0, 3.5, 4.0, 4.4, 4.6, 5.0, 4.5]
    for i, score in enumerate(scores):
        feed(last_query(), game().current_node, root_score=score, spread=2.0, n_moves=6)
        if game().current_node.depth >= 9:
            break
    # policy only (1 visit): self-play to the end picks the top policy move
    do("selfplay", until="end", target=None)
    no_candidates = fake_result(game().current_node)
    no_candidates["moveInfos"] = []
    do("feed", query=last_query(), result=no_candidates, partial=False)

    # -- 9. handicap and loaded files --
    do("config", key="game/handicap", value=3)
    do("new_game", sgf=None, props={"SZ": SIZE}, analyze_fast=False)
    do("config", key="game/handicap", value=0)
    do("new_game", sgf="(;GM[1]FF[4]SZ[9]HA[2]KM[0.5];W[ee];B[cc])", props=None, analyze_fast=False)
    do("new_game", sgf="(;GM[1]FF[4]SZ[9]HA[2]AB[cc][gg];W[ee])", props=None, analyze_fast=False)
    do("new_game", sgf="(;GM[1]FF[4]SZ[9]AP[KaTrain:1.17.0];B[cc];W[gg];AE[cc];B[dd])", props=None, analyze_fast=False)
    do("redo", n=99, stop=None)
    do("new_game", sgf="(;GM[1]FF[4]SZ[13]RU[tt]PB[Bob]PW[Ann];B[aa];W[ba];B[ca];W[ab];B[bb];W[ac];B[])", props=None, analyze_fast=False)
    do("redo", n=99, stop=None)
    do("save", trainer=None)
    # ko
    do("new_game", sgf="(;GM[1]FF[4]SZ[9];B[bb];W[cb];B[ac];W[dc];B[cc];W[cd];B[bd];W[bc])", props=None, analyze_fast=True)
    do("redo", n=99, stop=None)
    do("play", move="C7", player="B", analyze=False, ignore_ko=False)
    do("play", move="C7", player="B", analyze=False, ignore_ko=True)
    do("play", move="J9", player="W", analyze=False, ignore_ko=False)
    do("play", move="Z9", player="B", analyze=False, ignore_ko=False)

    return s.result()
