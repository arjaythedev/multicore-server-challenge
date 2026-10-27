#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
case "${1:-status}" in
  start)
    if [ ! -f "$PGDATA/PG_VERSION" ]; then
      password_file="$(mktemp "$TMPDIR/pg-password.XXXXXX")"
      trap 'rm -f "$password_file"' EXIT
      chmod 600 "$password_file"
      printf '%s\n' "$PGPASSWORD" > "$password_file"
      initdb -D "$PGDATA" --username="$PGUSER" --pwfile="$password_file" --auth=scram-sha-256 --encoding=UTF8 --locale=C > "$CHALLENGE_WORK/logs/postgres-init.log"
      cat >> "$PGDATA/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
port = 55432
# The workspace path exceeds macOS's Unix socket limit; use authenticated TCP.
unix_socket_directories = ''
shared_buffers = '128MB'
max_connections = 100
timezone = 'UTC'
EOF
    fi
    if pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then echo 'Project database already running.'; else pg_ctl -D "$PGDATA" -l "$CHALLENGE_WORK/logs/postgres.log" -w -t 30 start; fi
    ;;
  stop) pg_ctl -D "$PGDATA" -m fast -w stop ;;
  status) pg_ctl -D "$PGDATA" status ;;
  seed)
    if [ "$(psql -X -Atqc "SELECT count(*) FROM pg_database WHERE datname='conduit_dev'")" != 0 ]; then
      echo 'conduit_dev already exists; keeping it. Use fresh test database copies.'
    else
      bash "$CHALLENGE_REPO/seed/make-seed.sh" --dev
    fi
    if [ "$(psql -X -Atqc "SELECT count(*) FROM pg_database WHERE datname='conduit_local'")" = 0 ]; then
      createdb -T conduit_dev conduit_local
      echo 'Created conduit_local for interactive development; conduit_dev remains the template.'
    fi
    ;;
  *) echo 'Usage: database.sh start|stop|status|seed' >&2; exit 2 ;;
esac
