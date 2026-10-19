"""Engine fixtures: the queries KaTrain writes to KataGo, and what it does with KataGo's answers.

KaTrain's own writer and reader thread functions run here, synchronously: the write queue is a stand-in that stops
the writer when it is empty, and the KataGo process is a stand-in whose stdin is recorded and whose stdout plays back
prepared lines. Each step is recorded so the Dart test can do exactly the same.
"""

import json
import queue
import threading


class _Done(Exception):
    pass


class _ListQueue:
    """Queue stand-in: get() pops in order and stops the writer when empty."""

    def __init__(self):
        self.items = []

    def put(self, item):
        self.items.append(item)

    def get(self, block=True, timeout=None):
        if not self.items:
            raise _Done()
        return self.items.pop(0)

    def get_nowait(self):
        if not self.items:
            raise queue.Empty()  # what KaTrain's _drain_write_queue expects
        return self.items.pop(0)

    def empty(self):
        return not self.items


class _Stdin:
    def __init__(self):
        self.lines = []

    def write(self, data):
        self.lines.append(data.decode().rstrip("\n"))

    def flush(self):
        pass


class _Stdout:
    def __init__(self, engine):
        self.engine = engine
        self.lines = []

    def readline(self):
        if self.lines:
            return (self.lines.pop(0) + "\n").encode()
        self.engine.katago_process = None  # ends the reader loop
        return b""


class _Process:
    def __init__(self, engine):
        self.stdin = _Stdin()
        self.stdout = _Stdout(engine)

    def poll(self):
        return None


SGF = (
    "(;GM[1]FF[4]SZ[9]KM[5.5]RU[chinese]HA[2]AB[cc][gg]PL[W]"
    ";W[ee];B[ec];W[ce](;B[dd];W[gc];B[cg])(;B[dc];AE[ee];W[ff]))"
)

CONFIG = {"max_visits": 500, "fast_visits": 25, "max_time": 8.0, "wide_root_noise": 0.04, "_enable_ownership": True}


