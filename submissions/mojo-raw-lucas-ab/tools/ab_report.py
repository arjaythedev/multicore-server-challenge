"""Summarises a tools/ab.sh run: per arm, req/s, latency, cores used by Postgres and by our server, Postgres
cores per 1,000 req/s, statement and planning time, and the top statements.

    python3 tools/ab_report.py [/tmp/ab]
"""
import glob
import json
import os
import re
import sys

d = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ab"
runs = {}
for lg in sorted(glob.glob(f"{d}/*.loadgen")):
    base = lg[:-len(".loadgen")]
    rnd, arm = os.path.basename(base).split("-", 1)
    all_line = next(l for l in open(lg) if l.startswith("ALL"))
    f = all_line.split()
    rps, p50, p95, p99, err = float(f[2]), float(f[3]), float(f[5]), float(f[6]), float(f[8])
    c0, c1 = json.load(open(base + ".cpu0")), json.load(open(base + ".cpu1"))
    el = c1["time"] - c0["time"]
    hz = os.sysconf("SC_CLK_TCK")

    def cores(name):
        return (c1["ticks"].get(name, 0) - c0["ticks"].get(name, 0)) / hz / el

    busy = 1 - (c1["idle"] - c0["idle"]) / max(1, c1["total"] - c0["total"])
    pg = open(base + ".pgss").read()
    total = float(re.search(r"total (\d+) ms", pg).group(1))
    plan = 0.0
    stmts = {}
    for line in pg.splitlines()[1:-1]:
        m = re.match(r"(.{20}) +(\d+) +(\d+) +(\d+) +([\d.]+)% +(\d+)", line)
        if m:
            plan += float(m.group(4))
            stmts[m.group(1).strip()] = (float(m.group(3)) + float(m.group(4))) / el  # ms per second
    runs.setdefault(arm, []).append(dict(rps=rps, p50=p50, p95=p95, p99=p99, err=err, pg=cores("postgres"),
                                         app=cores("conduit"), busy=busy, stmt=total / el, plan=plan / el,
                                         stmts=stmts, rnd=rnd))

print(f"{'arm':4s} {'rnd':>3s} {'req/s':>7s} {'p50':>5s} {'p95':>5s} {'p99':>5s} {'err%':>5s} {'pg cores':>8s}"
      f" {'app cores':>9s} {'pg/1k rps':>9s} {'VM busy':>7s} {'stmt ms/s':>9s} {'plan ms/s':>9s}")
for arm, rs in runs.items():
    for r in rs:
        print(f"{arm:4s} {r['rnd']:>3s} {r['rps']:7.0f} {r['p50']:5.1f} {r['p95']:5.1f} {r['p99']:5.1f} {r['err']:5.2f}"
              f" {r['pg']:8.2f} {r['app']:9.2f} {1000 * r['pg'] / r['rps']:9.3f} {100 * r['busy']:6.0f}%"
              f" {r['stmt']:9.0f} {r['plan']:9.0f}")
print()
means = {}
for arm, rs in runs.items():
    m = {k: sum(r[k] for r in rs) / len(rs) for k in ("rps", "pg", "app", "stmt", "plan", "p99")}
    m["pg_per_k"] = sum(1000 * r["pg"] / r["rps"] for r in rs) / len(rs)
    means[arm] = m
    print(f"{arm}: mean {m['rps']:.0f} req/s, Postgres {m['pg']:.2f} cores = {m['pg_per_k']:.3f} cores per 1k req/s,"
          f" server {m['app']:.2f} cores, statements {m['stmt']:.0f} ms/s of which planning {m['plan']:.0f} ms/s")
