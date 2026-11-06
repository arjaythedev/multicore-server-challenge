#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:?Usage: sql-snapshot.sh begin|end RUN_ID}"
RUN_ID="${2:?RUN_ID is required}"

if [[ ! "$ACTION" =~ ^(begin|end)$ ]]; then
  echo "Action must be begin or end" >&2
  exit 2
fi

if [[ ! "$RUN_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Invalid RUN_ID" >&2
  exit 2
fi

OBS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$OBS_DIR/runs/$RUN_ID"

mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR"

FILE="$RUN_DIR/sql-$ACTION.csv"

if [[ -e "$FILE" ]]; then
  echo "Snapshot already exists: $FILE" >&2
  exit 2
fi

if [[ "$ACTION" == "end" && ! -f "$RUN_DIR/sql-begin.csv" ]]; then
  echo "Missing begin snapshot" >&2
  exit 2
fi

TEMP_FILE="$(mktemp "$RUN_DIR/.sql-XXXXXX")"
trap 'rm -f "$TEMP_FILE"' EXIT

sudo -u postgres psql \
  -X -q -v ON_ERROR_STOP=1 \
  -d conduit_lg \
  -c "
COPY (
  SELECT
    dbid,
    userid,
    toplevel,
    queryid,
    calls,
    total_exec_time,
    rows,
    shared_blks_hit,
    shared_blks_read,
    temp_blks_written,
    query
  FROM pg_stat_statements
  WHERE dbid = (
    SELECT oid
    FROM pg_database
    WHERE datname = 'conduit_lg'
  )
) TO STDOUT WITH (FORMAT csv, HEADER true);
" > "$TEMP_FILE"

mv "$TEMP_FILE" "$FILE"

sudo -u postgres psql \
  -X -A -t -v ON_ERROR_STOP=1 \
  -d conduit_lg \
  -c "SELECT stats_reset, dealloc FROM pg_stat_statements_info;" \
  > "$RUN_DIR/sql-$ACTION.meta"

date -u +'%Y-%m-%dT%H:%M:%SZ' \
  > "$RUN_DIR/sql-$ACTION.timestamp"

echo "Snapshot saved: $FILE"
