#!/usr/bin/env bash
# Scorer-like harness on wsl26 (our box only; the submission itself pins nothing).
#   h.sh <label> <built-sub-dir> <mode> <users...>
#   mode: probe (60s ramp + 60s), hold (60s ramp + 300s), cpu (60s ramp + 60s, no verdict needed)
#   env: WARM=1 (3 min warm-up at 500 users), FRESH=1 (fresh DB + PG restart + drop caches), APPENV="K=V K2=V2"
#   Several user counts: run in order on the same DB (like the scorer, no reset between phases).
set -u
L=$1; SUB=$2; MODE=$3; shift 3
H=$HOME/mc-fs2-h; OUT=$H/runs/$L; mkdir -p $OUT
export PATH=$HOME/go-sdk/bin:$PATH PGHOST=127.0.0.1 PGUSER=delneg PGPASSWORD=delneg
SECRET=multicore-server-challenge; LG=$H/loadgen; LGFIRST=${LGFIRST:-8}; LGLAST=${LGLAST:-19}
exec >> $OUT/run.log 2>&1
echo "=== $(date -u +%FT%TZ) $L $SUB $MODE $* WARM=${WARM:-1} FRESH=${FRESH:-1} APPENV=${APPENV:-}"
sudo sysctl -q -w net.core.somaxconn=65535 net.ipv4.tcp_max_syn_backlog=65535 net.ipv4.ip_local_port_range="1024 65535" net.ipv4.tcp_tw_reuse=1 fs.file-max=2097152 fs.nr_open=1048576
ulimit -n 1048576
sudo systemctl stop mcfs2-app 2>/dev/null; sudo systemctl reset-failed mcfs2-app 2>/dev/null
pkill -f "$LG run" 2>/dev/null
rsync -a --delete --exclude experiments "$SUB"/ /opt/mcfs2/app/ && chmod -R a+rX /opt/mcfs2/app
if [ "${FRESH:-1}" = 1 ]; then
  psql -X -q -d postgres -c "DROP DATABASE IF EXISTS conduit WITH (FORCE)" -c "CREATE DATABASE conduit TEMPLATE conduit_seed STRATEGY FILE_COPY OWNER conduit"
  sudo systemctl restart postgresql@18-main; sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
fi
ENVARGS=(); for kv in ${APPENV:-}; do ENVARGS+=(--setenv=$kv); done
sudo systemd-run -q --unit=mcfs2-app -p User=challenge -p Group=challenge -p LimitNOFILE=200000 -p AllowedCPUs=0-7 \
  -p AmbientCapabilities=CAP_NET_BIND_SERVICE -p WorkingDirectory=/opt/mcfs2/app -p KillMode=mixed -p TimeoutStopSec=20 \
  --setenv=HOME=/home/challenge --setenv=DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
  --setenv=JWT_SECRET=$SECRET --setenv=HOST=0.0.0.0 --setenv=PORT=80 "${ENVARGS[@]}" /opt/mcfs2/app/start.sh
