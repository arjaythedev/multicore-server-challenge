#!/usr/bin/env bash
# Runs OpenResty in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# One nginx worker per core; each worker keeps its own Postgres pool of DB_POOL_SIZE connections.
# Every path nginx writes to (pid, temp dirs, rendered config) lives in run/, so it works as a non-root user.
set -euo pipefail
cd "$(dirname "$0")"
: "${DATABASE_URL:?}" "${JWT_SECRET:?}" "${HOST:=0.0.0.0}" "${PORT:=80}"
WORKERS=$(nproc)
# 8 connections per worker (64 on 8 cores), never more than 95 in total. Every Postgres backend competes for the
# CPU with the nginx workers that carry all the users: on 4 vCPUs the workers waited for a CPU 44% of the time
# with 92 connections. In a pool comparison at the limit, 8 per worker beat 23 (and 4, which starved throughput).
POOL=$(( 95 / WORKERS )); [ "$POOL" -gt 8 ] && POOL=8
export DB_POOL_SIZE=${DB_POOL_SIZE:-$POOL}
mkdir -p run
{
  # started as root, nginx would drop its workers to "nobody"
  [ "$(id -u)" = 0 ] && echo "user root;"
  sed -e "s|__LISTEN__|$HOST:$PORT|" -e "s|__ROOT__|$PWD|g" -e "s|__WORKERS__|$WORKERS|" nginx.conf
} > run/nginx.conf
exec /usr/local/openresty/bin/openresty -p "$PWD/run/" -c "$PWD/run/nginx.conf" -e stderr
