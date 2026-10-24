#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Two worker processes per core (bcrypt blocks a worker's green threads), sharing 80 Postgres connections
# (5 per worker on the 8-core box).
set -euo pipefail
cd "$(dirname "$0")"
PREFIX="${CHICKEN_PREFIX:-/opt/chicken}"
export CHICKEN_REPOSITORY_PATH="$PWD/eggs:$(env -u CHICKEN_INSTALL_REPOSITORY "$PREFIX/bin/chicken-install" -repository)"
export WORKERS="${WORKERS:-$(( 2 * $(nproc) ))}"
export DB_POOL_SIZE="${DB_POOL_SIZE:-$(( WORKERS >= 80 ? 1 : 80 / WORKERS ))}"
exec ./bin/conduit
