import sys, json, re
L = sys.stdin.read().splitlines()
try:
    d = json.loads(L[0])
    m = re.search(r"server cores=([\d.]+) postgres cores=([\d.]+)", L[2])
    s, p = float(m[1]), float(m[2])
    lg = "LG-LIMITED" if "'lg_limited': True" in L[2] else "lg-ok"
    ok = "pass" if "'pass': True" in L[2] else "FAIL"
    print("rps=%.0f p50=%.1f p95=%.1f p99=%.1f err=%d srv=%.2f pg=%.2f  srv_us/req=%.1f pg_us/req=%.1f %s %s" % (
        d["rps"], d["p50_ms"], d["p95_ms"], d["p99_ms"], d["errors"], s, p, s / d["rps"] * 1e6, p / d["rps"] * 1e6, ok, lg))
except Exception as e:
    print("PARSE FAIL", e, L)
