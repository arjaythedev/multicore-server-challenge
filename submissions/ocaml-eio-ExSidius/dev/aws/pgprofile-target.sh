#!/usr/bin/env bash
# Runs on the target as root while load_start has been kicked off from the load generator. Profiles everything Postgres
# does during a fixed load: per-statement cost (pg_stat_statements), where the CPU goes down to C functions and kernel
# (perf), and what backends wait on. The profiling config is removed again afterwards.
#   pgprofile-target.sh setup | capture <dir> <settle-seconds> | teardown
set -euo pipefail
CONF=/etc/postgresql/18/main/conf.d/95-profile.conf
PSQL="runuser -u postgres -- psql -qX -d postgres"
case "$1" in
  setup)
    export DEBIAN_FRONTEND=noninteractive
    command -v perf >/dev/null && perf --version >/dev/null 2>&1 || apt-get install -y -q linux-tools-common "linux-tools-$(uname -r)" >/dev/null
    apt-get install -y -q postgresql-18-dbgsym >/dev/null 2>&1 || true
    cat > "$CONF" <<CONFEOF
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.max = 500
pg_stat_statements.track = top
pg_stat_statements.track_planning = on
track_io_timing = on
CONFEOF
    systemctl restart postgresql@18-main
    for _ in $(seq 30); do runuser -u postgres -- pg_isready -q && break; sleep 1; done
    $PSQL -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
    perf --version ;;
  capture)
    OUT="$2"; mkdir -p "$OUT"; sleep "$3"
    $PSQL -c "SELECT pg_stat_statements_reset()" >/dev/null
    runuser -u postgres -- psql -qtAX -d conduit -c "SELECT blks_read, blks_hit, xact_commit, tup_returned, tup_fetched, temp_files, temp_bytes FROM pg_stat_database WHERE datname = 'conduit'" > "$OUT/db_before.txt"
    start=$(date +%s.%N)
    : > "$OUT/waits.txt"
    ( for _ in $(seq 60); do
        runuser -u postgres -- psql -qtAX -d postgres -c "SELECT state, coalesce(wait_event_type,'CPU'), coalesce(wait_event,'running'), count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND datname='conduit' GROUP BY 1,2,3" >> "$OUT/waits.txt" 2>/dev/null
        sleep 1
      done ) &
    waiter=$!
    perf record -q -F 199 -a -g -e cpu-clock -o "$OUT/perf.data" -- sleep 60
    wait "$waiter"
    elapsed=$(awk "BEGIN{print $(date +%s.%N) - $start}"); echo "$elapsed" > "$OUT/elapsed.txt"
    runuser -u postgres -- psql -qtAX -d conduit -c "SELECT blks_read, blks_hit, xact_commit, tup_returned, tup_fetched, temp_files, temp_bytes FROM pg_stat_database WHERE datname = 'conduit'" > "$OUT/db_after.txt"
    runuser -u postgres -- psql -X -d postgres --csv > "$OUT/statements.csv" <<'SQL'
SELECT calls, round(total_exec_time::numeric, 1) AS exec_ms, round(total_plan_time::numeric, 1) AS plan_ms, plans,
       round(mean_exec_time::numeric, 3) AS mean_ms, round(max_exec_time::numeric, 1) AS max_ms, rows,
       shared_blks_hit, shared_blks_read, shared_blks_dirtied, wal_bytes, temp_blks_written,
       round(shared_blk_read_time::numeric, 1) AS read_ms, regexp_replace(query, '\s+', ' ', 'g') AS query
  FROM pg_stat_statements s JOIN pg_database d ON d.oid = s.dbid WHERE d.datname = 'conduit' AND calls > 0
 ORDER BY total_exec_time DESC
SQL
    perf report -i "$OUT/perf.data" --no-children --sort comm -g none --percent-limit 0.3 --stdio 2>/dev/null | grep -vE '^#|^$' > "$OUT/by_process.txt"
    perf report -i "$OUT/perf.data" --no-children --comm postgres --sort dso -g none --percent-limit 0.3 --stdio 2>/dev/null | grep -vE '^#|^$' > "$OUT/postgres_by_dso.txt"
    perf report -i "$OUT/perf.data" --no-children --comm postgres --sort symbol -g none --percent-limit 0.25 --stdio 2>/dev/null | grep -vE '^#|^$' > "$OUT/postgres_symbols.txt"
    perf report -i "$OUT/perf.data" --no-children --comm main.exe --sort symbol -g none --percent-limit 0.4 --stdio 2>/dev/null | grep -vE '^#|^$' > "$OUT/app_symbols.txt"
    perf report -i "$OUT/perf.data" --no-children --comm main.exe --sort dso -g none --percent-limit 0.05 --stdio 2>/dev/null | grep -vE '^#|^$' > "$OUT/app_by_dso.txt"
    perf report -i "$OUT/perf.data" --no-children --comm main.exe --sort dso,symbol -g none --percent-limit 0.04 --stdio 2>/dev/null | grep -vE '^#|^$' > "$OUT/app_all_symbols.txt"
    runuser -u postgres -- psql -qtAX -d postgres -c "SELECT ssl, count(*) FROM pg_stat_ssl s JOIN pg_stat_activity a USING (pid) WHERE a.backend_type = 'client backend' AND a.datname = 'conduit' GROUP BY 1" > "$OUT/tls.txt" ;;
  teardown)
    rm -f "$CONF"
    systemctl restart postgresql@18-main ;;
esac
