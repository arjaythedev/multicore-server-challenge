#!/usr/bin/env bash
# usage: WORKERS=6 bash scripts/cpusplit.sh <test-users>  -- user/sys/PG CPU and context switches per request,
#   then a per-stage ns/request CPU budget (scripts/stagetimer.py + breakdown.py; STAGES=0 to skip)
set -uo pipefail
APP="$(cd "$(dirname "$0")/.." && pwd)"; S=/tmp/conduit-lg; mkdir -p $S
USERS=$1
export DATABASE_URL=${DATABASE_URL:-postgres://conduit:conduit@127.0.0.1:5432/conduit_lg} JWT_SECRET=dev-secret HOST=127.0.0.1 PORT=3111 WORKERS=${WORKERS:-6}
rm -f $S/stages-*.json  # STAGES=0: plain server, no per-stage counters
if [ "${STAGES:-1}" = 1 ]; then ENTRY=scripts/stagetimer.py; else ENTRY="-m conduit_server.main"; fi
(cd $APP && STAGES_DIR=$S exec .venv/bin/python $ENTRY) > $S/srv.log 2>&1 &
PID=$!
for _ in $(seq 30); do curl -sf -o /dev/null http://127.0.0.1:3111/api/tags && break; sleep 1; done
/tmp/conduit-lg/loadgen run -target http://127.0.0.1:3111 -users $USERS -ramp 5s -measure 20s -tail 2s \
  -secret dev-secret -articles 500000 -think-scale 0.2 -run-id cs-$RANDOM -out $S/lg.json > $S/lg.out 2>&1 &
LG=$!
snap() { # utime stime vol nonvol summed over all threads of all server procs
  local u=0 s=0 v=0 n=0
  for p in $PID $(pgrep -P $PID); do for t in /proc/$p/task/*; do
    read -r -a f < <(sed 's/.*) //' $t/stat); u=$((u+f[11])); s=$((s+f[12]))
    v=$((v+$(awk '/^voluntary/{print $2}' $t/status))); n=$((n+$(awk '/^nonvoluntary/{print $2}' $t/status)))
  done; done; echo $u $s $v $n; }
pgs() { awk '{s+=$14+$15} END{print s}' $(for p in $(pgrep -u postgres postgres 2>/dev/null; pgrep -x postgres); do echo /proc/$p/stat; done | sort -u) 2>/dev/null; }
workers() { pgrep -P $PID || echo $PID; }
sig() { [ "${STAGES:-1}" = 1 ] && kill -$1 $(workers); }  # plain server (STAGES=0) has no USR1/USR2 handlers
sleep 10; sig USR1; read u0 s0 v0 n0 < <(snap); g0=$(pgs); t0=$(date +%s.%N)  # reset stage counters
sleep 10; read u1 s1 v1 n1 < <(snap); g1=$(pgs); t1=$(date +%s.%N); sig USR2  # dump them
wait $LG; grep -E "^(ALL|verdict)" $S/lg.out
RPS=$(awk '/^ALL/{print $3}' $S/lg.out)
awk -v u=$((u1-u0)) -v s=$((s1-s0)) -v v=$((v1-v0)) -v n=$((n1-n0)) -v g=$((g1-g0)) -v dt=$(echo "$t1-$t0"|bc) -v rps=$RPS 'BEGIN{
  hz=100; r=rps*dt; printf "~%.0f req/s | app user %.0fus sys %.0fus | pg %.0fus | ctxsw vol %.1f invol %.1f per req | app %.0f%% cpu\n",
  rps, u/hz/r*1e6, s/hz/r*1e6, g/hz/r*1e6, v/r, n/r, (u+s)/hz/dt*100
  printf "%.0f %.0f\n", (u+s)/hz*1e9, g/hz*1e9 > "'$S/ns.txt'"}'
[ "${STAGES:-1}" = 1 ] && $APP/.venv/bin/python $APP/scripts/breakdown.py $S $(cat $S/ns.txt)
kill $PID; wait $PID 2>/dev/null
