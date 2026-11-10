#!/usr/bin/env bash
# Paired experiments on one aged database, the state the official holds run in. `age` loads a fresh seed through
# probes and saves the result; every `hold` restores that copy, so runs are comparable. Survives an expired AWS session:
# addresses are resolved once, by `prep`.
#
#   dev/aws/exp.sh prep                       # start the boxes if needed, record addresses, sync, build
#   dev/aws/exp.sh sync                       # sync and build only
#   dev/aws/exp.sh age                        # make the aged database (about 12 minutes)
#   dev/aws/exp.sh hold <label> <users> [K=V ...]   # restore, restart with these settings, 5-minute hold
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUB="$(cd "$HERE/../.." && pwd)"; ROOT="$(cd "$SUB/../.." && pwd)"; NAME="$(basename "$SUB")"
STATE="$SUB/dev/results/aws/exp.state"; SECRET=multicore-server-challenge
SSH_OPTS=(-i "$HOME/.ssh/id_ed_personal" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o StrictHostKeyChecking=accept-new)
on_target() { ssh "${SSH_OPTS[@]}" "ubuntu@$TARGET" "$@"; }
on_loadgen() { ssh "${SSH_OPTS[@]}" "ubuntu@$LOADGEN" "$@"; }
sync_build() {
  rsync -az --delete -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" --exclude _build --exclude _opam-root --exclude dev/results --exclude .built "$SUB/" "ubuntu@$TARGET:/opt/challenge/subs/$NAME/"
  on_target "set -o pipefail; sudo install -m 755 /opt/challenge/subs/$NAME/dev/aws/telemetry.sh /opt/conduit-tools/telemetry.sh; sudo /opt/conduit-tools/prepare.sh $NAME | tail -1"
}
settings() { # K=V ...
  local body="[Service]\n" kv
  for kv in "$@"; do body="$body""Environment=$kv\n"; done
  on_target "sudo mkdir -p /etc/systemd/system/challenge.service.d; sudo rm -f /etc/systemd/system/challenge.service.d/*.conf; printf '$body' | sudo tee /etc/systemd/system/challenge.service.d/exp.conf >/dev/null; sudo systemctl daemon-reload"
}
load() { # users measure-seconds out-dir
  on_loadgen "sudo mkdir -p $3; sudo env CONDUIT_JWT_SECRET=$SECRET sh -c 'ulimit -n 1048576; conduit-loadgen run -target $URLS -users $1 -box-index 0 -id-offset 0 -ramp 60s -measure ${2}s -tail 15s -secret $SECRET -run-id exp\$(date +%s) -q -out $3/box0.json > $3/run.log 2>&1; conduit-loadgen merge -o $3/merged.json $3/box0.json > $3/merge.txt 2>&1 || true'"
}
case "${1:-}" in
  prep)
    [ -n "${AWS_CONFIG_FILE:-}" ] || { export DIRENV_LOG_FORMAT=""; exec direnv exec "$ROOT" bash "$0" "$@"; }
    bash "$HERE/aws.sh" up
    ip() { aws ec2 describe-instances --filters "Name=tag:Name,Values=$1" Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }
    printf 'TARGET=%s\nLOADGEN=%s\nURLS=%s\n' "$(ip multicore-target)" "$(ip multicore-loadgen)" "$(bash "$HERE/aws.sh" urls)" > "$STATE"
    . "$STATE"; sync_build ;;
  sync) . "$STATE"; sync_build ;;
  age)
    . "$STATE"; settings
    on_target "set -o pipefail; sudo /opt/conduit-tools/switch.sh $NAME --no-conformance | tail -1 | cut -c1-100"
    for u in 128000 180000 160000 150000; do load "$u" 60 "/root/exp/age-$u"; sleep 15; done
    on_target "sudo systemctl stop challenge; sudo -u postgres psql -qX -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS conduit_aged' -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'conduit'\" >/dev/null; sudo -u postgres psql -qX -v ON_ERROR_STOP=1 -c 'CREATE DATABASE conduit_aged TEMPLATE conduit STRATEGY FILE_COPY'; sudo -u postgres psql -qtAX -c \"SELECT pg_size_pretty(pg_database_size('conduit_aged'))\""
    echo aged ;;
  hold)
    . "$STATE"; LABEL="${2:?}"; USERS="${3:?}"; shift 3; settings "$@"
    on_target "set -e; sudo systemctl stop challenge
      sudo -u postgres psql -qX -v ON_ERROR_STOP=1 -c 'DROP DATABASE IF EXISTS conduit WITH (FORCE)' -c 'CREATE DATABASE conduit TEMPLATE conduit_aged STRATEGY FILE_COPY'
      sudo systemctl restart postgresql@18-main; for _ in \$(seq 30); do sudo -u postgres pg_isready -q && break; sleep 1; done
      sudo sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
      sudo systemctl start challenge; for _ in \$(seq 120); do curl -sf -m 2 -o /dev/null http://127.0.0.1/api/tags && break; sleep 0.5; done
      curl -sf -m 2 -o /dev/null http://127.0.0.1/api/tags
      sudo pkill -f '^bash /opt/conduit-tools/telemetry' || true; sudo setsid nohup /opt/conduit-tools/telemetry.sh /root/telemetry/$LABEL >/dev/null 2>&1 </dev/null & disown; sleep 3"
    load "$USERS" 300 "/root/exp/$LABEL"
    on_target "sudo pkill -f '^bash /opt/conduit-tools/telemetry' || true; systemctl is-active challenge >/dev/null || echo SERVER-DOWN"
    DEST="$SUB/dev/results/aws/exp-$LABEL"; mkdir -p "$DEST"
    rsync -az -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" "ubuntu@$LOADGEN:/root/exp/$LABEL/merged.json" "$DEST/"
    rsync -az -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" "ubuntu@$TARGET:/root/telemetry/$LABEL/" "$DEST/telemetry/"
    python3 -I - "$DEST" "$LABEL" "$USERS" "$*" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]+'/merged.json'));o=d['overall'];v=d['verdict']
r=[]
for l in open(sys.argv[1]+'/telemetry/mpstat.txt',errors='replace'):
    p=l.split()
    if len(p)==12 and p[1]=='all':
        try: r.append(float(p[-1]))
        except ValueError: pass
r=r[90:360]; idle=sum(r)/len(r) if r else -1
print(f"{sys.argv[2]:28s} {sys.argv[3]:>7s} rps {o['rps']:8.1f} p50 {o['p50_ms']:6.1f} p95 {o['p95_ms']:7.1f} p99 {o['p99_ms']:7.1f} err {o['errors']:6d} idle {idle:4.1f} {'PASS' if v['pass'] else 'FAIL'} lg={v['lg_limited']} [{sys.argv[4]}]")
PY
    ;;
  *) sed -n 2,9p "$0"; exit 2 ;;
esac
