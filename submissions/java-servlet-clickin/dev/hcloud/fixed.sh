#!/usr/bin/env bash
# Fixed-load A/B on the Hetzner rig: for each variant, fresh DB + restart, a short warm-up, then a measured run at a
# fixed user count; prints throughput, latency and the target's CPU split (app / Postgres, from systemd cgroups).
#   bash fixed.sh USERS LABEL JAR [KEY=VALUE ...]      (JAR: a server.jar built from the variant)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/hosts.env"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
U=$1; LABEL=$2; JAR=$3; shift 3
RAMP=${RAMP:-60}; MEASURE=${MEASURE:-120}; WARM=${WARM:-60}; WARM_USERS=${WARM_USERS:-20000}
LG=($LGS); N=${#LG[@]}
for h in "${LG[@]}"; do $SSH root@$h test -x /root/loadgen || scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$HERE/loadgen" root@$h:/root/loadgen; done
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$JAR" root@$TARGET:/opt/challenge/current/build/server.jar
$SSH root@$TARGET "chown challenge:challenge /opt/challenge/current/build/server.jar
printf 'DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit\nJWT_SECRET=multicore-server-challenge\nHOST=0.0.0.0\nPORT=80\n' > /etc/challenge/env
for kv in $*; do echo \$kv >> /etc/challenge/env; done
/opt/conduit-tools/switch.sh >/dev/null"
run() { # users ramp measure tag
  local start=$(( ($(date +%s) + 5) * 1000 )) i=0 off=0 pids=() w=(${LG_WEIGHTS:-}) sum=0 per
  # LG_WEIGHTS="2 2 1": users split by weight, for load boxes of unequal size (default: even)
  [ ${#w[@]} -eq $N ] || { w=(); for _ in "${LG[@]}"; do w+=(1); done; }
  for x in "${w[@]}"; do sum=$((sum + x)); done
  for h in "${LG[@]}"; do
    per=$(( $1 * ${w[$i]} / sum ))
    $SSH root@$h "ulimit -n 1048576; CONDUIT_JWT_SECRET=multicore-server-challenge /root/loadgen run -target http://$TARGET_PRIV -users $per -ramp ${2}s -measure ${3}s -tail 10s -box-index $i -id-offset $off -run-id $4$RANDOM -start-at $start -q -out /root/$4.json >/root/$4.log 2>&1" & pids+=($!)
    i=$((i+1)); off=$((off + per)); done
  echo $start
  wait "${pids[@]}"
}
$SSH root@$TARGET "test -f /root/monitor.pid && kill \$(cat /root/monitor.pid) 2>/dev/null; nohup /opt/conduit-tools/monitor.sh 1 $LABEL >/dev/null 2>&1 & echo \$! > /root/monitor.pid"
run $WARM_USERS 20 $WARM warm >/dev/null
s=$(run $U $RAMP $MEASURE m)
from=$(( s / 1000 + RAMP )); to=$(( from + MEASURE ))
cpu=$($SSH root@$TARGET "kill \$(cat /root/monitor.pid) 2>/dev/null; awk -F, -v f=$from -v t=$to 'NR>1 && \$1>=f && \$1<t {n++; c+=\$2; a+=\$4; d+=\$5} END{printf \"box %.1f%% app %.1f%% db %.1f%%\", c/n, a/n, d/n}' /root/results/monitor-$LABEL.csv")
# merge the boxes' results on the first load box
for h in "${LG[@]:1}"; do $SSH root@$h "cat /root/m.json" | $SSH root@${LG[0]} "cat > /root/m-$h.json"; done
sum=$($SSH root@${LG[0]} "/root/loadgen merge -o '' /root/m.json \$(ls /root/m-*.json 2>/dev/null | tr '\n' ' ')" || true)
line="$LABEL users=$U $cpu | $(echo "$sum" | awk '/^ALL /{printf "req/s=%s p50=%s p95=%s p99=%s err%%=%s", $3, $4, $6, $7, $9} /^box /{sub(/,.*CPU avg/, " cpu"); printf " | %s", $0}')"
echo "$line"
# keep the CPU split and the per-second samples: stdout alone lost them once
mkdir -p "$HERE/results"; { echo "$line"; echo "$sum"; } > "$HERE/results/$LABEL.txt"; echo "$line" >> "$HERE/results/fixed.log"
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$TARGET:/root/results/monitor-$LABEL.csv "$HERE/results/" || true