arms = list(means)
if len(arms) >= 2:
    a, b = means[arms[0]], means[arms[1]]
    print(f"\n{arms[1]} vs {arms[0]}: Postgres cores per 1k req/s {100 * (b['pg_per_k'] / a['pg_per_k'] - 1):+.1f}%,"
          f" statement time {100 * (b['stmt'] / a['stmt'] - 1):+.1f}%, planning {b['plan']:.0f} vs {a['plan']:.0f} ms/s")
    names = sorted(set(runs[arms[0]][0]["stmts"]) | set(runs[arms[1]][0]["stmts"]),
                   key=lambda n: -sum(r["stmts"].get(n, 0) for r in runs[arms[0]]))[:8]
    print(f"\n{'statement (ms per second)':26s} " + " ".join(f"{x:>8s}" for x in arms[:2]) + "   change")
    for n in names:
        va = sum(r["stmts"].get(n, 0) for r in runs[arms[0]]) / len(runs[arms[0]])
        vb = sum(r["stmts"].get(n, 0) for r in runs[arms[1]]) / len(runs[arms[1]])
        print(f"{n:26s} {va:8.1f} {vb:8.1f}   {100 * (vb / va - 1) if va else 0:+6.1f}%")

# Lists by kind, whatever the statements are called in each arm (a page + a count, or one combined statement):
# Postgres time per list request.
KINDS = ("global", "feed", "tag", "author", "favorited")


def list_cost(arm):
    out = {}
    for kind in KINDS:
        ms = calls = 0
        for lg in sorted(glob.glob(f"{d}/*-{arm}.pgss")):
            per = {}
            for line in open(lg).read().splitlines()[1:-1]:
                m = re.match(r"(.{20}) +(\d+) +(\d+) +(\d+)", line)
                if m and m.group(1).strip().split()[0] == kind:
                    per[m.group(1).strip()] = (int(m.group(2)), float(m.group(3)) + float(m.group(4)))
            ms += sum(t for _, t in per.values())
            calls += max((c for c, _ in per.values()), default=0)
        out[kind] = (ms, calls)
    return out


if len(arms) >= 2:
    ca, cb = list_cost(arms[0]), list_cost(arms[1])
    print(f"\n{'list (us per request)':22s} {arms[0]:>8s} {arms[1]:>8s}   change")
    for kind in KINDS:
        (ma, na), (mb, nb) = ca[kind], cb[kind]
        if na and nb:
            ua, ub = 1000 * ma / na, 1000 * mb / nb
            print(f"{kind:22s} {ua:8.0f} {ub:8.0f}   {100 * (ub / ua - 1):+6.1f}%")

# Per-statement time per call, round by round, with the median change: statements whose SQL didn't change show
# how much of a difference is just noise.
if "--per-round" in sys.argv and len(arms) >= 2:
    def per_call(path):
        out = {}
        for line in open(path).read().splitlines()[1:-1]:
            m = re.match(r"(.{20}) +(\d+) +(\d+) +(\d+) +([\d.]+)% +(\d+)", line)
            if m:
                out[m.group(1).strip()] = (int(m.group(6)), float(m.group(3)) + float(m.group(4)))  # us/call, total ms
        return out
    rounds = sorted({r["rnd"] for r in runs[arms[0]]} & {r["rnd"] for r in runs[arms[1]]}, key=int)
    skip = [x for x in sys.argv if x.startswith("--skip=")]
    skip = skip[0].split("=", 1)[1].split(",") if skip else []
    rounds = [r for r in rounds if r not in skip]
    per = {arm: {r: per_call(f"{d}/{r}-{arm}.pgss") for r in rounds} for arm in arms[:2]}
    names = sorted(per[arms[0]][rounds[0]], key=lambda n: -per[arms[0]][rounds[0]][n][1])[:10]  # busiest first
    print(f"\nus per call, {arms[0]} -> {arms[1]}, rounds {','.join(rounds)} (median change)")
    for n in names:
        us = {arm: {r: per[arm][r].get(n, (0, 0))[0] for r in rounds} for arm in arms[:2]}
        changes = sorted(100 * (us[arms[1]][r] / us[arms[0]][r] - 1) for r in rounds if us[arms[0]][r])
        cells = "  ".join(f"{us[arms[0]][r]:4d}->{us[arms[1]][r]:4d}" for r in rounds)
        print(f"  {n:18s} {cells}   {changes[len(changes) // 2]:+6.1f}%")