t0=$(date +%s.%N); ok=0
for i in $(seq 120); do curl -sf -o /dev/null -m 2 http://127.0.0.1/api/tags && { ok=1; break; }; sleep 0.5; done
echo "health ok=$ok after $(echo "$(date +%s.%N)-$t0" | bc | cut -c1-5)s"
[ $ok = 1 ] || { sudo journalctl -u mcfs2-app --no-pager | tail -30; exit 1; }
APPCG=/sys/fs/cgroup/system.slice/mcfs2-app.service
PGCG=/sys/fs/cgroup/system.slice/system-postgresql.slice/postgresql@18-main.service
( while :; do echo "$(date +%s.%N) $(awk '/usage_usec/{print $2}' $APPCG/cpu.stat) $(awk '/usage_usec/{print $2}' $PGCG/cpu.stat) $(cat $APPCG/memory.current) $(cat $PGCG/memory.current) $(awk '/^cpu /{print $2+$4+$7+$8, $2+$3+$4+$5+$6+$7+$8}' /proc/stat)"; sleep 1; done ) > $OUT/mon.txt &
MON=$!
phase() { # name users ramp measure
  local N=$1 U=$2 R=$3 M=$4 D=$OUT/$1; mkdir -p $D
  local PER=${PER:-40000}; local K=$(( (U + PER - 1) / PER )); local per=$(( U / K )); local rem=$(( U - per*K ))
  local sa=$(( $(date +%s%N) / 1000000 + 5000 )) off=0 pids=() files=()
  for k in $(seq 0 $((K-1))); do
    local u=$per; [ $k -lt $rem ] && u=$((u+1))
    local ncpu=$((LGLAST-LGFIRST+1)); local a=$((LGFIRST + k*ncpu/K)); local b=$((LGFIRST + (k+1)*ncpu/K - 1))
    GOMAXPROCS=$((b-a+1)) taskset -c $a-$b $LG run -target http://127.0.0.$((k+1)):80 -users $u -box-index $k -id-offset $off -ramp ${R}s -measure ${M}s \
      -tail 15s -start-at $sa -secret $SECRET -articles 500000 -run-id $L-$N-$RANDOM -q -out $D/box$k.json > $D/box$k.log 2>&1 &
    pids+=($!); files+=($D/box$k.json); off=$((off+u))
  done
  if [ -n "${PERF:-}" ]; then # profile the app mid-window from the build CPUs (needs APPENV=DOTNET_PerfMapEnabled=1)
    ( sleep $((R + 15)); sudo taskset -c 20-23 perf record -q -F 499 -g -p $(systemctl show -p MainPID --value mcfs2-app) -o $D/perf.data -- sleep 30 >/dev/null 2>&1 ) &
  fi
  if [ -n "${PGSPLIT:-}" ]; then # Postgres CPU by connection name / process type over 40 s of the window
    ( sleep $((R + 15)); $H/pgsplit.sh 40 > $D/pgsplit.txt 2>&1 ) &
  fi
  if [ -n "${PGPERF:-}" ]; then # profile CPUs 0-7 (app and Postgres) mid-window; filter with --comm postgres
    ( sleep $((R + 15)); sudo taskset -c 20-23 perf record -q -F 499 -g -a -C 0-7 -o $D/pgperf.data -- sleep 20 >/dev/null 2>&1 ) &
  fi
  wait "${pids[@]}"
  $LG merge -o $D/merged.json "${files[@]}" > $D/merged.txt 2>&1
  local ws=$(echo "$sa/1000 + $R" | bc -l) we=$(echo "$sa/1000 + $R + $M" | bc -l)
  local cpu=$(awk -v a=$ws -v b=$we '$1>=a && $1<=b {if(!n){a0=$2;p0=$3;t0=$1;b0=$6;bt0=$7}; a1=$2;p1=$3;t1=$1;b1=$6;bt1=$7; if($4>am)am=$4; if($5>pm)pm=$5; n++} END{dt=t1-t0; printf "app_cores=%.2f pg_cores=%.2f box_busy=%.1f%% app_mem_max=%dMB pg_mem_max=%dMB", (a1-a0)/1e6/dt, (p1-p0)/1e6/dt, 100*(b1-b0)/(bt1-bt0), am/1048576, pm/1048576}' $OUT/mon.txt)
  local s=$(jq -r '"pass=\(.verdict.pass) lg=\(.verdict.lg_limited) rps=\(.overall.rps|floor) p50=\(.overall.p50_ms) p95=\(.overall.p95_ms) p99=\(.overall.p99_ms) err=\(.overall.error_rate*100|tostring|.[0:6])% lgcpu=\([.boxes[].proc_cpu_avg_measure_pct|floor]) behind=\([.boxes[].fell_behind])"' $D/merged.json)
  local rps=$(jq '.overall.rps' $D/merged.json)
  local us=$(echo "$cpu" | awk -v r=$rps '{split($1,a,"=");split($2,b,"="); printf "us_req=%.1f app_us=%.1f pg_us=%.1f", (a[2]+b[2])*1e6/r, a[2]*1e6/r, b[2]*1e6/r}')
  echo "RESULT $L $N users=$U $s $us $cpu" | tee -a $H/results.txt
  curl -sf -o /dev/null -m 5 http://127.0.0.1/api/tags || echo "RESULT $L $N APP DEAD after phase" | tee -a $H/results.txt
}
if [ "${WARM:-1}" = 1 ]; then phase warmup 500 60 120; sleep 5; fi
passed() { grep "RESULT $L $1 " $H/results.txt | tail -1 | grep -q "pass=true lg=false"; }
nice2() { python3 -c "import math,sys;x=float(sys.argv[1]);e=10**max(1,int(math.floor(math.log10(x)))-1);print(int(round(x/e)*e))" $1; }
idle() { sleep 5; for i in $(seq 45); do b=$(awk '/^cpu /{print $2+$4+$7+$8, $2+$3+$4+$5+$6+$7+$8}' /proc/stat); sleep 2; b2=$(awk '/^cpu /{print $2+$4+$7+$8, $2+$3+$4+$5+$6+$7+$8}' /proc/stat); u=$(echo "$b $b2" | awk '{print 100*($3-$1)/($4-$2)*24/8}'); awk -v u=$u 'BEGIN{exit !(u<15)}' && return; done; }
if [ $MODE = search ]; then
  lo=0; hi=0; U=${START:-25000}
  while :; do idle; phase probe-$U $U 60 60; if passed probe-$U; then lo=$U; U=$((U*2)); else hi=$U; break; fi; [ $U -gt 400000 ] && break; done
  while [ $hi -gt 0 ] && [ $lo -gt 0 ] && [ $((hi-lo)) -gt $((lo/20)) ]; do U=$(nice2 $(( (lo+hi)/2 ))); { [ $U -le $lo ] || [ $U -ge $hi ]; } && break; idle; phase probe-$U $U 60 60; if passed probe-$U; then lo=$U; else hi=$U; fi; done
  U=$lo; while [ $U -gt 0 ]; do idle; phase hold-$U $U 60 300; if passed hold-$U; then echo "RESULT $L SCORE $U" | tee -a $H/results.txt; break; fi; U=$(nice2 $((U*95/100))); done
else
for U in "$@"; do
  case $MODE in hold) idle; phase hold-$U $U 60 300 ;; *) idle; phase $MODE-$U $U 60 60 ;; esac
  [ "${STOPFAIL:-0}" = 1 ] && ! passed $MODE-$U && break
done
fi
kill $MON
sudo journalctl -u mcfs2-app --no-pager | tail -5
sudo systemctl stop mcfs2-app
echo "=== done $(date -u +%FT%TZ)"
