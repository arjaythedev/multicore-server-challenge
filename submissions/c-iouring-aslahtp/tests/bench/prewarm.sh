#!/usr/bin/env bash
# Makes (or refreshes) a measurement copy of TEMPLATE and reads all of it into the OS cache and shared_buffers,
# for repeated runs with DB=<name> bash tests/bench/measure.sh ...
#
#   bash tests/bench/prewarm.sh [NAME]      (default measure_warm; TEMPLATE as in measure.sh)
set -euo pipefail
NAME=${1:-measure_warm}
TEMPLATE=${TEMPLATE:-conduit_seed}
P="psql -X -q -v ON_ERROR_STOP=1"
$P -d postgres -c "DROP DATABASE IF EXISTS $NAME WITH (FORCE)"
$P -d postgres -c "CREATE DATABASE $NAME TEMPLATE $TEMPLATE STRATEGY FILE_COPY"
sync
$P -d "$NAME" -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm"
$P -d "$NAME" -At -c "
  SELECT sum(pg_prewarm(c.oid, 'read')) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r', 'i', 't');
  SELECT sum(pg_prewarm(c.oid, 'buffer')) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'i';" > /dev/null
echo "$NAME ready ($($P -d postgres -At -c "SELECT pg_size_pretty(pg_database_size('$NAME'))"))"