def build(katrain_unused=None):
    from pysgf import Move

    from katrain.core.engine import KataGoEngine
    from katrain.core.game import KaTrainSGF

    class Host:
        def __init__(self):
            self.updates = 0
            self.errors = []

        def log(self, message, level):
            pass

        def update_state(self, *args, **kwargs):
            self.updates += 1

        def __call__(self, message, *args):
            self.errors.append([message, str(args[0]) if args else None, args[1] if len(args) > 1 else None])

    host = Host()
    engine = KataGoEngine.__new__(KataGoEngine)
    engine.katrain = host
    engine.config = dict(CONFIG)
    engine.allow_recovery = True
    engine.queries = {}
    engine.ponder_query = None
    engine.query_counter = 0
    engine.base_priority = 0
    engine.query_generation = 0
    engine.override_settings = {"reportAnalysisWinratesAs": "BLACK"}
    engine.write_queue = _ListQueue()
    engine.thread_lock = threading.RLock()
    engine.shell = False
    process = _Process(engine)
    engine.katago_process = process

    root = KaTrainSGF.parse_sgf(SGF)

    def preorder(node):
        stack = [node]
        while stack:
            n = stack.pop()
            yield n
            stack.extend(reversed(n.children))

    nodes = list(preorder(root))
    events = []

    def flush_writes():
        try:
            engine._write_stdin_thread()
        except _Done:
            pass
        written = [json.loads(line) for line in process.stdin.lines]
        process.stdin.lines.clear()
        return written

    def callback(tag):
        def cb(result, partial):
            events.append(["callback", tag, result["id"], partial, result["rootInfo"]["visits"]])

        return cb

    def error_callback(tag):
        def cb(result):
            events.append(["error_callback", tag, result["id"], result["error"]])

        return cb

    steps = []

    def request(node_ix, tag, with_error_callback=False, next_move=None, **kwargs):
        node = nodes[node_ix]
        nm = Move.from_gtp(next_move, player=node.next_player) if next_move else None
        engine.request_analysis(
            node,
            callback=callback(tag),
            error_callback=error_callback(tag) if with_error_callback else None,
            next_move=nm,
            **kwargs,
        )
        steps.append(
            {
                "op": "request",
                "node": node_ix,
                "tag": tag,
                "error_callback": with_error_callback,
                "next_move": next_move,
                "kwargs": kwargs,
                "written": flush_writes(),
                "visits_requested": node.analysis_visits_requested,
            }
        )

    def answer(lines):
        events.clear()
        before = host.updates
        process.stdout.lines = list(lines)
        engine._analysis_read_thread()
        engine.katago_process = process
        steps.append(
            {
                "op": "lines",
                "lines": lines,
                "events": list(events),
                "updates": host.updates - before,
                "outstanding": sorted(engine.queries.keys()),
            }
        )

    def op(name, fn, **extra):
        fn()
        steps.append({"op": name, **extra, "written": flush_writes(), "outstanding": sorted(engine.queries.keys())})

    def result(qid, visits, partial=False, **extra):
        return json.dumps(
            {
                "id": qid,
                "isDuringSearch": partial,
                "turnNumber": 1,
                "rootInfo": {"visits": visits, "winrate": 0.5, "scoreLead": 1.0},
                "moveInfos": [{"move": "D4", "order": 0, "visits": visits, "winrate": 0.5, "scoreLead": 1.0, "pv": ["D4"]}],
                **extra,
            }
        )

    # some nodes need analysis for find_alternatives
    nodes[2].set_analysis(
        {
            "rootInfo": {"visits": 10, "winrate": 0.5, "scoreLead": 0.0},
            "moveInfos": [
                {"move": "D5", "order": 0, "visits": 6, "winrate": 0.5, "scoreLead": 0.0, "pv": ["D5"]},
                {"move": "F4", "order": 1, "visits": 4, "winrate": 0.4, "scoreLead": -1.0, "pv": ["F4"]},
            ],
        },
        None,
        False,
        None,
        False,
    )

    request(0, "root")
    request(1, "visits", visits=1234)
    request(2, "fast", analyze_fast=True, time_limit=False)
    request(2, "alternatives", find_alternatives=True, priority=100)
    request(3, "region", region_of_interest=[1, 4, 2, 6])
    request(4, "refine", next_move="E5", visits=50)
    request(4, "noown", ownership=False, include_policy=False, report_every=None)
    request(5, "extra", extra_settings={"playoutDoublingAdvantage": 0.5, "wideRootNoise": 0.1}, report_every=0.5)
    assert nodes[8].clear_placements and not nodes[7].clear_placements
    request(8, "ae")  # AE in the path: not analysed
    request(9, "ae2")
    request(3, "ponder", ponder=True)
    request(3, "ponder_again", ponder=True)  # same position: nothing sent
    request(4, "ponder_other", ponder=True)  # replaces the pondering query
    request(1, "witherr", with_error_callback=True)

    ids = {st["tag"]: st["written"][0]["id"] for st in steps if st["op"] == "request" and st["written"]}
    answer(
        [
            result(ids["root"], 20, partial=True),
            result(ids["root"], 500),
            result(ids["visits"], 30, partial=True),
            json.dumps({"id": ids["fast"], "warning": "some warning"}),
            json.dumps({"id": ids["alternatives"], "error": "something failed"}),
            json.dumps({"id": ids["refine"], "error": "Illegal move at E5"}),
            json.dumps({"id": ids["witherr"], "error": "with callback"}),
            json.dumps({"id": "QUERY:999", "rootInfo": {}}),
            json.dumps({"no": "id"}),
            json.dumps({"id": ids["region"], "action": "terminate", "terminateId": ids["region"]}),
            result(ids["noown"], 0, noResults=True),
            "{not json",
            result(ids["visits"], 1234),
        ]
    )
    op("terminate_query", lambda: engine.terminate_query(ids["extra"]), query=ids["extra"])
    op("terminate_queries_for_node", lambda: engine.terminate_queries(only_for_node=nodes[4]), node=4)
    op("stop_pondering", engine.stop_pondering)
    op("on_new_game", engine.on_new_game)
    request(1, "after_new_game")
    answer([result(ids["fast"], 99), result(f"QUERY:{engine.query_counter}", 77)])

    return {"sgf": SGF, "config": CONFIG, "steps": steps, "errors": host.errors}
