#!/usr/bin/env bash
# Runs the repository's load generator against a locally built server and the dev seed.
#
#   LOADGEN=/path/to/loadgen bash scripts/loadtest.sh [users] [measure-window]
#
# LOADGEN defaults to /tmp/loadgen-mac; build it with:
#   cd bench && go build -o /tmp/loadgen-mac ./cmd/loadgen
set -uo pipefail

LDC_BIN="${LDC_BIN:-/Users/cyrus_msk/Documents/Files/Software/ldc-osx-arm64/bin}"
PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@14/bin}"
PGPORT="${PGPORT:-5433}"
USERS=${1:-800}
MEASURE=${2:-40s}
LOADGEN="${LOADGEN:-/tmp/loadgen-mac}"

export PATH="$LDC_BIN:$PG_BIN:$PATH"
export PGHOST=127.0.0.1 PGPORT PGUSER=${USER}
export DATABASE_URL="postgres://conduit:conduit@127.0.0.1:$PGPORT/conduit_dev"
export JWT_SECRET=multicore-server-challenge HOST=127.0.0.1 PORT=3200
BASE="http://127.0.0.1:3200"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SUB="$ROOT/submissions/d-vibe-cyrusmsk"

TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
  pkill -f "conduit-vibed" 2>/dev/null
}
trap cleanup EXIT

# The dev seed is a working copy of the full one; running against it directly
# keeps the run short, at the price of it living in conduit_dev afterwards.
DYLD_LIBRARY_PATH=/opt/homebrew/opt/libpq/lib "$SUB/bin/conduit-vibed" > "$TMP/server.log" 2>&1 &
PID=$!
for _ in $(seq 60); do curl -sf -o /dev/null "$BASE/api/tags" && break; sleep 1; done
curl -sf -o /dev/null "$BASE/api/tags" || { echo "server did not start"; cat "$TMP/server.log"; exit 1; }

"$LOADGEN" run -target "$BASE" -users "$USERS" -box-index 0 -id-offset 0 -ramp 15s -measure "$MEASURE" \
    -tail 10s -secret "$JWT_SECRET" -run-id local-probe-1 -articles 10000 -out "$TMP/box0.json" 2>&1 | tail -22
echo "== server log errors: $(grep -cE 'request failed' "$TMP/server.log")"
kill $PID
