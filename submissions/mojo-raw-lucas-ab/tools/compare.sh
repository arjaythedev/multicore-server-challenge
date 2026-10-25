#!/usr/bin/env bash
# Same-load comparison of several submissions on one machine. For each run, one submission at a time and in
# turn (A B C ... A B C ...): a fresh copy of the full seed, the submission's server in its tools/run_submission.sh
# container, a warm-up at the same load (a fresh copy starts with cold caches), then a measured loadgen run.
# Records req/s, latency, errors, the server's CPU (its container's cgroup, so every process it starts) and
# Postgres's (host processes named postgres), per 1,000 req/s. Loadgen's own CPU is in neither.
# FOR LOCAL COMPARISONS ONLY. Needs conduit_seed, /tmp/loadgen, and Postgres superuser access as the current user.
#
#   bash tools/compare.sh <users> <measure seconds> <rounds> <submission folder> [<folder> ...]
#
# Results: /tmp/compare/<round>-<name>.{json,loadgen,cpu}; tools/compare_report.py summarises them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
USERS=$1 MEASURE=$2 ROUNDS=$3
shift 3
OUT=/tmp/compare
PORT=3300
mkdir -p "$OUT"
rm -f "$OUT"/*
ulimit -n 200000
export PGDATABASE=postgres

snapshot() {  # container name -> JSON: server cgroup usec, postgres ticks, wall time
  local id; id=$(docker inspect -f '{{.Id}}' "$1")
  python3 - "$id" <<'EOF'
import json, os, sys
usec = 0
with open(f"/sys/fs/cgroup/system.slice/docker-{sys.argv[1]}.scope/cpu.stat") as f:
    for line in f:
        if line.startswith("usage_usec"):
            usec = int(line.split()[1])
pg = 0
for pid in os.listdir("/proc"):
    if pid.isdigit():
        try:
            s = open(f"/proc/{pid}/stat").read()
        except OSError:
            continue
        if s[s.index("(") + 1:s.rindex(")")] == "postgres":
            f = s[s.rindex(")") + 2:].split()
            pg += int(f[11]) + int(f[12])
print(json.dumps({"app_usec": usec, "pg_ticks": pg, "hz": os.sysconf("SC_CLK_TCK"), "time": os.times().elapsed}))
EOF
}

stop_all() {
  for c in $(docker ps --format '{{.Names}}' | grep '^sub-' || true); do
    docker exec "$c" bash -c 'pkill -u challenge || true' >/dev/null 2>&1 || true
  done
}

for round in $(seq "$ROUNDS"); do
  for folder in "$@"; do
    name="$(basename "$folder")"
    cname="sub-$(echo "$name" | tr 'A-Z' 'a-z')"
    db="cmp_$(echo "$name" | tr 'A-Z-' 'a-z_')"
    stop_all
    sleep 2
    psql -X -q -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" -c "CREATE DATABASE $db TEMPLATE conduit_seed STRATEGY FILE_COPY" \
      2>&1 | grep -vE "NOTICE|NOTA" || true
    bash "$HERE/run_submission.sh" up "$folder" "$PORT" "$db" dev-secret > "$OUT/$round-$name.server" 2>&1
    /tmp/loadgen run -target "http://127.0.0.1:$PORT" -users "$USERS" -ramp 20s -measure 40s -tail 5s \
      -secret dev-secret -run-id "w$round$name$$" -q -out /dev/null > /dev/null 2>&1 || true
    snapshot "$cname" > "$OUT/$round-$name.cpu0"
    /tmp/loadgen run -target "http://127.0.0.1:$PORT" -users "$USERS" -ramp 10s -measure "${MEASURE}s" -tail 5s \
      -secret dev-secret -run-id "m$round$name$$" -out "$OUT/$round-$name.json" > "$OUT/$round-$name.loadgen" 2>&1 || true
    snapshot "$cname" > "$OUT/$round-$name.cpu1"
    echo "round $round $name: $(grep -E '^ALL' "$OUT/$round-$name.loadgen" || echo 'no result')"
    stop_all
    psql -X -q -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" 2>&1 | grep -vE "NOTICE|NOTA" || true
  done
done
python3 "$HERE/compare_report.py" "$OUT"
