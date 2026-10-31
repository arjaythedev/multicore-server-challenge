#!/usr/bin/env bash
# Box-side telemetry for a benchmark run, on the target as root: per-CPU, per-thread, disk, scheduler and socket
# stats plus Postgres wait events, each with timestamps, into a directory. Runs until killed.
#   telemetry.sh /root/telemetry/<label>
set -u
OUT="${1:?usage: telemetry.sh <dir>}"
mkdir -p "$OUT"
export S_TIME_FORMAT=ISO LC_ALL=C
trap 'kill $(jobs -p) 2>/dev/null; exit 0' INT TERM HUP EXIT
mpstat -P ALL 1 > "$OUT/mpstat.txt" &
pidstat -t -u -h 1 -C main.exe > "$OUT/threads.txt" &
pidstat -u -w -h 1 -C postgres > "$OUT/postgres.txt" &
iostat -xmt 1 > "$OUT/iostat.txt" &
vmstat -t -w 1 > "$OUT/vmstat.txt" &
{
  cat <<'SQL'
\pset format unaligned
\pset tuples_only on
SELECT extract(epoch FROM now())::numeric(14,1) AS ts, state, coalesce(wait_event_type, 'CPU') AS type,
       coalesce(wait_event, 'running') AS event, count(*)
  FROM pg_stat_activity
 WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
 GROUP BY 1, 2, 3, 4 \watch 1
SQL
} | runuser -u postgres -- psql -qX -d postgres > "$OUT/pg_wait.txt" 2>/dev/null &
while :; do
  echo "$(date +%s) $(ss -s | awk '/^TCP:/{print}')"
  runuser -u postgres -- psql -qtAX -d postgres -c "SELECT extract(epoch FROM now())::bigint, wal_records, wal_bytes, wal_fpi FROM pg_stat_wal" -c "SELECT extract(epoch FROM now())::bigint, num_timed, num_requested, write_time, sync_time, buffers_written FROM pg_stat_checkpointer" >> "$OUT/pg_io.txt" 2>/dev/null
  sleep 5
done > "$OUT/sockets.txt" &
wait
