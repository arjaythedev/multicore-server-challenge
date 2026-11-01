#!/usr/bin/env bash
# A/B load test on one database: runs each arm in turn (A B A B ...), restarting the server with that arm's
# environment, and records loadgen's summary, CPU per process group and pg_stat_statements for every run.
# PROFILING ONLY: needs pg_stat_statements in the database (see tools/pgss.py) and bin/loadgen-style binary.
#
#   bash tools/ab.sh <database> <users> <measure seconds> <rounds> "A:ENV=1 ENV2=x" "B:ENV=0" ...
#
# Results go to /tmp/ab/<round>-<arm>.{loadgen,pgss,cpu}; tools/ab_report.py summarises them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUB="$(cd "$HERE/.." && pwd)"
DB=$1 USERS=$2 MEASURE=$3 ROUNDS=$4
shift 4
LOADGEN="${LOADGEN:-/tmp/loadgen}"
PORT="${PORT:-3120}"
START="${ROUND_START:-1}"  # >1 adds rounds to an earlier run's results instead of starting over
mkdir -p /tmp/ab
[ "$START" = 1 ] && rm -f /tmp/ab/*
ulimit -n 200000
for round in $(seq "$START" $((START + ROUNDS - 1))); do
  for arm in "$@"; do
    label="${arm%%:*}"
    envs="${arm#*:}"
    # CONDUIT_BIN=<path> in an arm runs that build instead of bin/conduit (name it "conduit" too, so the CPU
    # accounting and pkill find it)
    bin="$(echo "$envs" | sed -n 's/.*CONDUIT_BIN=\([^ ]*\).*/\1/p')"
    bin="${bin:-$SUB/bin/conduit}"
    pkill -x conduit 2>/dev/null || true
    sleep 1
    env DATABASE_URL="postgres://conduit:conduit@127.0.0.1:5432/$DB" JWT_SECRET=dev-secret HOST=127.0.0.1 \
      PORT="$PORT" $envs "$bin" > "/tmp/ab/$round-$label.server" 2>&1 &
    for _ in $(seq 50); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && break; sleep 0.2; done
    python3 "$HERE/pgss.py" "$DB" --reset
    python3 "$HERE/cpu_by_comm.py" > "/tmp/ab/$round-$label.cpu0"
    "$LOADGEN" run -target "http://127.0.0.1:$PORT" -users "$USERS" -ramp 5s -measure "${MEASURE}s" -tail 3s \
      -secret dev-secret -run-id "ab$round$label$$" -out "/tmp/ab/$round-$label.json" > "/tmp/ab/$round-$label.loadgen" 2>&1
    python3 "$HERE/cpu_by_comm.py" > "/tmp/ab/$round-$label.cpu1"
    python3 "$HERE/pgss.py" "$DB" > "/tmp/ab/$round-$label.pgss"
    echo "round $round $label: $(grep -E '^ALL' "/tmp/ab/$round-$label.loadgen")"
  done
done
pkill -x conduit 2>/dev/null || true
