#!/usr/bin/env bash
# Edit locally, sync, then build, test and benchmark on the AWS boxes through the repo's own scoring pipeline
# (score/prepare.sh, score/switch.sh, score/chain.sh). Instances are found by their Name tags.
#
#   dev/aws/aws.sh status              # instances, and what's running
#   dev/aws/aws.sh up | down           # start or stop both instances (stopped instances don't bill for CPU)
#   dev/aws/aws.sh test                # sync, build, conformance on the full seed
#   dev/aws/provision.sh               # create both instances from nothing, if they're gone
#   dev/aws/aws.sh search <label> [start-users]   # sync, then a full search with telemetry, detached on the load box (STATS=1 adds the app's counters)
#   dev/aws/aws.sh fetch <label>       # copy that run's results and telemetry to dev/results/aws/<label>
#   dev/aws/aws.sh pgprofile <label> [users]      # fixed load with pg_stat_statements and perf; prints the profile
#   dev/aws/aws.sh hold <label> <users>           # conformance, fresh database, then a 5-minute hold with no profilers
#   dev/aws/fast.sh                               # quick experiments under running load, see there
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUB="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$SUB/../.." && pwd)"
NAME="$(basename "$SUB")"
# The AWS credentials come from the direnv profile of this folder.
if [ -z "${AWS_CONFIG_FILE:-}" ]; then export DIRENV_LOG_FORMAT=""; exec direnv exec "$ROOT" bash "$0" "$@"; fi
export AWS_PAGER=""
KEY="$HOME/.ssh/id_ed_personal"
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o StrictHostKeyChecking=accept-new)

instance() { # name query
  aws ec2 describe-instances --filters "Name=tag:Name,Values=$1" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query "Reservations[0].Instances[0].$2" --output text
}
target_ip() { instance multicore-target PublicIpAddress; }
loadgen_ip() { instance multicore-loadgen PublicIpAddress; }
on_target() { ssh "${SSH_OPTS[@]}" "ubuntu@$TARGET" "$@"; }
on_loadgen() { ssh "${SSH_OPTS[@]}" "ubuntu@$LOADGEN" "$@"; }
resolve() {
  TARGET=$(target_ip); LOADGEN=$(loadgen_ip)
  [ "$TARGET" != None ] && [ "$LOADGEN" != None ] || { echo "instances aren't running: dev/aws/aws.sh up"; exit 1; }
}
searching() { on_loadgen 'pgrep -f "^/usr/local/bin/conduit-loadgen search|[c]hain.sh" >/dev/null'; }

# Four target addresses, as on the official box: each gives the load generator about 64k ports. They don't survive
# a stop, so `up` and every sync put them back.
target_urls() {
  local eni ips ip urls primary
  eni=$(instance multicore-target 'NetworkInterfaces[0].NetworkInterfaceId')
  primary=$(instance multicore-target PrivateIpAddress)
  ips=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" \
    --query 'NetworkInterfaces[0].PrivateIpAddresses[?Primary==`false`].PrivateIpAddress' --output text)
  urls="http://$primary"
  for ip in $ips; do
    urls="$urls,http://$ip"
    on_target "IF=\$(ip -o -4 route show to default | awk '{print \$5; exit}'); ip -o -4 addr show \$IF | grep -q ' $ip/' || sudo ip addr add $ip/20 dev \$IF" >&2
  done
  echo "$urls"
}

sync_and_build() {
  rsync -az --delete -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" \
    --exclude _build --exclude _opam-root --exclude dev/results --exclude .built \
    "$SUB/" "ubuntu@$TARGET:/opt/challenge/subs/$NAME/"
  on_target "set -o pipefail; sudo install -m 755 /opt/challenge/subs/$NAME/dev/aws/telemetry.sh /opt/conduit-tools/telemetry.sh; sudo /opt/conduit-tools/prepare.sh $NAME | tail -2"
}

