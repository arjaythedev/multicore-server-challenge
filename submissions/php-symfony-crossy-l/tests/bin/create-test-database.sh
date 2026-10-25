#!/usr/bin/env bash
# Creates the database the integration tests run against, as a copy of the dev seed. Safe to run again:
# an existing database is left alone, so this costs nothing once it has run.
#
#   tests/bin/create-test-database.sh            create it if it is missing
#   tests/bin/create-test-database.sh --rebuild  drop it and copy the seed again
#
# Connects as a Postgres superuser through the usual libpq variables (PGHOST, PGUSER, PGPASSWORD).
# TEST_DATABASE names the database (default conduit_phpunit); TEMPLATE names the seed (default conduit_dev).
set -euo pipefail

DB="${TEST_DATABASE:-conduit_phpunit}"
TEMPLATE="${TEMPLATE:-conduit_dev}"
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d postgres"

if [ "${1:-}" = --rebuild ]; then
  $PSQL -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)"
fi

exists="$($PSQL -Atc "SELECT count(*) FROM pg_database WHERE datname = '$DB'")"
if [ "$exists" != 0 ]; then
  echo "test database $DB exists"
  exit 0
fi

[ "$($PSQL -Atc "SELECT count(*) FROM pg_database WHERE datname = '$TEMPLATE'")" = 1 ] \
  || { echo "no database $TEMPLATE to copy: run task seed-dev first" >&2; exit 1; }

$PSQL -c "CREATE DATABASE $DB TEMPLATE $TEMPLATE STRATEGY FILE_COPY"
echo "test database $DB created from $TEMPLATE"
