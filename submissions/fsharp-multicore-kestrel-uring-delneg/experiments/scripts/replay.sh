#!/usr/bin/env bash
# replay.sh <sqlfile> <kind> [batches=300] [batch=16] [db=conduit_seed]
# Times one batched statement (from MC_DUMP_SQL output, "-- <kind>" section) over fixed, seeded inputs in a single
# backend: SQL shape A/B without HTTP or scheduling noise. Prints ms per batch and backend CPU us per request.
set -euo pipefail
F=$1; K=$2; NB=${3:-300}; B=${4:-16}; DB=${5:-conduit_seed}
W=/tmp/replay; mkdir -p $W
SQL=$(awk -v k="-- $K" '$0==k{f=1;next} /^-- /{f=0} f' "$F" | sed '/^$/d')
[ -n "$SQL" ] || { echo "no section $K in $F"; exit 1; }
# inputs: deterministic per (kind, NB, B)
KB=${K%% *}; IN=$W/in-$KB-$NB-$B.sql
if [ ! -f $IN ]; then
  q() { local o=""; for e in "$@"; do o="$o${o:+, }quote_literal(array_agg($e)::text)"; done; echo "$o"; }
  ART="(SELECT slug FROM articles WHERE id = s)"
  AUTH="(SELECT u.username FROM users u JOIN articles a ON a.author_id = u.id WHERE a.id = s)"
  case $KB in
    tags) ARGS=$(q i);;
    user) ARGS=$(q i v);;
    article*|comments*) ARGS=$(q i v "$ART");;
    profile*) ARGS=$(q i v "$AUTH");;
    list*|feed*) ARGS=$(q i v l o);;
    tag*) ARGS=$(q i v l o "(SELECT t.name FROM tags t ORDER BY t.id OFFSET (s % 40) LIMIT 1)");;
    author*) ARGS=$(q i v 5 0 "$AUTH");;
    favorited*) ARGS=$(q i v 5 0 "(SELECT u.username FROM users u WHERE u.id = 1 + s % 100000)");;
    *) echo "unknown kind $K"; exit 1;;
  esac
  psql -X -At -d $DB > $IN <<SQL
SELECT setseed(0.42);
CREATE TEMP TABLE r AS
SELECT b, (row_number() OVER (PARTITION BY b ORDER BY k) - 1)::int4 AS i,
       CASE WHEN random() < 0.2 THEN 0 ELSE 1 + floor(random() * 100000) END::int8 AS v,
       10::int4 AS l, CASE WHEN random() < 0.7 THEN 0 ELSE 10 * (1 + floor(random() * 4)) END::int8 AS o,
       (SELECT max(id) FROM articles) - floor(power(random(), 3) * 20000)::int8 AS s
  FROM generate_series(1, $NB) b, generate_series(1, $B) k;
SELECT 'EXECUTE q(' || concat_ws(', ', $ARGS) || ');' FROM r GROUP BY b ORDER BY b;
SQL
  sed -i '/^EXECUTE/!d' $IN
fi
{
  echo "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0; SET enable_memoize = off;"
  echo "PREPARE q AS $SQL;"
  echo "SELECT pg_backend_pid() AS pid \\gset"
  echo "\\o /dev/null"
  head -20 $IN   # warm-up (plans, caches)
  echo "\\o"
  echo "SELECT utime + stime AS t0 FROM (SELECT (string_to_array(split_part(pg_read_file('/proc/' || :pid || '/stat'), ') ', 2), ' '))[12:13]::int8[] AS x) s, LATERAL (SELECT x[1] AS utime, x[2] AS stime) y \\gset"
  echo "\\o /dev/null"
  cat $IN
  echo "\\o"
  echo "SELECT (utime + stime - :t0) * 10000.0 / ($NB * $B) AS us_per_req FROM (SELECT (string_to_array(split_part(pg_read_file('/proc/' || :pid || '/stat'), ') ', 2), ' '))[12:13]::int8[] AS x) s, LATERAL (SELECT x[1] AS utime, x[2] AS stime) y;"
} > $W/run-${K// /_}.sql
sudo -u postgres psql -X -At -d $DB -f $W/run-${K// /_}.sql 2>&1 | tail -1
