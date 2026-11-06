#!/usr/bin/env bash
# A local Postgres 18 with the benchmark box's settings (box/pg-conf.sh for 8 CPUs and 16 GB), on its own port.
#   dev/tools.sh dev/pg.sh up | down | status
set -euo pipefail
. "$(dirname "$0")/env.sh"
init() {
  mkdir -p "$BENCH_HOME"
  mkdir "$PGDATA"
  chmod 700 "$PGDATA"
  chattr +C "$PGDATA" 2>/dev/null || true   # no copy-on-write on btrfs: database files shouldn't pay for it
  local pw; pw=$(mktemp); echo "$PGPASSWORD" > "$pw"
  initdb -D "$PGDATA" -U postgres --pwfile="$pw" --auth-host=scram-sha-256 --auth-local=trust -E UTF8 --locale=C.UTF-8 >/dev/null
  rm -f "$pw"
  cat >> "$PGDATA/postgresql.conf" <<CONF
listen_addresses = '127.0.0.1'
port = $PGPORT
unix_socket_directories = '$PGDATA'
# box/pg-conf.sh --print on an 8 CPU, 16 GB box:
max_connections = 100
shared_buffers = 4096MB
effective_cache_size = 12288MB
maintenance_work_mem = 1024MB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
work_mem = 9709kB
huge_pages = try
min_wal_size = 1GB
max_wal_size = 4GB
max_worker_processes = 8
max_parallel_workers = 8
max_parallel_workers_per_gather = 4
max_parallel_maintenance_workers = 4
CONF
}
case "${1:-status}" in
  up)
    [ -d "$PGDATA" ] || init
    pg_ctl -D "$PGDATA" status >/dev/null 2>&1 || \
      taskset -c "$TARGET_CPUS" pg_ctl -D "$PGDATA" -l "$BENCH_HOME/postgres.log" -w start </dev/null >/dev/null 2>&1
    psql -X -Atd postgres -c 'show server_version' ;;
  down) pg_ctl -D "$PGDATA" -m fast stop ;;
  status) pg_ctl -D "$PGDATA" status ;;
  *) echo "usage: pg.sh up|down|status"; exit 2 ;;
esac
