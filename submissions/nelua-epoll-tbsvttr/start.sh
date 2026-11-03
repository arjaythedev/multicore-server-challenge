#!/usr/bin/env bash
# Foreground (systemd ExecStart). Config from env: DATABASE_URL, JWT_SECRET, HOST, PORT. Optional:
#   DB_POOL         Postgres connections, the database process's (default 48)
#   WORKERS         HTTP worker processes (default: one per 2 CPUs this process may use)
#   BATCH_MS        how long the first read of a kind waits at least for others to share its batch (default 20)
#   BATCH_INFLIGHT  batches of one kind in flight at once, at most (default 3)
#   BATCH_SLOW_MS   how long a batch in flight runs before the next of its kind may go alongside (default 100)
#   BATCH_MAX       requests in one batch, at most (default 4000)
#   BATCH_US        how long a process waits after a quiet loop pass, in microseconds (default 2000)
#   GZIP            1: gzip responses when that saves a TCP segment (default 0)
#   BCRYPT_HELPERS  bcrypt processes (default: one per CPU), BCRYPT_LANES (default: the fastest here, measured at
#                   start), BCRYPT_WAIT_MS (how long a first hash waits for others to share its lanes, default 150)
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/build/conduit"
