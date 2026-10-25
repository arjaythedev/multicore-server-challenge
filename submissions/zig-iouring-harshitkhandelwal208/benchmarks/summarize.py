#!/usr/bin/env python3
"""Turn run.sh output into a Markdown table: median over rounds (min-max in brackets) of each contender.

usage: summarize.py OUTPUT_FILE [label ...]    labels give the row order (default: order of first appearance)
        env: NAMES=file with `label<TAB>description` lines (optional)"""
import collections, os, re, statistics, sys

rows = collections.OrderedDict()
for line in open(sys.argv[1]):
    m = re.match(r"(\S+) r(\d+): (rps=.*)", line)
    if not m:
        continue
    if "LG-LIMITED" in m[3]:
        continue  # the load generator fell behind: this run says nothing about the server
    kv = {k: float(v) for k, v in re.findall(r"([\w/]+)=([\d.]+)", m[3].split(" pass")[0].split(" FAIL")[0])}
    rows.setdefault(m[1], []).append(dict(rps=kv["rps"], p50=kv["p50"], p95=kv["p95"], p99=kv.get("p99", float("nan")), err=int(kv["err"]),
                                          app=kv["srv_us/req"], pg=kv["pg_us/req"], ok=" pass " in m[3] + " "))
order = sys.argv[2:] or list(rows)
names = {}
if os.environ.get("NAMES"):
    for l in open(os.environ["NAMES"]):
        k, _, v = l.rstrip("\n").partition("\t")
        names[k] = v


def med(xs, fmt="%.1f"):
    xs = sorted(xs)
    return (fmt + " (" + fmt + "-" + fmt + ")") % (statistics.median(xs), xs[0], xs[-1])


print("| contender | runs | req/s | p50 ms | p95 ms | app us/req | postgres us/req | total us/req | errors | passes |")
print("|---|---|---|---|---|---|---|---|---|---|")
for lab in order:
    r = rows.get(lab)
    if not r:
        continue
    tot = [x["app"] + x["pg"] for x in r]
    print("| %s | %d | %.0f | %.1f | %s | %.1f | %s | %s | %d | %d/%d |" % (
        names.get(lab, lab), len(r), statistics.median(x["rps"] for x in r), statistics.median(x["p50"] for x in r),
        med([x["p95"] for x in r]), statistics.median(x["app"] for x in r), med([x["pg"] for x in r]), med(tot), sum(x["err"] for x in r),
        sum(1 for x in r if x["ok"]), len(r)))
