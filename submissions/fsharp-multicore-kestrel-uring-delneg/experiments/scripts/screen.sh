#!/usr/bin/env bash
# CPU per request at a fixed load (the experiment's deciding number), on the benchmark box, as root.
#
#   screen.sh <submission> <label> [users=6000] [think-scale=0.1] [env-file]
#
# Fresh database and cold caches as the grader does (switch.sh --no-conformance), the server under
# challenge.service with the extra environment from <env-file> (KEY=VALUE lines, a systemd drop-in), then the
# loadgen pinned to CPUs 6-7: ramp 30 s, measure 150 s. CPU is counted over the last 120 s of the measure window
# (the first 30 s are warm-up): box busy (user+nice+sys+irq+softirq, steal excluded) minus the loadgen's own process,
# split into the app's cgroup, Postgres's cgroup and the rest (kernel work charged to no unit, monitors).
# -think-scale overstates users (#25): use this only for CPU per request, never to estimate a score.
# Output: /root/mc/screens/<label>/{result.txt,result.json,lg.json,merged.txt,switch.log}
set -euo pipefail
NAME="${1:?submission}"; LABEL="${2:?label}"; USERS="${3:-6000}"; SCALE="${4:-0.1}"; ENVF="${5:-}"
RAMP=30; MEAS=150; SKIP=30
OUT="/root/mc/screens/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
DROP=/etc/systemd/system/challenge.service.d/zz-exp.conf
mkdir -p "$(dirname "$DROP")"
{ echo "[Service]"; if [ -n "$ENVF" ]; then { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENVF" || true; } | sed 's/^/Environment=/'; fi; } > "$DROP"
cp "$DROP" "$OUT/env.conf"
systemctl daemon-reload
/opt/conduit-tools/switch.sh "$NAME" --no-conformance > "$OUT/switch.log" 2>&1 || { tail -20 "$OUT/switch.log"; exit 1; }
START=$(( $(date +%s%3N) + 3000 ))
taskset -c 6,7 /usr/local/bin/conduit-loadgen run -target http://127.0.0.1 -users "$USERS" -think-scale "$SCALE" \
  -ramp ${RAMP}s -measure ${MEAS}s -tail 5s -start-at "$START" -secret multicore-server-challenge \
  -run-id "s$(date +%s)" -q -out "$OUT/lg.json" > "$OUT/lg.log" 2>&1 &
LG=$!
python3 - "$OUT" "$START" "$RAMP" "$MEAS" "$SKIP" "$LG" <<'PY'
import json, os, subprocess, sys, time
out, start, ramp, meas, skip, lg = sys.argv[1], int(sys.argv[2]) / 1000, int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
HZ = os.sysconf('SC_CLK_TCK')
def cg(unit):
    g = subprocess.run(['systemctl', 'show', '-p', 'ControlGroup', '--value', unit], capture_output=True, text=True).stdout.strip()
    d = {}
    try:
        for l in open('/sys/fs/cgroup' + g + '/cpu.stat'):
            k, v = l.split(); d[k] = int(v)
    except OSError: pass
    return d
def snap():
    f = [int(x) for x in open('/proc/stat').readline().split()[1:]]
    busy = f[0] + f[1] + f[2] + f[5] + f[6]
    total = sum(f[:8])
    try:
        s = open('/proc/%d/stat' % lg).read().rsplit(')', 1)[1].split()
        lgt = int(s[11]) + int(s[12])
    except OSError: lgt = 0
    return dict(t=time.time(), busy=busy, total=total, steal=f[7], softirq=f[6], sys=f[2], app=cg('challenge.service'), pg=cg('postgresql@18-main.service'), lg=lgt)
def wait_until(t):
    while time.time() < t: time.sleep(min(0.2, t - time.time()) if t - time.time() > 0 else 0)
wait_until(start + ramp + skip); a = snap()
wait_until(start + ramp + meas); b = snap()
json.dump(dict(a=a, b=b), open(out + '/snap.json', 'w'))
PY
wait $LG || true
/usr/local/bin/conduit-loadgen merge -o "$OUT/merged.json" "$OUT/lg.json" > "$OUT/merged.txt" 2>&1 || true
python3 - "$OUT" "$RAMP" "$MEAS" "$SKIP" "$NAME" "$USERS" "$SCALE" <<'PY'
import json, os, sys
out, ramp, meas, skip = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
s = json.load(open(out + '/snap.json')); a, b = s['a'], s['b']
lg = json.load(open(out + '/lg.json'))
HZ = os.sysconf('SC_CLK_TCK')
reqs = sum(x.get('completed', 0) for x in lg['timeline'] if ramp + skip <= x['t'] < ramp + meas)
errs = sum(x.get('errors', 0) for x in lg['timeline'] if ramp + skip <= x['t'] < ramp + meas)
secs = b['t'] - a['t']
us = lambda ticks: ticks * 1e6 / HZ
box = us(b['busy'] - a['busy']); lgc = us(b['lg'] - a['lg'])
app = b['app'].get('usage_usec', 0) - a['app'].get('usage_usec', 0)
appsys = b['app'].get('system_usec', 0) - a['app'].get('system_usec', 0)
pg = b['pg'].get('usage_usec', 0) - a['pg'].get('usage_usec', 0)
steal = (b['steal'] - a['steal']) * 100 / max(1, b['total'] - a['total'])
m = json.load(open(out + '/merged.json')) if os.path.exists(out + '/merged.json') else {}
ov = m.get('overall', {})
r = dict(label=os.path.basename(out), submission=sys.argv[5], users=int(sys.argv[6]), scale=float(sys.argv[7]),
         rps=reqs / secs, errors=errs, box_us=(box - lgc) / reqs, app_us=app / reqs, app_sys_us=appsys / reqs, pg_us=pg / reqs,
         other_us=(box - lgc - app - pg) / reqs, lg_us=lgc / reqs, steal_pct=steal, box_cores=(box - lgc) / secs / 1e6,
         p50=ov.get('p50_ms'), p95=ov.get('p95_ms'), p99=ov.get('p99_ms'), err_rate=ov.get('error_rate'))
json.dump(r, open(out + '/result.json', 'w'))
txt = ('%(label)s %(submission)s users=%(users)d scale=%(scale)g: %(rps).0f req/s, box %(box_us).1f us/req '
       '(app %(app_us).1f [sys %(app_sys_us).1f], pg %(pg_us).1f, other %(other_us).1f; loadgen %(lg_us).1f), '
       '%(box_cores).2f cores, steal %(steal_pct).1f%%, p50 %(p50)s p95 %(p95)s p99 %(p99)s ms, errors %(errors)d' % r)
open(out + '/result.txt', 'w').write(txt + '\n'); print(txt)
PY
