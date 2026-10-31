#!/usr/bin/env bash
# A capacity hold on the benchmark box, as root: real think time, ramp 60 s + hold 300 s at <users>, the loadgen
# on the same box pinned to CPUs 6-7 (it takes CPU from the server, so this is a lower bound, not the score;
# its lg_limited flag reads the whole box and fires here: judge the loadgen by its own CPU and fell_behind).
#
#   hold.sh <submission> <label> <users> [env-file] [--aged]
#
# Fresh database first (switch.sh --no-conformance) unless --aged (keeps the database of the previous run:
# the grader's search never resets it between warm-up, probes and hold, #79). score/monitor.sh samples the
# app/Postgres split and steal every second. Output: /root/mc/holds/<label>/
set -euo pipefail
NAME="${1:?submission}"; LABEL="${2:?label}"; USERS="${3:?users}"; ENVF="${4:-}"; AGED="${5:-}"
OUT="/root/mc/holds/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
DROP=/etc/systemd/system/challenge.service.d/zz-exp.conf
mkdir -p "$(dirname "$DROP")"
{ echo "[Service]"; if [ -n "$ENVF" ]; then { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENVF" || true; } | sed 's/^/Environment=/'; fi; } > "$DROP"
cp "$DROP" "$OUT/env.conf"
systemctl daemon-reload
if [ "$AGED" = --aged ]; then
  systemctl restart challenge.service
  for _ in $(seq 60); do curl -sf -m 2 -o /dev/null http://127.0.0.1/api/tags && break; sleep 1; done
else
  /opt/conduit-tools/switch.sh "$NAME" --no-conformance > "$OUT/switch.log" 2>&1 || { tail -20 "$OUT/switch.log"; exit 1; }
fi
(cd "$OUT" && setsid nohup /opt/conduit-tools/monitor.sh 1 "$OUT/monitor.csv" > /dev/null 2>&1 < /dev/null &)
START=$(( $(date +%s%3N) + 3000 ))
ulimit -n 1048576
taskset -c 6,7 /usr/local/bin/conduit-loadgen run -target http://127.0.0.1 -users "$USERS" \
  -ramp 60s -measure 300s -tail 5s -start-at "$START" -secret multicore-server-challenge \
  -run-id "h$(date +%s)" -q -out "$OUT/lg.json" > "$OUT/lg.log" 2>&1 || true
pkill -f "monitor.sh 1 $OUT/monitor.csv" || true
/usr/local/bin/conduit-loadgen merge -o "$OUT/merged.json" "$OUT/lg.json" > "$OUT/merged.txt" 2>&1 || true
python3 - "$OUT" "$USERS" <<'PY'
import csv, json, sys
out, users = sys.argv[1], int(sys.argv[2])
m = json.load(open(out + '/merged.json')); ov = m.get('overall', {})
rows = [r for r in csv.DictReader(open(out + '/monitor.csv'))]
lg = json.load(open(out + '/lg.json'))
t0 = lg['meta']['start_at_ms'] / 1000 + 60; t1 = t0 + 300
w = [r for r in rows if t0 <= float(r['ts']) < t1] or rows
avg = lambda k: sum(float(r[k] or 0) for r in w) / max(1, len(w))
box = lg.get('box') or {}
txt = ('%s users=%d: %s, %.0f req/s, p50 %s p95 %s p99 %s ms, errors %.3f%%; box cpu %.0f%% steal %.1f%%, app %.0f%% pg %.0f%% of a core, '
       'app pss %.0f MB; loadgen cpu %s%% fell_behind %s' % (out.rsplit('/', 1)[1], users, m.get('verdict', {}).get('status', m.get('verdict')),
       ov.get('rps', 0), ov.get('p50_ms'), ov.get('p95_ms'), ov.get('p99_ms'), 100 * (ov.get('error_rate') or 0),
       avg('cpu'), avg('steal'), avg('app_core'), avg('pg_core'), avg('app_pss'), box.get('proc_cpu_avg_measure_pct'), box.get('fell_behind')))
open(out + '/result.txt', 'w').write(txt + '\n'); print(txt)
PY
