#!/usr/bin/env bash
# Simulated benchmark box Postgres: PG 18 in docker, pinned to the "box" CPUs, box pgtune values (16 GB / 8 cores).
#   box-pg.sh start | stop | rm | psql [args]
# Listens on 127.0.0.1:${PGPORT:-55432} only (host network, trust auth on loopback). Data in docker volume mcsc-pg.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOX_CPUS="${BOX_CPUS:-0-7}"
PORT="${PGPORT:-55432}"
NAME=mcsc-pg
case "${1:-}" in
start)
  args=()
  while IFS= read -r line; do
    line="${line%%#*}"; [ -z "${line// }" ] && continue
    k="$(echo "${line%%=*}" | xargs)"; v="$(echo "${line#*=}" | xargs)"
    args+=(-c "$k=$v")
  done < "$HERE/pg-box.conf"
  docker run -d --name "$NAME" --network host --cpuset-cpus "$BOX_CPUS" --memory 10g --shm-size 1g \
    --ulimit nofile=200000:200000 \
    -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_INITDB_ARGS="--auth-host=trust" \
    -v mcsc-pg:/var/lib/postgresql \
    postgres:18 -p "$PORT" -c listen_addresses=127.0.0.1 "${args[@]}"
  for _ in $(seq 60); do docker exec "$NAME" pg_isready -q -h 127.0.0.1 -p "$PORT" && break; sleep 1; done
  docker exec "$NAME" pg_isready -h 127.0.0.1 -p "$PORT"
  ;;
stop) docker stop "$NAME" && docker rm "$NAME" ;;
rm) docker rm -f "$NAME" 2>/dev/null || true; docker volume rm mcsc-pg ;;
psql) shift; PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres psql "$@" ;;
*) echo "usage: $0 start|stop|rm|psql"; exit 2 ;;
esac
