"""Per-request CPU budget in ns, from the stage counters scripts/stagetimer.py dumps (cpusplit.sh runs both).

    .venv/bin/python scripts/breakdown.py <dir with stages-*.json> <app_cpu_ns> <pg_cpu_ns>

<app_cpu_ns>/<pg_cpu_ns>: total CPU of the server processes / Postgres over the measured window (from /proc).
Stages are exclusive thread CPU (user+sys) summed over every worker for that window; everything is divided by the
requests the workers actually served in it. "loop + unaccounted" is app CPU minus all timed stages.
"""
import glob
import json
import os
import sys
from collections import Counter

GOAL_APP_NS, GOAL_TOTAL_NS = 50_000, 8 * 1e9 / 30_000  # 50 µs app; 30k req/s on 8 vCPUs


def main():
    folder, app_total, pg_total = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    acc, calls, wrapper_ns, inflight = Counter(), Counter(), 0, Counter()
    for path in glob.glob(os.path.join(folder, "stages-*.json")):
        d = json.load(open(path))
        acc.update(d["acc"])
        calls.update(d["calls"])
        wrapper_ns = d["wrapper_ns"]
        inflight.update({int(k): v for k, v in d.get("inflight", {}).items()})
    requests = calls.get("http parse", 0)  # parse_request runs once per request, pipelined or not
    if not requests:
        print("no stage counters (was the server started via scripts/stagetimer.py?)")
        return
    app_ns, pg_ns = app_total / requests, pg_total / requests
    per = {stage: ns / requests for stage, ns in acc.items()}
    per["loop + unaccounted"] = app_ns - sum(per.values())
    print(f"\nper-request CPU budget (ns), {requests} requests, {sum(calls.values()) / requests:.1f} timed calls/req")
    print(f"  {'stage':38} {'ns/req':>8} {'share':>6} {'calls/req':>9}")
    for stage, ns in sorted(per.items(), key=lambda kv: -kv[1]):
        print(f"  {stage:38} {ns:8.0f} {ns / app_ns:6.1%} {calls.get(stage, 0) / requests:9.2f}")
    print(f"  {'= app (user+sys)':38} {app_ns:8.0f}   goal {GOAL_APP_NS:.0f}"
          f"  (~{sum(calls.values()) * wrapper_ns / requests:.0f} of it is this instrumentation, inside the stages)")
    print(f"  {'+ postgres':38} {pg_ns:8.0f}")
    print(f"  {'= total CPU per request':38} {app_ns + pg_ns:8.0f}   goal {GOAL_TOTAL_NS:.0f}"
          f"  -> {8e9 / (app_ns + pg_ns):.0f} req/s on 8 vCPU")
    if inflight:  # pipeline: queries already in flight on the worker's connection when each one was submitted
        n = sum(inflight.values())
        print("  pipeline depth at submit: " + ", ".join(
            f"{k}: {v / n:.1%}" for k, v in sorted(inflight.items()) if k < 4 or k == max(inflight))
              + f"  (mean {sum(k * v for k, v in inflight.items()) / n:.2f})")


if __name__ == "__main__":
    main()
