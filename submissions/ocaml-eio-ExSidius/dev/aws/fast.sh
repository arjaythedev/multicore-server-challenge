#!/usr/bin/env bash
# Quick experiments under running load: Postgres, the OS cache and the load generator stay up while the app is
# swapped. Results only rank options against each other; aws.sh hold is the only real pass.
#
#   dev/aws/fast.sh start [users]        # start the boxes if needed, a clean cold start, then load
#   dev/aws/fast.sh set [K=V ...]        # replace the app's env overrides and restart the app (load keeps running)
#   dev/aws/fast.sh swap [dir]           # sync source from a checkout of this submission, build, restart the app
#   dev/aws/fast.sh read [settle] [secs] # wait, then measure a window: latency, CPU, per-lane statement time, DB size
#   dev/aws/fast.sh ab "K=V ..." [settle] [secs]  # A/B/A: current settings, these settings, current settings again
#   dev/aws/fast.sh trend [secs]         # p50/p95/p99 and req/s in steps, to watch latency climb
#   dev/aws/fast.sh reset [users]        # restore the seed without restarting Postgres, restart load (no reseed)
#   dev/aws/fast.sh load [users]         # restart only the load generator, keeping the database as it is
#   dev/aws/fast.sh stop                 # stop the load, keep everything warm
#   dev/aws/fast.sh down                 # stop the load and both boxes
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUB="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$SUB/../.." && pwd)"
NAME="$(basename "$SUB")"
if [ -z "${AWS_CONFIG_FILE:-}" ]; then export DIRENV_LOG_FORMAT=""; exec direnv exec "$ROOT" bash "$0" "$@"; fi
export AWS_PAGER=""
STATE="$SUB/dev/results/aws/fast.state"
SSH_OPTS=(-i "$HOME/.ssh/id_ed_personal" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o StrictHostKeyChecking=accept-new)
SECRET=multicore-server-challenge
SETTLE=40; WINDOW=20; RAMP=10

on_target() { ssh "${SSH_OPTS[@]}" "ubuntu@$TARGET" "$@"; }
on_loadgen() { ssh "${SSH_OPTS[@]}" "ubuntu@$LOADGEN" "$@"; }
load_state() { [ -f "$STATE" ] || { echo "not started: dev/aws/fast.sh start"; exit 1; }; . "$STATE"; }
ip_of() { aws ec2 describe-instances --filters "Name=tag:Name,Values=$1" Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }

stop_load() { on_loadgen 'sudo pkill -x loadgen-live || true; for _ in $(seq 20); do pgrep -x loadgen-live >/dev/null || break; sleep 0.5; done'; }
start_load() { # users
  on_loadgen "sudo mkdir -p /root/live; sudo rm -f /root/live/stream.jsonl; sudo env CONDUIT_JWT_SECRET=$SECRET CONDUIT_LIVE_FILE=/root/live/stream.jsonl sh -c 'ulimit -n 1048576; setsid nohup /usr/local/bin/loadgen-live run -target $URLS -users $1 -box-index 0 -id-offset 0 -ramp ${RAMP}s -measure 6h -tail 5s -secret $SECRET -run-id live\$(date +%s) -q -out /root/live/box.json > /root/live/run.log 2>&1 </dev/null &'"
}
restart_app() {
  on_target "sudo systemctl restart challenge; for _ in \$(seq 120); do curl -sf -m 2 -o /dev/null http://127.0.0.1/api/tags && exit 0; sleep 0.25; done; echo 'app not ready'; sudo journalctl -u challenge -n 20 --no-pager; exit 1"
}
write_env() { # K=V ...
  local body="[Service]\nEnvironment=CONDUIT_STATS=1\n" kv
  for kv in "$@"; do body="$body""Environment=$kv\n"; done
  on_target "sudo mkdir -p /etc/systemd/system/challenge.service.d; sudo rm -f /etc/systemd/system/challenge.service.d/stats.conf; printf '$body' | sudo tee /etc/systemd/system/challenge.service.d/exp.conf >/dev/null; sudo systemctl daemon-reload"
  printf '%s\n' "$*" > "$STATE.env"
}
measure() { # label settle secs
  local from to tmp
  sleep "$2"
  tmp=$(mktemp -d)
  from=$(on_loadgen 'date +%s%3N')
  # Batch lines are printed at most once a second per fiber; the statement time is the mean over the window.
  on_target "mpstat $3 1 | tail -1" > "$tmp/cpu"
  to=$(on_loadgen 'date +%s%3N')
  on_target "sudo journalctl -u challenge --since '-$3s' -o cat --no-pager | grep '^batch ' || true" > "$tmp/lanes"
  on_target "sudo -u postgres psql -qtAX -d conduit -c \"SELECT pg_database_size('conduit')/1048576, (SELECT sum(n_dead_tup) FROM pg_stat_user_tables), (SELECT count(*) FROM articles)\"" > "$tmp/db"
  printf '%-10s %s\n' "$1" "$(on_loadgen "sudo /usr/local/bin/loadgen-live live-read /root/live/stream.jsonl $from $to")"
  python3 - "$tmp" "$3" <<'PY'
import sys,re,collections
d,secs=sys.argv[1],float(sys.argv[2])
c=open(d+'/cpu').read().split()
if len(c)>=11:
    v=[float(x) for x in c[2:12]]
    print(f"           cpu busy={v[0]+v[1]+v[2]+v[4]+v[5]:.1f} usr={v[0]:.1f} nice={v[1]:.1f} sys={v[2]:.1f} soft={v[5]:.1f} iowait={v[3]:.1f} idle={v[9]:.1f}")
L=collections.defaultdict(lambda:[0,0,0.0])
for l in open(d+'/lanes'):
    m=re.match(r'batch lane=(\S+) runs=(\d+) jobs=(\d+) avg=\S+ ms=([\d.]+)',l)
    if m:
        a=L[m[1]];r=int(m[2]);a[0]+=r;a[1]+=int(m[3]);a[2]+=r*float(m[4])
t=sorted(L.items(),key=lambda kv:-kv[1][2])
print('           lanes '+'  '.join(f"{k}:{v[2]/v[0]:.0f}ms/{v[1]/v[0]:.0f}" for k,v in t[:7]))
db=open(d+'/db').read().strip().split('|')
if len(db)==3: print(f"           db {db[0]} MB, {db[1]} dead rows, {db[2]} articles")
PY
  rm -rf "$tmp"
}

