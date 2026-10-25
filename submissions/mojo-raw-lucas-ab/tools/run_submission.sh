#!/usr/bin/env bash
# Runs any submission or example the way the benchmark box does, but inside an ubuntu:24.04 container with host
# networking, on a machine that isn't Ubuntu: the base packages box/setup-box.sh installs, install.sh as root,
# build.sh as user `challenge`, start.sh as `challenge` with DATABASE_URL, JWT_SECRET, HOST and PORT. Postgres is
# the host's (reached at 127.0.0.1 through the host network). FOR LOCAL COMPARISONS ONLY.
#
#   bash tools/run_submission.sh up   <submission folder> <port> <database> [jwt secret]
#   bash tools/run_submission.sh down <submission folder>
#   bash tools/run_submission.sh logs <submission folder>
#
# `up` installs and builds once per container (logs in /tmp/sub-<name>.*.log on the host) and (re)starts the
# server, then waits up to 60 s for GET /api/tags, as the box does.
set -euo pipefail
ACTION=$1
SRC="$(cd "$2" && pwd)"
NAME="sub-$(basename "$SRC" | tr 'A-Z' 'a-z')"
case "$ACTION" in
  down) docker rm -f "$NAME" >/dev/null 2>&1 || true; echo "removed $NAME"; exit 0 ;;
  logs) docker exec "$NAME" tail -40 /tmp/server.log; exit 0 ;;
  up) ;;
  *) echo "usage: $0 up|down|logs <folder> [port database [secret]]"; exit 2 ;;
esac
PORT=$3
DB=$4
SECRET="${5:-dev-secret}"
LOG=/tmp/$NAME

if ! docker inspect "$NAME" >/dev/null 2>&1; then
  echo "== $NAME: new ubuntu:24.04 container"
  # seccomp=unconfined: the box runs servers without seccomp. Docker's default profile blocks io_uring (so
  # io_uring servers can't start) and filters every syscall (a cost syscall-heavy servers would pay unevenly).
  # CPUSET (e.g. 0-7) pins the container, so nproc inside matches the box and submissions size their pools as there.
  docker run -d --name "$NAME" --network host --ulimit nofile=200000:200000 --security-opt seccomp=unconfined \
    ${CPUSET:+--cpuset-cpus "$CPUSET"} ubuntu:24.04 sleep infinity >/dev/null
  # What box/setup-box.sh installs before any submission, and the box's user
  docker exec -e DEBIAN_FRONTEND=noninteractive "$NAME" bash -c \
    'apt-get update -q && apt-get install -y -q build-essential pkg-config git curl jq sysstat rsync unzip ca-certificates gnupg lsb-release' \
    > "$LOG.base.log" 2>&1
  docker exec "$NAME" useradd --create-home --shell /bin/bash challenge
  docker exec "$NAME" mkdir -p /opt/challenge
  docker cp "$SRC" "$NAME":/opt/challenge/current
  docker exec "$NAME" chown -R challenge:challenge /opt/challenge/current
  echo "== $NAME: install.sh (root)"
  if ! docker exec -w /opt/challenge/current -e DEBIAN_FRONTEND=noninteractive "$NAME" bash install.sh \
      > "$LOG.install.log" 2>&1; then
    tail -20 "$LOG.install.log"; echo "install.sh failed"; exit 1
  fi
  echo "== $NAME: build.sh (challenge)"
  if ! docker exec -u challenge -w /opt/challenge/current -e HOME=/home/challenge "$NAME" bash build.sh \
      > "$LOG.build.log" 2>&1; then
    tail -20 "$LOG.build.log"; echo "build.sh failed"; exit 1
  fi
  tail -1 "$LOG.build.log"
fi

# (Re)start the server
docker exec "$NAME" bash -c 'pkill -u challenge || true; sleep 1'
docker exec -d -u challenge -w /opt/challenge/current -e HOME=/home/challenge \
  -e DATABASE_URL="postgres://conduit:conduit@127.0.0.1:5432/$DB" -e JWT_SECRET="$SECRET" \
  -e HOST=127.0.0.1 -e PORT="$PORT" "$NAME" bash -c 'exec bash start.sh > /tmp/server.log 2>&1'
for _ in $(seq 60); do
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && { echo "== $NAME: up on :$PORT ($DB)"; exit 0; }
  sleep 1
done
echo "GET /api/tags not 200 after 60 s"; docker exec "$NAME" tail -20 /tmp/server.log; exit 1
