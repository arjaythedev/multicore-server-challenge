#!/usr/bin/env bash
# Overload check, on the benchmark box, as root, against the running challenge.service (#35 was never scored:
# after a ~2,000-user burst it stopped answering for good). Three rounds of: 2,000 loadgen users with fast
# think time, killed after 8 s (connections dropped mid-request), plus 2,000 raw connections that send half a
# request or a whole one and reset at once. Then the server must still serve: GET /api/tags within 2 s and a short
# loadgen run with no errors.
set -euo pipefail
OUT=/root/mc/overload; rm -rf "$OUT"; mkdir -p "$OUT"
ulimit -n 1048576
for round in 1 2 3; do
  taskset -c 6,7 timeout -s KILL 8 /usr/local/bin/conduit-loadgen run -target http://127.0.0.1 -users 2000 -think-scale 0.02 \
    -ramp 1s -measure 30s -tail 1s -secret multicore-server-challenge -run-id "o$round$(date +%s)" -q -out "$OUT/burst$round.json" \
    > /dev/null 2>&1 || true
  python3 - <<'PY'
import socket, struct
socks = []
for i in range(2000):
    try:
        s = socket.socket(); s.setblocking(True); s.settimeout(2); s.connect(('127.0.0.1', 80))
        s.sendall(b'GET /api/articles?limit=100 HTTP/1.1\r\nHost: x\r\n' + (b'\r\n' if i % 2 else b''))
        socks.append(s)
    except OSError: pass
for s in socks:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0)); s.close()
PY
done
sleep 2
code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1/api/tags || true)
taskset -c 6,7 /usr/local/bin/conduit-loadgen run -target http://127.0.0.1 -users 300 -think-scale 0.1 -ramp 5s -measure 20s -tail 2s \
  -secret multicore-server-challenge -run-id "oc$(date +%s)" -q -out "$OUT/after.json" > /dev/null 2>&1 || true
/usr/local/bin/conduit-loadgen merge -o "$OUT/after-merged.json" "$OUT/after.json" > /dev/null 2>&1 || true
python3 - "$code" <<'PY'
import json, sys
m = json.load(open('/root/mc/overload/after-merged.json')); ov = m.get('overall', {})
ok = sys.argv[1] == '200' and (ov.get('error_rate') or 0) == 0 and ov.get('count', 0) > 0
print('overload %s: tags=%s, after: %s requests, error rate %s, p99 %s ms' % ('PASS' if ok else 'FAIL', sys.argv[1], ov.get('count'), ov.get('error_rate'), ov.get('p99_ms')))
PY
