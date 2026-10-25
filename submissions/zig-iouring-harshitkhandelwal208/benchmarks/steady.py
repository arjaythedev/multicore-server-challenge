#!/usr/bin/env python3
"""Steady-state latency of each contender from the load generator's per-second timeline.

A run's measurement window starts right when the ramp ends, and every contender shows a start-up spike in its first
seconds (all users become active at once). This script drops the first STEADY_SKIP seconds of the window (default 5)
and the last second, then reports the median over runs of the median per-second p95 and p99 (each per-second value is
computed by the load generator over that second only).

usage: steady.py RESULTS_DIR TAGPREFIX label [label ...]      e.g. steady.py ../../runs/final final ours p64
"""
import glob, json, os, statistics, sys

skip = int(os.environ.get("STEADY_SKIP", "5"))
d, prefix, labels = sys.argv[1], sys.argv[2], sys.argv[3:]
print("| contender | runs | steady p95 ms | steady p99 ms |")
print("|---|---|---|---|")
for lab in labels:
    p95s, p99s = [], []
    for f in sorted(glob.glob(os.path.join(d, "%s-%s-*.merged.json" % (prefix, lab)))):
        try:
            m = json.load(open(f))
        except Exception:
            continue
        tl = m.get("timeline", [])
        if not tl:
            continue
        end = max(x["t"] for x in tl)
        steady = [x for x in tl if skip <= x["t"] < end and x.get("completed", 0) > 0]
        if not steady:
            continue
        p95s.append(statistics.median(x["p95_ms"] for x in steady))
        p99s.append(statistics.median(x["p99_ms"] for x in steady))
    if p95s:
        print("| %s | %d | %.1f (%.1f-%.1f) | %.1f (%.1f-%.1f) |" % (
            lab, len(p95s), statistics.median(p95s), min(p95s), max(p95s), statistics.median(p99s), min(p99s), max(p99s)))
