#!/usr/bin/env bash
# One load test: fresh copy of the seed DB, start a submission pinned to SRV_CPUS, warm up, measure with the
# challenge's own loadgen pinned to LG_CPUS. Prints req/s, p50/p95/p99, errors, CPU-µs per request for the app and
# for Postgres, app RSS and fds, pass/fail. Appends the line to $RESULTS/ALL.txt.
#
#   lab/bench.sh <submission-dir> <users> <think-scale> [measure_s=60] [ramp_s=60]
#
# think-scale 1.0 is the real workload (users = connections). Above ~50k users the users are spread over several
# loopback target addresses (127.0.0.1, .2, ...) so no (src,dst) pair runs out of ephemeral ports.
# env: TEMPLATE (conduit_seed) SRV_CPUS (0-7) LG_CPUS (8-15) PORT (3000) TAG WARM_USERS (2000) WARM_S (60)
#      LOADGEN (bench/cmd/loadgen binary; built if missing) RESULTS (lab/results) KEEP=1 (leave server up)
#      PG_CGROUP (Postgres in a container: its cgroup dir) PG_USER (host user owning the Postgres processes)
# Needs: root or a high hard nofile limit (the server gets 200000 like the box; loadgen gets 1048576),
#        Postgres superuser via PGHOST/PGPORT/PGUSER, Postgres itself pinned with lab/pin-postgres.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
exec 9>/tmp/conduit-bench.lock; flock 9          # one load test at a time
DIR="$(cd "$1" && pwd)"; USERS=$2; SCALE=$3; MEAS=${4:-60}; RAMP=${5:-60}
TEMPLATE=${TEMPLATE:-conduit_seed}; SRV_CPUS=${SRV_CPUS:-0-7}; LG_CPUS=${LG_CPUS:-8-15}
WARM_USERS=${WARM_USERS:-2000}; WARM_S=${WARM_S:-60}; PORT=${PORT:-3000}; TAG=${TAG:-$(basename "$DIR")}
ARTICLES=${ARTICLES:-$([ "$TEMPLATE" = conduit_dev ] && echo 10000 || echo 500000)}
RESULTS=${RESULTS:-$HERE/results}; mkdir -p "$RESULTS"
LOADGEN=${LOADGEN:-$ROOT/bench/.loadgen}
[ -x "$LOADGEN" ] || (cd "$ROOT/bench" && go build -o "$LOADGEN" ./cmd/loadgen)
OUT=$RESULTS/runs/$TAG-u$USERS-s$SCALE-$(date +%H%M%S); mkdir -p "$OUT"
DB=bench_db; PSQL="psql -X -q -v ON_ERROR_STOP=1 -d postgres"
$PSQL -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -c "CREATE DATABASE $DB TEMPLATE $TEMPLATE STRATEGY FILE_COPY"
export DATABASE_URL="postgres://conduit:conduit@127.0.0.1:${PGPORT:-5432}/$DB" JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT
fuser -k $PORT/tcp >/dev/null 2>&1 || true
(ulimit -n 200000 2>/dev/null || true; cd "$DIR" && exec taskset -c $SRV_CPUS bash start.sh) > "$OUT/server.log" 2>&1 &
SPID=$!
for _ in $(seq 120); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && break; sleep 0.5; done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" || { echo "server not up"; tail -20 "$OUT/server.log"; exit 1; }
APP=$(fuser $PORT/tcp 2>/dev/null | awk '{print $1}'); APP=${APP:-$SPID}
echo "app pid $APP ($(cat /proc/$APP/comm)), nofile: $(awk '/open files/{print $4}' /proc/$APP/limits)"
NT=$(( (USERS + ${PER_TARGET:-50000} - 1) / ${PER_TARGET:-50000} )); TARGETS=""
for i in $(seq 1 $NT); do TARGETS="${TARGETS:+$TARGETS,}http://127.0.0.$i:$PORT"; done
ticks() { awk '{print $14+$15}' /proc/$1/stat 2>/dev/null || echo 0; }
# Postgres CPU: summed over host processes of user postgres, or (Postgres in a container) from its cgroup:
#   PG_CGROUP=/sys/fs/cgroup/system.slice/docker-<full id>.scope   (cpu.stat usage_usec, converted to ticks)
pgticks() {
  if [ -n "${PG_CGROUP:-}" ]; then awk -v hz=$(getconf CLK_TCK) '/^usage_usec/{printf "%d\n", $2*hz/1e6}' "$PG_CGROUP/cpu.stat"; return; fi
  local s=0 t; for p in $(pgrep -u "${PG_USER:-postgres}" 2>/dev/null); do t=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null || echo 0); s=$((s+t)); done; echo $s; }
