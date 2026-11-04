#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
exec "$DIR/bin/conduit"
