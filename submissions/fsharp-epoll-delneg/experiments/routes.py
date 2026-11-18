#!/usr/bin/env python3
# One line per phase from merged.json: login and sign-up latency/errors, then every route with a non-2xx status or an
# error class (a 404/500 under load that conformance doesn't show is a bug). usage: routes.py merged.json
import json, sys
d = json.load(open(sys.argv[1]))
out = []
for e in d["endpoints"]:
    n = e["name"]
    if n in ("POST /api/users/login", "POST /api/users"):
        out.append("%s n=%d p95=%.0f p99=%.0f max=%.0f err=%.3f%%" % (n.split()[1], e["count"], e["p95_ms"], e["p99_ms"], e["max_ms"], 100 * e["error_rate"]))
for e in d["endpoints"]:
    bad = {k: v for k, v in e.get("statuses", {}).items() if not k.startswith("2")}
    cls = e.get("error_classes", {}) or {}
    if bad or cls:
        out.append("%s bad=%s classes=%s" % (e["name"], json.dumps(bad, separators=(",", ":")), json.dumps(cls, separators=(",", ":"))))
print(" | ".join(out) if out else "no errors")
