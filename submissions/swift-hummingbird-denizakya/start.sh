#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# One Postgres connection pool; default 3 connections per core, capped at 95 (SPEC.md: max_connections = 100).
set -euo pipefail
export PATH="/opt/swift/usr/bin:$PATH"
DIR="$(cd "$(dirname "$0")" && pwd)"
NPROC="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
DEFAULT_POOL=$(( 3 * NPROC ))
[ "$DEFAULT_POOL" -gt 95 ] && DEFAULT_POOL=95
export DB_POOL_SIZE="${DB_POOL_SIZE:-$DEFAULT_POOL}"
exec "$DIR/.build/release/Conduit"
