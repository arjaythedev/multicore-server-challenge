#!/usr/bin/env bash
set -euo pipefail

MODE="${1:?Usage: sql-profile.sh off|on|detailed}"

case "$MODE" in
  off)
    TRACK="none"
    IO="off"
    PLANNING="off"
    ;;
  on)
    TRACK="top"
    IO="off"
    PLANNING="off"
    ;;
  detailed)
    TRACK="top"
    IO="on"
    PLANNING="on"
    ;;
  *)
    echo "Unknown SQL profiling mode: $MODE" >&2
    exit 2
    ;;
esac

sudo -u postgres psql -X -v ON_ERROR_STOP=1 \
  -d postgres \
  -c "ALTER SYSTEM SET \"pg_stat_statements.track\" = '$TRACK';" \
  -c "ALTER SYSTEM SET track_io_timing = '$IO';" \
  -c "ALTER SYSTEM SET \"pg_stat_statements.track_planning\" = '$PLANNING';" \
  -c "SELECT pg_reload_conf();"

sudo -u postgres psql -X -d postgres \
  -c "SHOW pg_stat_statements.track;" \
  -c "SHOW pg_stat_statements.track_planning;" \
  -c "SHOW track_io_timing;"
