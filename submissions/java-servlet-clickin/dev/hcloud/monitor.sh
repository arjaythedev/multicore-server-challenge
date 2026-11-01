#!/usr/bin/env bash
# /opt/conduit-tools/monitor.sh <interval s> <tag>: CSV of box CPU and the app / Postgres split from systemd cgroups.
set -u
I=${1:-1}; TAG=${2:-run}; OUT=/root/results/monitor-$TAG.csv; mkdir -p /root/results
echo "time,cpu%,steal%,app%,db%,nginx%,mem_used_mb,pg_conns" > "$OUT"
cg() { echo "/sys/fs/cgroup$(systemctl show -p ControlGroup --value "$1")/cpu.stat"; }
APP=$(cg challenge.service); DB=$(cg postgresql@18-main.service); n=$(nproc)
use() { awk '/^usage_usec/{print $2}' "$1" 2>/dev/null || echo 0; }
snap() { read -r _ u ni s id io irq sirq st _ < /proc/stat; T=$((u+ni+s+id+io+irq+sirq+st)); B=$((T-id-io)); ST=$st; A=$(use "$APP"); D=$(use "$DB"); NS=$(date +%s%N); }
snap; pT=$T; pB=$B; pS=$ST; pA=$A; pD=$D; pN=$NS
while sleep "$I"; do snap; dT=$((T-pT)); dN=$(( (NS-pN)/1000 )); [ $dT -gt 0 ] && [ $dN -gt 0 ] || continue
  awk -v t="$(date +%s)" -v b=$((B-pB)) -v s=$((ST-pS)) -v a=$((A-pA)) -v d=$((D-pD)) -v dT=$dT -v dN=$dN -v n=$n \
    -v m="$(free -m | awk '/Mem:/{print $3}')" -v c="$(runuser -u postgres -- psql -tAXc 'select count(*) from pg_stat_activity' 2>/dev/null || echo 0)" \
    'BEGIN{printf "%s,%.1f,%.1f,%.1f,%.1f,0,%s,%s\n", t, b*100/dT, s*100/dT, a*100/(dN*n), d*100/(dN*n), m, c}' >> "$OUT"
  pT=$T; pB=$B; pS=$ST; pA=$A; pD=$D; pN=$NS; done
