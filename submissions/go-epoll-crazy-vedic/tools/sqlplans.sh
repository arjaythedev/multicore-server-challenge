#!/usr/bin/env bash
# Capture prepared-query plans on a disposable full-seed clone.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/.bench/sqlplans-$(date +%Y%m%d-%H%M%S)"
DB="zenith_sqlplan_$$"
mkdir -p "$OUT"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d postgres)
cleanup() { "${PSQL[@]}" -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null; }
trap cleanup EXIT
"${PSQL[@]}" -c "CREATE DATABASE $DB TEMPLATE conduit_seed STRATEGY FILE_COPY"
case "${PGHOST:-}" in ""|/*) DBHOST=127.0.0.1 ;; *) DBHOST="$PGHOST" ;; esac
export TEST_DATABASE_URL="postgres://conduit:conduit@$DBHOST:${PGPORT:-5432}/$DB"
export GOTOOLCHAIN=go1.27.2 CGO_ENABLED=1
export CGO_CXXFLAGS="${CGO_CXXFLAGS:--O3 -DNDEBUG -march=native}"

capture() {
  local label="$1" mode="$2" metadata="$3" recent="$4" favorite="$5"
  echo "== $label: plan_cache_mode=$mode metadata=$metadata recent_feed=$recent favorite=$favorite"
  CAPTURE_SQL_PLANS=1 PG_PLAN_MODE="$mode" SQL_METADATA_BATCH="$metadata" \
    FEED_RECENT_SCAN="$recent" PG_FAVORITE_MODE="$favorite" \
    PLAN_OUT="$OUT/$label.json" go test ./src -run '^TestCaptureSQLPlans$' -count=1 -v
}

cd "$HERE"
capture generic-reference force_generic_plan 0 0 combined
capture custom-reference force_custom_plan 0 0 combined
capture auto-reference auto 0 0 combined
capture generic-metadata force_generic_plan 1 0 combined
capture generic-recent-feed force_generic_plan 0 1 combined
capture generic-separate-favorites force_generic_plan 0 0 separate
echo "SQL plan artifacts: $OUT"
