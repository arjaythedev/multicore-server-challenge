#!/usr/bin/env python3
"""Differential tester: sends one random request mix to two Conduit servers and compares them.

Usage: python3 -I difftest.py --a http://127.0.0.1:3101 --b http://127.0.0.1:3102 \
           --secret dev-secret --articles 10000 --users 2000 --count 20000 --seed 1 [--writes]
Exit status 1 when any response pair differs. See README.md.
"""
import argparse
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # -I drops the script dir from sys.path

from dt import gen, report, runner, world  # noqa: E402
from dt.client import Call  # noqa: E402
from dt.model import WriteModel  # noqa: E402
from dt.side import Side  # noqa: E402

DEFAULT_SAMPLE = 400


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--a", required=True, help="base URL of server A (also the source of discovery)")
    p.add_argument("--b", required=True, help="base URL of server B")
    p.add_argument("--secret", required=True, help="JWT secret both servers use")
    p.add_argument("--articles", type=int, default=10000, help="articles in the database")
    p.add_argument("--users", type=int, default=2000, help="user ids 1..N to sample from")
    p.add_argument("--count", type=int, default=20000, help="requests (follow-ups included)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--writes", action="store_true", help="also run POST/PUT/DELETE flows in lockstep")
    p.add_argument("--evil", action="store_true",
                   help="with --writes: titles with NUL / lone surrogates (servers may disagree and then diverge)")
    p.add_argument("--workers", type=int, default=16, help="threads for read-only runs")
    p.add_argument("--sample", type=int, default=DEFAULT_SAMPLE, help="users sampled for discovery")
    return p.parse_args(argv)


def preflight(a: Side, b: Side):
    """Both servers must answer /api/tags with the same list before anything else runs."""
    sent = [s.run(Call("GET", "/api/tags")) for s in (a, b)]
    for side, s in zip((a, b), sent):
        if s.resp.status != 200:
            raise SystemExit(f"server {side.label} is not ready: {s.resp.status} {s.resp.error}")
    if sent[0].resp.body != sent[1].resp.body:
        print("warning: /api/tags differs between the servers (different data?)", file=sys.stderr)


def main(argv) -> int:
    sys.stdout.reconfigure(errors="backslashreplace")
    sys.stderr.reconfigure(errors="backslashreplace")
    args = parse_args(argv)
    rng = random.Random(args.seed)
    a, b = Side("A", args.a, args.secret), Side("B", args.b, args.secret)
    preflight(a, b)
    started = time.time()
    data = world.discover(a, rng, args.articles, args.users, args.sample)
    slugs, cids = data.seed_maps()
    for side in (a, b):
        side.slug.update(slugs)
        side.cid.update(cids)
    print(f"discovered {len(data.users)} users, {len(data.arts)} articles, {len(data.cmts)} comments, "
          f"{len(data.tags)} tags in {time.time() - started:.1f}s", file=sys.stderr)
    model = WriteModel() if args.writes else None
    g = gen.Gen(rng, data, args.secret, f"{args.seed}x{int(started) % 100000}", model, args.evil)
    stats = runner.Stats()
    run_started = time.time()
    progress = lambda n: print(f"  {n}/{args.count}", file=sys.stderr) if n % 2000 == 0 else None
    runner.run_all(runner.Runner(a, b, run_started, stats), g, args.count, args.writes, args.workers, progress)
    bad = report.print_report(stats, time.time() - run_started, sum(stats.count.values()))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
