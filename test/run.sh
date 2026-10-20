#!/usr/bin/env bash
# Builds a submission, starts it on a fresh copy of the seed database and runs the conformance suite.
# This is exactly what CI runs on every pull request.
#
#   bash test/run.sh submissions/<your-folder>
#
# Run your install.sh yourself first (once, as root). Needs the dev seed (bash seed/make-seed.sh --dev),
# Go >= 1.27 (builds bench/cmd/conformance), psql and curl. Postgres superuser access through the usual libpq
# variables (PGHOST, PGPORT, PGUSER, PGPASSWORD), as for make-seed.sh. TEMPLATE=conduit_seed tests on the full seed.
set -euo pipefail
DIR="$(cd "${1:?usage: test/run.sh submissions/<folder>}" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="${TEMPLATE:-conduit_dev}"
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d postgres"
for f in build.sh start.sh README.md; do [ -f "$DIR/$f" ] || { echo "missing $DIR/$f"; exit 1; }; done
grep -qiE '^[*_ ]*front[*_ ]*:[*_ ]*(nginx|direct)' "$DIR/README.md" || {
  echo "README.md needs a line 'Front: nginx' or 'Front: direct' (rule 10)"; exit 1; }
[ "$($PSQL -Atc "SELECT count(*) FROM pg_database WHERE datname = '$TEMPLATE'")" = 1 ] || {
  echo "no database $TEMPLATE: run bash seed/make-seed.sh --dev"; exit 1; }

TMP="$(mktemp -d)"
DB="challenge_test_$$"
case "${PGHOST:-}" in ""|/*) DBHOST=127.0.0.1 ;; *) DBHOST="$PGHOST" ;; esac
export DATABASE_URL="postgres://conduit:conduit@$DBHOST:${PGPORT:-5432}/$DB"
export JWT_SECRET=multicore-server-challenge HOST=127.0.0.1 PORT="${PORT:-3000}"
BASE="http://$HOST:$PORT"

echo "== conformance suite"
(cd "$ROOT/bench" && go build -o "$TMP/conformance" ./cmd/conformance)
echo "== fresh database $DB from $TEMPLATE"
$PSQL -c "CREATE DATABASE $DB TEMPLATE $TEMPLATE STRATEGY FILE_COPY"

PID=""
cleanup() {
  if [ -n "$PID" ]; then pkill -P "$PID" 2>/dev/null || true; kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  $PSQL -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== build"; bash "$DIR/build.sh"
echo "== start"
bash "$DIR/start.sh" > "$TMP/server.log" 2>&1 &
PID=$!
for _ in $(seq 60); do curl -sf -o /dev/null "$BASE/api/tags" && break; sleep 1; done
curl -sf -o /dev/null "$BASE/api/tags" || { echo "GET /api/tags not 200 after 60 s"; cat "$TMP/server.log"; exit 1; }

echo "== test"
rc=0; "$TMP/conformance" -base "$BASE" -secret "$JWT_SECRET" -q || rc=$?
[ $rc = 0 ] || { echo "== server log (last 30 lines)"; tail -30 "$TMP/server.log"; }
exit $rc
