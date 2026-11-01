#!/usr/bin/env bash
# Runs the server in the foreground. Required config: DATABASE_URL, JWT_SECRET. Optional: HOST (127.0.0.1),
# PORT (3000), APP_THREADS (min(ceil(cores/4), 8)), DB_READ_CONNS (3), BCRYPT_THREADS (min(ceil(cores/4), 2)),
# WRITE_BATCH_US (1000), BCRYPT_BATCH_MS (150), READ_BATCH_MS (0), READ_SHARE_PCT (100), SCHED_BATCH (1),
# HTTP_GZIP (0 never, 1 always, unset adaptive).
# GET /api/tags answers within 60 s of this script. No additional configuration is required.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/conduit"