LG() { ulimit -n 1048576 2>/dev/null || true; taskset -c $LG_CPUS "$LOADGEN" "$@"; }
if [ "$WARM_S" -gt 0 ]; then
  LG run -target "$TARGETS" -users $WARM_USERS -ramp 10s -measure ${WARM_S}s -tail 2s -secret $JWT_SECRET \
    -articles $ARTICLES -think-scale 0.2 -run-id warm$RANDOM -q -out "$OUT/warm.json" >/dev/null 2>&1 || true
  sleep 5
fi
START=$(( $(date +%s%3N) + 3000 ))
LG run -target "$TARGETS" -users $USERS -ramp ${RAMP}s -measure ${MEAS}s -tail 5s -secret $JWT_SECRET \
  -articles $ARTICLES -think-scale $SCALE -run-id r$(date +%s) -start-at $START -q -out "$OUT/box0.json" > "$OUT/lg.log" 2>&1 &
LGPID=$!
sleep $(awk -v s=$START -v r=$RAMP 'BEGIN{ d=(s + r*1000)/1000 - systime(); print (d>0)?d:0 }')
A0=$(ticks $APP); P0=$(pgticks); T0=$(date +%s%3N)
sleep $MEAS
A1=$(ticks $APP); P1=$(pgticks); T1=$(date +%s%3N)
RSS=$(awk '/VmRSS/{print $2}' /proc/$APP/status); FDS=$(ls /proc/$APP/fd | wc -l)
wait $LGPID || true
"$LOADGEN" merge -o "$OUT/merged.json" "$OUT/box0.json" > "$OUT/merged.txt" 2>&1 || true
python3 - "$OUT" $A0 $A1 $P0 $P1 $T0 $T1 $(getconf CLK_TCK) $RSS $FDS "$TAG" $USERS $SCALE "$RESULTS" <<'PY'
import json,sys
out,a0,a1,p0,p1,t0,t1,hz,rss,fds,tag,users,scale,res=sys.argv[1:]
a=(int(a1)-int(a0))/int(hz); p=(int(p1)-int(p0))/int(hz); win=(int(t1)-int(t0))/1000
m=json.load(open(out+"/merged.json")); o=m["overall"]; v=m["verdict"]
req=o["rps"]*win or 1
line=(f"{tag} users={users} scale={scale} rps={o['rps']:.0f} p50={o['p50_ms']:.1f} p95={o['p95_ms']:.1f} p99={o['p99_ms']:.1f} "
      f"err={o['error_rate']:.4f} | app={a/win*100:.0f}%cpu pg={p/win*100:.0f}%cpu | app_us/req={a/req*1e6:.1f} "
      f"pg_us/req={p/req*1e6:.1f} total_us/req={(a+p)/req*1e6:.1f} | rss={int(rss)//1024}MB fds={fds} "
      f"pass={v['pass']} lgcpu={m['boxes'][0]['proc_cpu_avg_measure_pct']:.0f}% lg_limited={v.get('lg_limited')} "
      f"{';'.join(v.get('fail_reasons') or [])}")
print(line); open(out+"/summary.txt","w").write(line+"\n"); open(res+"/ALL.txt","a").write(line+"\n")
PY
if [ "${KEEP:-0}" != 1 ]; then kill $APP 2>/dev/null || true; sleep 1; kill -9 $APP 2>/dev/null || true; fi
