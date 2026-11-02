#!/usr/bin/env bash
# Runs nginx in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# One worker per core; each worker has a thread pool, and each thread one Postgres connection (95 at most in all).
set -euo pipefail
cd "$(dirname "$0")"
: "${DATABASE_URL:?}" "${JWT_SECRET:?}" "${HOST:=0.0.0.0}" "${PORT:=80}"
WORKERS=$(nproc)
THREADS=$(( 95 / WORKERS )); [ "$THREADS" -gt 16 ] && THREADS=16
mkdir -p run
{
  [ "$(id -u)" = 0 ] && echo "user root;"     # started as root, nginx would drop its workers to "nobody"
  sed -e "s|__LISTEN__|$HOST:$PORT|" -e "s|__ROOT__|$PWD|g" -e "s|__WORKERS__|$WORKERS|" -e "s|__THREADS__|$THREADS|" nginx.conf
} > run/nginx.conf
exec build/nginx/sbin/nginx -p "$PWD/run/" -c "$PWD/run/nginx.conf" -e stderr
