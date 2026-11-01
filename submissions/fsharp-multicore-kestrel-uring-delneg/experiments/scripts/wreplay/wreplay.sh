#!/usr/bin/env bash
# wreplay.sh <batch> [n=4800] [seed=0.1] [db=conduit_seed]: favorite writes as the app sends them, backend CPU per request.
# batch 1: per request one pipeline (insert, article read, Sync = one transaction); batch B: per B requests one pipeline
# with the batched insert and the batched article read (one transaction, one commit).
set -euo pipefail
B=$1; N=${2:-4800}; SEED=${3:-0.1}; DB=${4:-conduit_seed}; W=/tmp/wreplay; mkdir -p $W
D=/root/mc/wr
IN=$W/in-$B-$N-$SEED.txt
psql_in() { sudo -u postgres psql -X -At -d $DB "$@"; }
psql_in > $IN <<SQL
SELECT setseed($SEED);
CREATE TEMP TABLE r0 AS SELECT g, (1 + floor(random() * 100000))::int8 AS v,
  (SELECT max(id) FROM articles) - floor(power(random(), 3) * 20000)::int8 AS s FROM generate_series(1, $N) g;
CREATE TEMP TABLE r AS SELECT g, (g - 1) / $B AS b, ((g - 1) % $B)::int4 AS i, v,
  (SELECT a.slug FROM articles a WHERE a.id <= r0.s ORDER BY a.id DESC LIMIT 1) AS k FROM r0;
SELECT CASE WHEN $B = 1 THEN
  E'\\\\startpipeline\n\\\\bind_named fav ' || v || ' ' || quote_literal(k) || E' \\\\g\n\\\\bind_named art ' || v || ' ' || quote_literal(k) || E' \\\\g\n\\\\endpipeline'
ELSE NULL END FROM r WHERE $B = 1 ORDER BY g;
SELECT E'\\\\startpipeline\n\\\\bind_named favb ' || quote_literal(array_agg(v ORDER BY i)::text) || ' ' || quote_literal(array_agg(k ORDER BY i)::text)
  || E' \\\\g\n\\\\bind_named artb ' || quote_literal(array_agg(i ORDER BY i)::text) || ' ' || quote_literal(array_agg(v ORDER BY i)::text) || ' '
  || quote_literal(array_agg(k ORDER BY i)::text) || E' \\\\g\n\\\\endpipeline'
  FROM r WHERE $B > 1 GROUP BY b ORDER BY b;
SQL
sed -i '/^SELECT\|^$/d; s/ \\g$/ \\sendpipeline/' $IN
CPU="SELECT (x[1] + x[2]) AS x FROM (SELECT (string_to_array(split_part(pg_read_file('/proc/' || pg_backend_pid() || '/stat'), ') ', 2), ' '))[12:13]::int8[] AS x) s"
{
  echo "SET plan_cache_mode = force_generic_plan; SET jit = off; SET enable_memoize = off;"
  echo "INSERT INTO favorites (user_id, article_id) SELECT \$1, a.id FROM articles a WHERE a.slug = \$2 ON CONFLICT DO NOTHING \\parse fav"
  echo "$(cat $D/art1.sql) \\parse art"
  echo "INSERT INTO favorites (user_id, article_id) SELECT r.v, a.id FROM unnest(\$1::int8[], \$2::text[]) AS r(v, k) JOIN articles a ON a.slug = r.k ON CONFLICT DO NOTHING \\parse favb"
  echo "$(cat $D/artb.sql) \\parse artb"
  echo "\\o /dev/null"
  head -$((3 * 20)) $IN
  echo "\\o"
  echo "$CPU \\gset t0_"
  echo "\\o /dev/null"
  cat $IN
  echo "\\o"
  echo "SELECT ($CPU) - :t0_x AS d \\gset"
  echo "SELECT :d * 10000.0 / $N AS us_per_req;"
} | sed 's/\\gset t0_/\\gset t0_/' > $W/run-$B.sql
sudo -u postgres psql -X -At -d $DB -f $W/run-$B.sql 2>&1 | tail -2
