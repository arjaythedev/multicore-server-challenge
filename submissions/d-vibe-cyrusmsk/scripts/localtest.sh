#!/usr/bin/env bash
# Runs the conformance suite against a fresh copy of the dev seed, the way test/run.sh
# does, from this workstation (macOS with homebrew's PostgreSQL 14 and LDC).
#
#   bash scripts/localtest.sh [port]
set -uo pipefail

LDC_BIN="${LDC_BIN:-/Users/cyrus_msk/Documents/Files/Software/ldc-osx-arm64/bin}"
PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@14/bin}"
PGPORT="${PGPORT:-5433}"

export PATH="$LDC_BIN:$PG_BIN:$PATH"
export PGHOST=127.0.0.1 PGPORT PGUSER=${USER}

PORT=${1:-3103}
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SUB="$ROOT/submissions/d-vibe-cyrusmsk"
DB="conduit_local_$$"
export DATABASE_URL="postgres://conduit:conduit@127.0.0.1:$PGPORT/$DB"
export JWT_SECRET=multicore-server-challenge HOST=127.0.0.1 PORT=$PORT
BASE="http://127.0.0.1:$PORT"

TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
  pkill -f "conduit-vibed" 2>/dev/null
  psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1
}
trap cleanup EXIT

echo "== build"
(cd "$ROOT/bench" && go build -o "$TMP/conformance" ./cmd/conformance) || exit 1
(cd "$SUB" && dub build --compiler=ldc2) || exit 1

echo "== fresh database $DB from conduit_dev"
psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" \
    -c "CREATE DATABASE $DB TEMPLATE conduit_dev" || exit 1

echo "== start"
# dpq2 loads libpq at runtime, and on macOS homebrew's libpq is not in the loader path
DYLD_LIBRARY_PATH=/opt/homebrew/opt/libpq/lib \
    "$SUB/bin/conduit-vibed" > "$TMP/server.log" 2>&1 &
PID=$!
for _ in $(seq 60); do curl -sf -o /dev/null "$BASE/api/tags" && break; sleep 1; done
curl -sf -o /dev/null "$BASE/api/tags" || { echo "server did not start"; cat "$TMP/server.log"; exit 1; }

echo "== conformance"
rc=0
"$TMP/conformance" -base "$BASE" -secret "$JWT_SECRET" || rc=$?
[ $rc = 0 ] || { echo "== server log (last 40 lines)"; tail -40 "$TMP/server.log"; }
exit $rc