case "${1:-}" in
  status)
    aws ec2 describe-instances --filters Name=tag:Project,Values=multicore-bench Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,State.Name,PublicIpAddress]' --output text
    TARGET=$(target_ip); LOADGEN=$(loadgen_ip)
    if [ "$LOADGEN" != None ] && [ "$TARGET" != None ]; then
      on_loadgen 'sudo tail -1 /root/results/chain.log 2>/dev/null | cut -c1-140; sudo grep -E " (warmup|probe-[0-9]+|hold-[0-9]+) +[0-9]+ users +[0-9]+ req" /root/results/'"$NAME"'/search.log 2>/dev/null | tail -14 | cut -c1-125; sudo tail -1 /root/results/'"$NAME"'/search.log 2>/dev/null | cut -c1-125'
      on_target 'uptime; echo "challenge $(systemctl is-active challenge) nginx $(systemctl is-active nginx) postgres $(systemctl is-active postgresql@18-main)"'
    fi ;;
  up)
    ids=$(aws ec2 describe-instances --filters Name=tag:Project,Values=multicore-bench Name=instance-state-name,Values=stopped --query 'Reservations[].Instances[].InstanceId' --output text)
    if [ -n "$ids" ]; then aws ec2 start-instances --instance-ids $ids --output text >/dev/null; aws ec2 wait instance-running --instance-ids $ids; fi
    resolve; for _ in $(seq 30); do on_target true 2>/dev/null && on_loadgen true 2>/dev/null && break; sleep 5; done
    target_urls >/dev/null; echo "up: target $TARGET, load generator $LOADGEN" ;;
  down)
    resolve; searching && { echo "a search is running: not stopping"; exit 1; }
    ids=$(aws ec2 describe-instances --filters Name=tag:Project,Values=multicore-bench Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text)
    aws ec2 stop-instances --instance-ids $ids --output text >/dev/null; echo "stopping $ids" ;;
  test)
    resolve; searching && { echo "a search is running: wait for it"; exit 1; }
    target_urls >/dev/null; sync_and_build
    on_target "set -o pipefail; sudo /opt/conduit-tools/switch.sh $NAME | tail -6 | cut -c1-140; sudo systemctl stop challenge" ;;
  search)
    LABEL="${2:?usage: aws.sh search <label> [start-users]}"; START="${3:-5000}"
    resolve; searching && { echo "a search is running: wait for it"; exit 1; }
    URLS=$(target_urls); sync_and_build
    on_target "sudo pkill -f '^bash /opt/conduit-tools/telemetry' || true
      sudo mkdir -p /etc/systemd/system/challenge.service.d
      sudo rm -f /etc/systemd/system/challenge.service.d/stats.conf
      if [ '${STATS:-0}' = 1 ]; then printf '[Service]\nEnvironment=CONDUIT_STATS=1\n' | sudo tee /etc/systemd/system/challenge.service.d/stats.conf >/dev/null; fi
      sudo systemctl daemon-reload
      sudo setsid nohup /opt/conduit-tools/telemetry.sh /root/telemetry/$LABEL >/dev/null 2>&1 </dev/null & disown"
    PRIVATE=$(instance multicore-target PrivateIpAddress)
    on_loadgen "sudo mkdir -p /root/archive
      sudo sh -c '[ -d /root/results/$NAME ] && mv /root/results/$NAME /root/archive/$NAME-\$(date +%s) ; rm -f /root/results/$NAME.out /root/results/$NAME.prepare.log; echo $NAME > /root/batch.txt; echo $LABEL > /root/current-label'
      sudo env TARGET=root@$PRIVATE URLS=$URLS START=$START MAX=250000 setsid nohup bash /root/chain.sh /root/batch.txt > /tmp/chain.out 2>&1 </dev/null & disown"
    echo "search $LABEL started from $START users" ;;
  pgprofile)
    LABEL="${2:?usage: aws.sh pgprofile <label> [users]}"; USERS="${3:-40000}"
    resolve; searching && { echo "a search is running: wait for it"; exit 1; }
    URLS=$(target_urls); sync_and_build
    TOOL="/opt/challenge/subs/$NAME/dev/aws/pgprofile-target.sh"
    on_target "sudo systemctl stop challenge; sudo bash $TOOL setup; sudo /opt/conduit-tools/switch.sh $NAME --no-conformance | tail -1 | cut -c1-100"
    on_loadgen "sudo mkdir -p /root/pgprofile/$LABEL; sudo env CONDUIT_JWT_SECRET=multicore-server-challenge sh -c 'ulimit -n 1048576; setsid nohup conduit-loadgen run -target $URLS -users $USERS -box-index 0 -id-offset 0 -ramp 60s -measure 150s -tail 15s -secret multicore-server-challenge -run-id prof\$(date +%s) -q -out /root/pgprofile/$LABEL/box0.json > /root/pgprofile/$LABEL/run.log 2>&1 </dev/null &'"
    on_target "sudo bash $TOOL capture /root/pgprofile/$LABEL 90"
    sleep 90
    on_loadgen "sudo conduit-loadgen merge -o /root/pgprofile/$LABEL/merged.json /root/pgprofile/$LABEL/box0.json | tail -6 | cut -c1-120 || true"
    on_target "sudo bash $TOOL teardown"
    DEST="$SUB/dev/results/aws/pgprofile-$LABEL"; mkdir -p "$DEST"
    rsync -az -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" "ubuntu@$TARGET:/root/pgprofile/$LABEL/" "$DEST/"
    rsync -az -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" "ubuntu@$LOADGEN:/root/pgprofile/$LABEL/merged.json" "$DEST/"
    echo "$DEST" ;;
  hold)
    LABEL="${2:?usage: aws.sh hold <label> <users>}"; USERS="${3:?usage: aws.sh hold <label> <users>}"
    resolve; searching && { echo "a search is running: wait for it"; exit 1; }
    URLS=$(target_urls); sync_and_build
    on_target "set -o pipefail; sudo /opt/conduit-tools/switch.sh $NAME | tail -1 | cut -c1-100"
    on_target "sudo pkill -f '^bash /opt/conduit-tools/telemetry' || true; sudo setsid nohup /opt/conduit-tools/telemetry.sh /root/telemetry/$LABEL >/dev/null 2>&1 </dev/null & disown"
    on_loadgen "sudo mkdir -p /root/holds/$LABEL; sudo env CONDUIT_JWT_SECRET=multicore-server-challenge sh -c 'ulimit -n 1048576; conduit-loadgen run -target $URLS -users $USERS -box-index 0 -id-offset 0 -ramp 60s -measure 300s -tail 15s -secret multicore-server-challenge -run-id hold\$(date +%s) -q -out /root/holds/$LABEL/box0.json > /root/holds/$LABEL/run.log 2>&1; conduit-loadgen merge -o /root/holds/$LABEL/merged.json /root/holds/$LABEL/box0.json' | tail -12 | cut -c1-130 || true"
    on_target "sudo pkill -f '^bash /opt/conduit-tools/telemetry' || true"
    DEST="$SUB/dev/results/aws/hold-$LABEL"; mkdir -p "$DEST"
    rsync -az -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" "ubuntu@$LOADGEN:/root/holds/$LABEL/merged.json" "$DEST/"
    rsync -az -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" "ubuntu@$TARGET:/root/telemetry/$LABEL/" "$DEST/telemetry/"
    echo "$DEST" ;;
  urls) resolve; target_urls ;;
  fetch)
    LABEL="${2:?usage: aws.sh fetch <label>}"; resolve
    DEST="$SUB/dev/results/aws/$LABEL"; mkdir -p "$DEST"
    rsync -az -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" "ubuntu@$LOADGEN:/root/results/$NAME/" "$DEST/search/"
    rsync -az -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" "ubuntu@$TARGET:/root/telemetry/$LABEL/" "$DEST/telemetry/"
    on_target "sudo journalctl -u challenge --since '-24h' -o cat --no-pager | grep '^stats ' || true" > "$DEST/telemetry/app_stats.txt"
    echo "$DEST" ;;
  *) sed -n 2,11p "$0"; exit 2 ;;
esac
