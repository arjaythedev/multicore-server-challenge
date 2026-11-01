"""Summarises a tools/compare.sh run: per submission and round, req/s, latency, errors, and the cores the server
and Postgres used, also per 1,000 req/s; then each submission's median over its rounds.

    python3 tools/compare_report.py [/tmp/compare]
"""
import glob
import json
import os
import statistics
import sys

d = sys.argv[1] if len(sys.argv) > 1 else "/tmp/compare"
rows = {}
for lg in sorted(glob.glob(f"{d}/*.loadgen")):
    base = lg[:-len(".loadgen")]
    rnd, name = os.path.basename(base).split("-", 1)
    line = next((l for l in open(lg) if l.startswith("ALL")), None)
    if line is None or not os.path.exists(base + ".cpu1"):
        print(f"{name} round {rnd}: no result")
        continue
    f = line.split()
    rps, p50, p95, p99, err = float(f[2]), float(f[3]), float(f[5]), float(f[6]), float(f[8])
    c0, c1 = json.load(open(base + ".cpu0")), json.load(open(base + ".cpu1"))
    el = c1["time"] - c0["time"]
    app = (c1["app_usec"] - c0["app_usec"]) / 1e6 / el
    pg = (c1["pg_ticks"] - c0["pg_ticks"]) / c1["hz"] / el
    rows.setdefault(name, []).append(dict(rnd=rnd, rps=rps, p50=p50, p95=p95, p99=p99, err=err, app=app, pg=pg))

print(f"{'submission':26s} {'rnd':>3s} {'req/s':>6s} {'p50':>5s} {'p95':>6s} {'p99':>7s} {'err%':>5s}"
      f" {'app cores':>9s} {'pg cores':>8s} {'app/1k':>7s} {'pg/1k':>6s} {'total/1k':>8s}")
for name, rs in rows.items():
    for r in rs:
        k = 1000 / r["rps"]
        print(f"{name:26s} {r['rnd']:>3s} {r['rps']:6.0f} {r['p50']:5.1f} {r['p95']:6.1f} {r['p99']:7.1f} {r['err']:5.2f}"
              f" {r['app']:9.2f} {r['pg']:8.2f} {r['app'] * k:7.3f} {r['pg'] * k:6.3f} {(r['app'] + r['pg']) * k:8.3f}")
print("\nmedian over rounds (cores per 1,000 req/s; latency in ms)")
print(f"{'submission':26s} {'req/s':>6s} {'app/1k':>7s} {'pg/1k':>6s} {'total/1k':>8s} {'p50':>5s} {'p95':>6s} {'p99':>7s} {'err%':>5s}")
summary = []
for name, rs in rows.items():
    med = lambda key: statistics.median(r[key] for r in rs)  # noqa: E731
    app_k = statistics.median(1000 * r["app"] / r["rps"] for r in rs)
    pg_k = statistics.median(1000 * r["pg"] / r["rps"] for r in rs)
    summary.append((app_k + pg_k, name))
    print(f"{name:26s} {med('rps'):6.0f} {app_k:7.3f} {pg_k:6.3f} {app_k + pg_k:8.3f} {med('p50'):5.1f}"
          f" {med('p95'):6.1f} {med('p99'):7.1f} {med('err'):5.2f}")
print("\ncheapest first (server + Postgres cores per 1,000 req/s): "
      + ", ".join(f"{n} {t:.3f}" for t, n in sorted(summary)))
