#!/usr/bin/env bash
# Runs the server in the foreground. Required config: DATABASE_URL, JWT_SECRET. Optional: HOST (127.0.0.1),
# PORT (3000). Tuning knobs (defaults below are the ones measured for an 8-core box, see README):
#   APP_THREADS, DB_READ_CONNS      epoll workers and read connections per worker (4 x 2 + 4 writers = 12 conns)
#   READ_BATCH_US, READ_BATCH_MAX   read-collection window (us) and the most reads in one batched statement
#   READ_BATCH_US_SMALL             window of the cheap families (tags, profile, user); default READ_BATCH_US / 4
#   BCRYPT_WAIT_US, BCRYPT_LANES_MIN  how long a login may wait for company to fill the 6-lane bcrypt call
#   WRITE_BATCH_US (1000), HTTP_GZIP (0 never, 1 always, unset adaptive), HTTP_QUICKACK (0; 1 = TCP_QUICKACK off per response)
# GET /api/tags answers within 60 s of this script. No additional configuration is required.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export APP_THREADS="${APP_THREADS:-4}"
export DB_READ_CONNS="${DB_READ_CONNS:-2}"
export READ_BATCH_US="${READ_BATCH_US:-50000}"
export READ_BATCH_MAX="${READ_BATCH_MAX:-256}"
exec "$DIR/conduit"
