#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
ulimit -n "$(ulimit -Hn)"
export DB_POOL_SIZE=1
export WORKERS="${WORKERS:-$(( $(nproc) * 2 ))}"
exec ./build/server
