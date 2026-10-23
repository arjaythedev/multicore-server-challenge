#!/usr/bin/env bash
# Local load test against the full seed: bash scripts/loadtest.sh <label> <test-users> [WORKERS]
# Needs a full-seed copy `conduit_lg` (see README "Measured"); results land in /tmp/conduit-lg/<label>.*
# -think-scale 0.2: each test user makes ~5x a real user's requests (users ≈ req/s / 0.263 on the leaderboard).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT=/tmp/conduit-lg; mkdir -p "$OUT"
LABEL=$1 USERS=$2
[ -x "$OUT/loadgen" ] || (cd "$ROOT/bench" && go build -o "$OUT/loadgen" ./cmd/loadgen)
export DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_lg JWT_SECRET=dev-secret HOST=127.0.0.1 PORT=3110
[ -n "${3:-}" ] && export WORKERS=$3
(cd "$HERE" && exec .venv/bin/python -m conduit_server.main) > "$OUT/$LABEL.server.log" 2>&1 &
PID=$!
for _ in $(seq 30); do curl -sf -o /dev/null http://127.0.0.1:3110/api/tags && break; sleep 1; done
# CPU split (app vs postgres) sampled mid-run
( sleep 28; top -b -d 10 -n 2 -w 200 | awk '/^top -/{n++} n==2 && NR>7 {c[$12]+=$9} END{for(k in c) if(c[k]>20) printf "cpu %s %.0f%%\n",k,c[k]}' ) &
TOP=$!
"$OUT/loadgen" run -target http://127.0.0.1:3110 -users "$USERS" -ramp 15s -measure 30s -tail 5s \
  -secret dev-secret -articles 500000 -think-scale 0.2 -run-id "$LABEL-$RANDOM" -out "$OUT/$LABEL.json" 2>&1 \
  | grep -E "^(ALL|errors|verdict)"
wait $TOP
pkill -P $PID; kill $PID; wait $PID 2>/dev/null
sleep 5
