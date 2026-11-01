#!/usr/bin/env bash
# Local load run inside the container (server, Postgres and loadgen share the CPUs: compare settings only).
#   bash dev/load.sh <users> [think-scale] [template db] [extra env for start.sh, e.g. "LOOPS=4 READ_CONNS=8"]
set -euo pipefail
USERS=${1:-5000}; TS=${2:-0.2}; TPL=${3:-conduit_dev}; EXTRA=${4:-}
ART=10000; [ "$TPL" = conduit_seed ] && ART=500000
docker exec -e USERS=$USERS -e TS=$TS -e TPL=$TPL -e ART=$ART -e EXTRA="$EXTRA" -e JOPTS="${JOPTS:-}" cbox bash -c '
set -e
export PATH=/opt/jdk/bin:/usr/local/go/bin:$PATH
cd /repo/bench && [ -x /tmp/loadgen ] || go build -o /tmp/loadgen ./cmd/loadgen
runuser -u postgres -- psql -qXc "DROP DATABASE IF EXISTS lg WITH (FORCE)" -c "CREATE DATABASE lg TEMPLATE $TPL STRATEGY FILE_COPY"
pkill -f [c]hallenge.Main || true; sleep 1
cd /repo/submissions/java-servlet-clickin
env $EXTRA DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/lg JWT_SECRET=dev HOST=127.0.0.1 PORT=3110 \
  JAVA_OPTS="-Xlog:gc:file=/tmp/gc.log ${JOPTS:-}" bash start.sh > /tmp/server.log 2>&1 &
for _ in $(seq 60); do curl -sf -o /dev/null http://127.0.0.1:3110/api/tags && break; sleep 1; done
ulimit -n 1048576
cpu() { for p in $(pgrep -f "$1"); do awk "{s+=\$14+\$15} END{print s}" /proc/$p/stat; done | awk "{s+=\$1} END{print s+0}"; }
J0=$(cpu "[c]hallenge.Main"); P0=$(cpu "^postgres"); T0=$(date +%s.%N)
/tmp/loadgen run -target http://127.0.0.1:3110 -users $USERS -ramp 15s -measure 40s -tail 5s \
  -secret dev -articles $ART -think-scale $TS -run-id r$RANDOM -out /tmp/local.json 2>&1 | tail -30
J1=$(cpu "[c]hallenge.Main"); P1=$(cpu "^postgres"); T1=$(date +%s.%N)
echo "== CPU over the whole run (cores): java $(echo "($J1-$J0)/100/($T1-$T0)" | bc -l | cut -c1-5)  postgres $(echo "($P1-$P0)/100/($T1-$T0)" | bc -l | cut -c1-5)"
echo "== GC"; grep -c "Pause" /tmp/gc.log || true; tail -3 /tmp/gc.log
pkill -f [c]hallenge.Main || true
'
