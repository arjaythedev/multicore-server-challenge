"""Run the server with per-stage CPU accounting (cpusplit.sh uses this as the server entry point).

    .venv/bin/python scripts/stagetimer.py        # same env as conduit_server.main

Wraps the hot functions with thread CPU clocks (time.thread_time_ns: user+sys of this thread, excluding time spent
waiting in the run queue) and charges each stage its *exclusive* time. Nothing in conduit_server changes. In each
worker, SIGUSR1 resets the counters and SIGUSR2 writes them to $STAGES_DIR/stages-<pid>.json.
"""
import json
import os
import signal
import sys
import threading
import time
from collections import defaultdict

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from conduit_server import main as app  # noqa: E402
from conduit_server.adapters.inbound import router as router_mod, socket_server  # noqa: E402
from conduit_server.adapters.outbound import pg_repository, crypto_adapter  # noqa: E402

_clock = time.thread_time_ns
acc = defaultdict(int)
calls = defaultdict(int)
_local = threading.local()  # per thread (loop + bcrypt helper): open stages' CPU ns spent in timed children


def timed(stage, fn):
    def wrapper(*args, **kwargs):
        stack = getattr(_local, "stack", None)
        if stack is None:
            stack = _local.stack = [0]
        stack.append(0)
        t = _clock()
        try:
            return fn(*args, **kwargs)
        finally:
            elapsed = _clock() - t
            acc[stage] += elapsed - stack.pop()
            calls[stage] += 1
            stack[-1] += elapsed

    return wrapper


def _patch(owner, name, stage, static=False):
    fn = getattr(owner, name)
    setattr(owner, name, staticmethod(timed(stage, fn)) if static else timed(stage, fn))


Srv = socket_server.RawSocketHttpServer
_patch(Srv, "_read", "socket recv + framing")
_patch(Srv, "_send", "socket send")
_patch(Srv, "_flush", "socket send")
_patch(Srv, "_accept", "accept + close")
_patch(Srv, "_close", "accept + close")
_patch(Srv, "_respond", "requests")  # synchronous requests only (pipelined ones skip it); breakdown counts parses
_patch(socket_server, "parse_request", "http parse")  # imported by name into socket_server
_patch(router_mod.SocketRouter, "dispatch", "router dispatch")
_patch(router_mod.SocketRouter, "resume", "controllers + domain")  # generator handlers' bodies run inside it
_patch(router_mod.SocketRouter, "_build_response", "json encode + response bytes", static=True)
_patch(router_mod.HttpRequest, "json", "json decode (request)")
for route in router_mod.router.routes:
    route.handler = timed("controllers + domain", route.handler)

Crypto = crypto_adapter.JoseBcryptCryptoAdapter
for name in ("hash_password", "verify_password"):
    _patch(Crypto, name, "bcrypt")
for name in ("issue_token", "verify_token"):
    _patch(Crypto, name, "jwt verify/issue")

Repo = pg_repository.PostgresUserRepository
_patch(Repo, "_run", "libpq exec (send+wait+recv, params)", static=True)
_patch(Repo, "_run_json", "libpq exec (send+wait+recv, params)", static=True)
for name in [n for n in vars(Repo)
             if not n.startswith("__") and n not in ("_run", "_run_json") and callable(getattr(Repo, n))]:
    _patch(Repo, name, "repo: dict rows + glue")
_patch(pg_repository.SingleConnection, "get", "repo: dict rows + glue")
for name in ("submit", "ready", "flush"):
    _patch(pg_repository.PgPipeline, name, "libpq exec (send+wait+recv, params)")
_submit = pg_repository.PgPipeline.submit


def _counted_submit(self, query, token):
    inflight[len(self.inflight)] += 1  # queries already in flight when this one goes out
    return _submit(self, query, token)


inflight = defaultdict(int)
pg_repository.PgPipeline.submit = _counted_submit
_patch(pg_repository.Query, "result", "repo: dict rows + glue")

_RealTransformer = pg_repository.Transformer


class _TimedTransformer:
    """Per-connection row decoder with its two calls timed (the C Transformer's methods can't be patched)."""

    def __init__(self, conn):
        tx = _RealTransformer(conn)
        self.set_pgresult = timed("row decode (psycopg C)", tx.set_pgresult)
        self.load_rows = timed("row decode (psycopg C)", tx.load_rows)


pg_repository.Transformer = _TimedTransformer


def _clock_cost() -> int:
    """CPU ns one timed() wrapper adds around a call, so the report can show instrumentation overhead."""
    noop = timed("_calibrate", lambda: None)
    t = _clock()
    for _ in range(20000):
        noop()
    cost = (_clock() - t) // 20000
    acc.pop("_calibrate", None)
    calls.pop("_calibrate", None)
    return cost


_WRAPPER_NS = _clock_cost()


def _reset(*_):
    acc.clear()
    calls.clear()
    inflight.clear()


def _dump(*_):
    out = os.path.join(os.getenv("STAGES_DIR", "/tmp/conduit-lg"), f"stages-{os.getpid()}.json")
    with open(out, "w") as f:
        json.dump({"acc": dict(acc), "calls": dict(calls), "wrapper_ns": _WRAPPER_NS, "inflight": dict(inflight)}, f)


signal.signal(signal.SIGUSR1, _reset)  # inherited by every forked worker
signal.signal(signal.SIGUSR2, _dump)

if __name__ == "__main__":
    app.main()