case "${1:-}" in
  start)
    USERS="${2:-100000}"
    bash "$HERE/aws.sh" up
    TARGET=$(ip_of multicore-target); LOADGEN=$(ip_of multicore-loadgen); URLS=$(bash "$HERE/aws.sh" urls)
    printf 'TARGET=%s\nLOADGEN=%s\nURLS=%s\nUSERS=%s\n' "$TARGET" "$LOADGEN" "$URLS" "$USERS" > "$STATE"
    if ! on_loadgen 'test -x /usr/local/bin/loadgen-live' || [ "$HERE/live/live.go" -nt "$STATE.lg" ]; then
      t=$(mktemp -d); "$SUB/dev/tools.sh" bash "$HERE/live/build.sh" "$t/loadgen-live"
      scp -q "${SSH_OPTS[@]}" "$t/loadgen-live" "ubuntu@$LOADGEN:/tmp/loadgen-live"; rm -rf "$t"
      on_loadgen 'sudo install -m 755 /tmp/loadgen-live /usr/local/bin/loadgen-live'; touch "$STATE.lg"
    fi
    stop_load
    write_env ${FAST_ENV:-WORKERS=6 BATCH_WINDOW_MS=100}
    rsync -az --delete -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" --exclude _build --exclude _opam-root --exclude dev/results --exclude .built "$SUB/" "ubuntu@$TARGET:/opt/challenge/subs/$NAME/"
    on_target "sudo /opt/conduit-tools/prepare.sh $NAME | tail -1; sudo /opt/conduit-tools/switch.sh $NAME --no-conformance | tail -1 | cut -c1-100"
    start_load "$USERS"
    echo "load started: $USERS users" ;;
  set)
    load_state; shift; t=$SECONDS; write_env "$@"; restart_app; echo "app restarted in $((SECONDS - t)) s with: $*" ;;
  swap)
    load_state; DIR="${2:-$SUB}"; t=$SECONDS
    rsync -az --delete -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo rsync" --exclude _build --exclude _opam-root --exclude dev/results --exclude .built "$DIR/" "ubuntu@$TARGET:/opt/challenge/subs/$NAME/"
    on_target "set -o pipefail; cd /opt/challenge/subs/$NAME && sudo find . -maxdepth 1 ! -name . ! -name _opam-root ! -name _build -exec chown -R challenge:challenge {} + && sudo chmod +x ./*.sh && sudo -u challenge env -i HOME=/home/challenge PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin OPAMROOT=\$PWD/_opam-root opam exec --switch=conduit -- dune build --release src/main.exe 2>&1 | tail -20"
    b=$((SECONDS - t)); restart_app; echo "synced and built in $b s, running after $((SECONDS - t)) s" ;;
  read)
    load_state; measure now "${2:-$SETTLE}" "${3:-$WINDOW}" ;;
  ab)
    load_state; A=$(cat "$STATE.env"); B="${2:?usage: fast.sh ab \"K=V ...\" [settle] [secs]}"; S="${3:-$SETTLE}"; W="${4:-$WINDOW}"
    echo "A: $A"; echo "B: $A $B"
    write_env $A; restart_app; measure A1 "$S" "$W"
    write_env $A $B; restart_app; measure B "$S" "$W"
    write_env $A; restart_app; measure A2 "$S" "$W" ;;
  trend)
    load_state; end=$((SECONDS + ${2:-120})); while [ $SECONDS -lt $end ]; do measure "t+$SECONDS" 0 15 | head -1; done ;;
  reset)
    load_state; USERS="${2:-$USERS}"; t=$SECONDS; stop_load
    on_target "sudo systemctl stop challenge; sudo -u postgres psql -qX -v ON_ERROR_STOP=1 -c \"DROP DATABASE IF EXISTS conduit WITH (FORCE)\" -c \"CREATE DATABASE conduit TEMPLATE conduit_seed STRATEGY FILE_COPY\""
    restart_app; sed -i "s/^USERS=.*/USERS=$USERS/" "$STATE"; start_load "$USERS"; echo "database restored and load restarted in $((SECONDS - t)) s: $USERS users" ;;
  load) load_state; USERS="${2:-$USERS}"; stop_load; sed -i "s/^USERS=.*/USERS=$USERS/" "$STATE"; start_load "$USERS"; echo "load restarted, database kept: $USERS users" ;;
  stop) load_state; stop_load; echo "load stopped" ;;
  down) load_state; stop_load; bash "$HERE/aws.sh" down; rm -f "$STATE" ;;
  *) sed -n 2,15p "$0"; exit 2 ;;
esac
