"""Run one op on both servers, compare, and keep running statistics.

Read-only runs execute ops on a thread pool (order is irrelevant on an
unchanged database). Write runs execute ops one at a time, the two servers
in parallel, so both databases see the same sequence.
Memory: only counters, the first `MAX_SHOWN` mismatches and one example
per mismatch class are kept.
"""
import json
import re
import threading
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

from . import compare
from .client import Call
from .gen import Gen, Op
from .gen_read import READ_OPS
from .gen_write import WRITE_OPS, op_register
from .side import Side

MAX_SHOWN = 10
CHUNK = 400
WRITE_SHARE = 0.4
BOOTSTRAP_USERS = 12      # registrations at the start of a --writes run
INDEX = re.compile(r"\[\d+\]")


@dataclass(slots=True)
class Mismatch:
    index: int
    label: str
    reason: str
    detail: str
    request: str
    a: str
    b: str


class Stats:
    """Counters for the summary; `add` is thread-safe."""

    def __init__(self):
        self.count: Counter = Counter()
        self.bad: Counter = Counter()
        self.status: dict = defaultdict(Counter)
        self.errors: Counter = Counter()          # (side label, status) for 5xx/no answer
        self.error_example: dict = {}
        self.shown: list = []
        self.classes: dict = {}                   # (label, reason, sa, sb) -> [count, first mismatch]
        self._lock = threading.Lock()

    def add(self, op: Op, index: int, a: tuple, b: tuple, why, request: str):
        with self._lock:
            self._add(op, index, a, b, why, request)

    def _add(self, op: Op, index: int, a: tuple, b: tuple, why, request: str):
        self.count[op.label] += 1
        self.status[op.label][a[0]] += 1
        for name, summary in (("A", a), ("B", b)):
            if summary[0] == 0 or summary[0] >= 500:
                self.errors[(name, op.label, summary[0])] += 1
                self.error_example.setdefault((name, op.label, summary[0]), request)
        if why is None:
            return
        self.bad[op.label] += 1
        rec = Mismatch(index, op.label, why[0], why[1], request, compare.clip(a[2]), compare.clip(b[2]))
        rec.a, rec.b = f"{a[0]} ct_ok={a[1]} {rec.a}", f"{b[0]} ct_ok={b[1]} {rec.b}"
        self.shown.append(rec)
        self.shown = sorted(self.shown, key=lambda m: m.index)[:MAX_SHOWN]
        key = (op.label + (f" <{op.variant}>" if op.variant else ""), INDEX.sub("[]", why[0]), a[0], b[0])
        entry = self.classes.setdefault(key, [0, rec])
        entry[0] += 1
        if rec.index < entry[1].index:
            entry[1] = rec


def request_text(call: Call, sent_a, sent_b) -> str:
    body = "" if call.body is None else " body=" + compare.clip(call.body if not isinstance(call.body, bytes) else call.body.decode("utf-8", "replace"))
    auth = "" if call.auth is None else f" auth={call.auth[0]}:{str(call.auth[1])[:60]}"
    return f"{call.method} A:{sent_a.path[:200]} B:{sent_b.path[:200]}{auth}{body}"


class Runner:
    """Owns both sides and turns an `Op` into a recorded comparison."""

    def __init__(self, a: Side, b: Side, run_start: float, stats: Stats):
        self.a, self.b, self.start, self.stats = a, b, run_start, stats

    def _summary(self, side: Side, sent, call: Call):
        resp = sent.resp
        return compare.summarise(resp, call, sent.token, side.secret, self.start)

    def _hooks(self, op: Op, sent_a, sent_b, sum_a, sum_b, parsed):
        if op.after:
            for side, sent, summ in ((self.a, sent_a, sum_a), (self.b, sent_b, sum_b)):
                op.after(side, summ[0], parsed(sent))

    def run(self, op: Op, index: int, pool=None):
        """Send `op` to both sides (concurrently if `pool`), compare, record."""
        if pool:
            fut = pool.submit(self.b.run, op.call)
            sent_a = self.a.run(op.call)
            sent_b = fut.result()
        else:
            sent_a, sent_b = self.a.run(op.call), self.b.run(op.call)
        sum_a, sum_b = self._summary(self.a, sent_a, op.call), self._summary(self.b, sent_b, op.call)
        self.stats.add(op, index, sum_a, sum_b, compare.compare(sum_a, sum_b), request_text(op.call, sent_a, sent_b))
        self._hooks(op, sent_a, sent_b, sum_a, sum_b, _parsed)


def _parsed(sent):
    try:
        return json.loads(sent.resp.body) if sent.resp.body else None
    except ValueError:
        return None


def pick(rng, table):
    """Weighted choice of a generator function from (weight, fn) pairs."""
    return rng.choices([fn for _, fn in table], weights=[w for w, _ in table])[0]


def next_op(g: Gen, writes: bool, index: int) -> Op:
    """Follow-ups first, then bootstrap registrations, then the weighted mix."""
    if g.pending:
        return g.pending.pop(0)
    if writes:
        if index < BOOTSTRAP_USERS:
            return op_register(g)
        if g.rng.random() < WRITE_SHARE:
            return pick(g.rng, WRITE_OPS)(g)
    return pick(g.rng, READ_OPS)(g)


def run_all(runner: Runner, g: Gen, count: int, writes: bool, workers: int, progress):
    """Generate and execute `count` ops."""
    if writes:
        with ThreadPoolExecutor(1) as pool:
            for i in range(count):
                runner.run(next_op(g, True, i), i, pool)
                progress(i + 1)
        return
    with ThreadPoolExecutor(workers) as pool:
        done = 0
        while done < count:
            n = min(CHUNK, count - done)
            ops = [next_op(g, False, done + i) for i in range(n)]
            list(pool.map(lambda pair: runner.run(pair[1], done + pair[0]), enumerate(ops)))
            done += n
            progress(done)
