#!/usr/bin/env bash
# The harness (the sss8 rule: never rely on manual testing). Green or red, one verdict at the end.
#
#   bash check.sh            # 1 build (Release, warnings are errors) -> 2 unit facts -> 3 conformance
#                            #   -> 4 the read-batching property
#   SKIP_CONFORMANCE=1 bash check.sh   # the quick gate: 1 and 2 only, no database
#
# Phase 3 is the repo's own test/run.sh (what CI runs): it needs the dev seed, Go, psql and curl,
# with Postgres superuser access through the libpq variables (see ../../test/run.sh). Phase 4
# runs Tests/BatchTests.fs (FsCheck: a request's answer never depends on its batch-mates) against
# a fresh copy of the same dev seed, with the same psql access.
# Every phase runs whatever an earlier one said, so one red never hides another.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
export DOTNET_ROOT="${DOTNET_ROOT:-/usr/local/dotnet}" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
DOTNET="$DOTNET_ROOT/dotnet"; [ -x "$DOTNET" ] || DOTNET=dotnet
declare -A verdict
t0=$(date +%s)

phase() {  # key, command...
  local key="$1"; shift
  local s=$(date +%s)
  echo "== $key"
  if "$@"; then verdict[$key]=GREEN; else verdict[$key]=RED; fi
  echo "-- $key took $(( $(date +%s) - s ))s: ${verdict[$key]}"
}

phase 1-build bash "$DIR/build.sh"
phase 2-facts "$DOTNET" test "$DIR/src/Tests" -nologo -v q --filter 'FullyQualifiedName!~BatchTests'

batches() {  # a fresh copy of the dev seed, the property against it, the copy dropped
  local db="batch_test_$$" psql="psql -X -q -v ON_ERROR_STOP=1 -d postgres" host
  case "${PGHOST:-}" in ""|/*) host=127.0.0.1 ;; *) host="$PGHOST" ;; esac
  $psql -c "CREATE DATABASE $db TEMPLATE ${TEMPLATE:-conduit_dev} STRATEGY FILE_COPY" || return 1
  BATCH_TEST_DATABASE_URL="postgres://conduit:conduit@$host:${PGPORT:-5432}/$db" \
    "$DOTNET" test "$DIR/src/Tests" -nologo -v q --filter 'FullyQualifiedName~BatchTests'
  local status=$?
  $psql -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" || true
  return $status
}

if [ -n "${SKIP_CONFORMANCE:-}" ]; then
  verdict[3-conformance]="not run"
  verdict[4-batches]="not run"
else
  phase 3-conformance bash "$ROOT/test/run.sh" "$DIR"
  phase 4-batches batches
fi

echo "== verdict"
red=0
for k in 1-build 2-facts 3-conformance 4-batches; do
  printf '  %-15s %s\n' "$k" "${verdict[$k]}"
  [ "${verdict[$k]}" = RED ] && red=1
done
if [ $red = 0 ]; then echo "check.sh: ALL GREEN in $(( $(date +%s) - t0 ))s"; else echo "check.sh: RED in $(( $(date +%s) - t0 ))s"; exit 1; fi
