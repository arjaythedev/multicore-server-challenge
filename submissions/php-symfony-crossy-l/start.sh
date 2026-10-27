#!/usr/bin/env bash
# Runs the server in the foreground.
#
# Required: DATABASE_URL, JWT_SECRET.  Listens on HOST:PORT (default 127.0.0.1:3000).
#
# Optional tuning:
#   PHP_WORKERS       worker processes, each serving many requests at once         (default: one per CPU)
#   PG_CONNECTIONS    Postgres connections per worker, each running one statement  (default 1)
#   PHP_TASK_WORKERS  processes that hash passwords, one at a time each            (default: one per CPU)
#
# The server holds PHP_WORKERS x PG_CONNECTIONS connections to Postgres; this refuses to start above 90, which leaves
# room under the box's limit of 95.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

: "${DATABASE_URL:?DATABASE_URL is required}"
: "${JWT_SECRET:?JWT_SECRET is required}"

export HOST="${HOST:-127.0.0.1}"
export PORT="${PORT:-3000}"
export PHP_WORKERS="${PHP_WORKERS:-$(nproc)}"
export PG_CONNECTIONS="${PG_CONNECTIONS:-1}"
export PHP_TASK_WORKERS="${PHP_TASK_WORKERS:-$(nproc)}"

# Postgres is on this machine, so no TLS. A sslmode in DATABASE_URL takes precedence.
export PGSSLMODE="${PGSSLMODE:-disable}"

connections=$((PHP_WORKERS * PG_CONNECTIONS))
if [ "$connections" -gt 90 ]; then
  echo "PHP_WORKERS x PG_CONNECTIONS is $connections; more than 90 Postgres connections would not fit under the box's limit of 95" >&2
  exit 1
fi

# Every connection is an open file: raise the limit as far as it may go.
ulimit -Sn "$(ulimit -Hn)" 2>/dev/null || true

export APP_ENV=prod
export APP_DEBUG=0

# php.ini sits next to this script. PHP_INI_SCAN_DIR may name a directory of extra ini files; it is empty by default.
export PHPRC="$PWD"
export PHP_INI_SCAN_DIR="${PHP_INI_SCAN_DIR:-}"

# The server runs as a child so that a stop request can be repeated: Swoole's manager can miss a SIGTERM that arrives
# while it is replacing a worker.
php bin/server.php &
server=$!

stopping=0
trap 'stopping=1' TERM INT

while kill -0 "$server" 2>/dev/null; do
  if [ "$stopping" -eq 1 ]; then
    kill -TERM "$server" 2>/dev/null || true
    sleep 0.2
  else
    wait "$server" || true
  fi
done

wait "$server"
