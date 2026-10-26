#!/usr/bin/env bash
# 1 s sampler for the simulated box, same column ideas as score/monitor.sh.
#   monitor.sh [interval] out.csv     (runs until killed; loadgen search calls it as "<cmd> 1 <tag>.csv")
# cpu = busy % of the box CPUs (BOX_CPUS, default 0-7); lg_cpu = busy % of the other CPUs (load generator side)
# app_box / pg_box = cgroup CPU in % of the whole 8-vCPU box; app_rss / pg_mem in MB
set -u
OUT="${!#}"
BOX_CPUS="${BOX_CPUS:-0-7}"; B0="${BOX_CPUS%-*}"; B1="${BOX_CPUS#*-}"; NB=$((B1 - B0 + 1))
APP_CG="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/mcsc-app.scope"
PG_CG="/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' mcsc-pg).scope"
usec() { awk '$1=="usage_usec"{print $2}' "$1/cpu.stat" 2>/dev/null || echo 0; }
cpus() { awk -v a="$B0" -v b="$B1" '/^cpu[0-9]/{n=substr($1,4)+0; busy=$2+$3+$4+$7+$8; tot=busy+$5+$6; if(n>=a&&n<=b){bb+=busy;bt+=tot}else{lb+=busy;lt+=tot}} END{print bb,bt,lb,lt}' /proc/stat; }
PGQ="select count(*) filter (where state='active') || ' ' || count(*) from pg_stat_activity where backend_type='client backend'"
echo "ts,time,cpu,lg_cpu,app_box,pg_box,app_rss,pg_mem,mem_avail,pg_active,pg_total" > "$OUT"
read -r bb0 bt0 lb0 lt0 <<<"$(cpus)"; a0=$(usec "$APP_CG"); p0=$(usec "$PG_CG"); t0=${EPOCHREALTIME/./}
while sleep 1; do
  read -r bb1 bt1 lb1 lt1 <<<"$(cpus)"; a1=$(usec "$APP_CG"); p1=$(usec "$PG_CG"); t1=${EPOCHREALTIME/./}
  dt=$((t1 - t0)); [ "$dt" -le 0 ] && dt=1
  pgc=$(docker exec mcsc-pg psql -h 127.0.0.1 -p 55432 -U postgres -qtAX -c "$PGQ" 2>/dev/null | tr ' ' ,); pgc="${pgc:-,}"
  awk -v ts="$(date +%s.%3N)" -v tm="$(date +%T)" -v bb=$((bb1-bb0)) -v bt=$((bt1-bt0)) -v lb=$((lb1-lb0)) -v lt=$((lt1-lt0)) \
      -v a=$((${a1:-0}-${a0:-0})) -v p=$((p1-p0)) -v dt="$dt" -v nb="$NB" \
      -v ar="$(awk '/^anon /{print int($2/1048576)}' "$APP_CG/memory.stat" 2>/dev/null)" \
      -v pm="$(awk '{print int($1/1048576)}' "$PG_CG/memory.current" 2>/dev/null)" \
      -v ma="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)" -v pg="$pgc" \
      'BEGIN{printf "%s,%s,%.1f,%.1f,%.1f,%.1f,%s,%s,%s,%s\n", ts,tm, bt?100*bb/bt:0, lt?100*lb/lt:0, 100*a/dt/nb, 100*p/dt/nb, ar,pm,ma,pg}' >> "$OUT"
  bb0=$bb1; bt0=$bt1; lb0=$lb1; lt0=$lt1; a0=$a1; p0=$p1; t0=$t1
done
