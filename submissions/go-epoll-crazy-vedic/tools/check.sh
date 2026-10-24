#!/usr/bin/env bash
# Tests use disposable clones and never modify the seed template.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TEMPLATE="${TEMPLATE:-conduit_dev}"
[[ "$TEMPLATE" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]] || { echo "invalid TEMPLATE" >&2; exit 2; }
DB="zenith_check_$$"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d postgres)
cleanup() { "${PSQL[@]}" -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"${PSQL[@]}" -c "CREATE DATABASE $DB TEMPLATE $TEMPLATE STRATEGY FILE_COPY"
case "${PGHOST:-}" in ""|/*) DBHOST=127.0.0.1 ;; *) DBHOST="$PGHOST" ;; esac
export TEST_DATABASE_URL="postgres://conduit:conduit@$DBHOST:${PGPORT:-5432}/$DB"
export GOTOOLCHAIN=go1.27.2 CGO_ENABLED="${CGO_ENABLED:-1}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:--O3 -DNDEBUG -march=native}"
cd "$HERE"
flags=(-count=1)
if [ "${RACE:-0}" = 1 ]; then flags+=(-race); fi
go test "${flags[@]}" ./src/...
if [ -n "${FUZZ_TIME:-}" ]; then
  for target in FuzzWireFraming FuzzJWTMatchesLibrary; do
    go test ./src -run '^$' -fuzz "^$target$" -fuzztime "$FUZZ_TIME" -parallel 2
  done
fi
cd "$ROOT"
PORT="${PORT:-3111}" bash test/run.sh "$HERE"
