#!/usr/bin/env bash
# Restart the benchmark's Postgres so every run starts from the same state (run.sh calls this before each measurement).
#   PGDATA      data directory (default: ./pgdata)
#   PG_BIN      directory with pg_ctl (default: the pg_ctl on PATH)
#   PG_CPUS     CPUs to pin Postgres to, as taskset takes them (default: 1-3,7-9)
set -euo pipefail
PGDATA="${PGDATA:-$PWD/pgdata}"
PG_CTL="${PG_BIN:+$PG_BIN/}pg_ctl"
"$PG_CTL" -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || true
taskset -c "${PG_CPUS:-1-3,7-9}" "$PG_CTL" -D "$PGDATA" -l "$PGDATA/server.log" -w start >/dev/null
