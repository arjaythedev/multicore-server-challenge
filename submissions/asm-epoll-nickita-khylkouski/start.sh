#!/usr/bin/env bash
# Runs the server in the foreground. Required config: DATABASE_URL, JWT_SECRET. Optional: HOST (127.0.0.1),
# PORT (3000), APP_THREADS (min(ceil(3*cores/8), 8)), DB_READ_CONNS (2), BCRYPT_THREADS (ceil(cores/8)),
# WRITE_BATCH_US (1000), HTTP_GZIP (0 never, 1 always, unset adaptive).
# GET /api/tags answers within 60 s of this script. No additional configuration is required.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/conduit"
