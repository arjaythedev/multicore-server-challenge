#!/usr/bin/env bash
# cmtpl.sh [db] [n=60] [reps=200]: the planner's comments statement over fixed random slug sets (newest-skewed),
# generic plans as the app; backend CPU ms per batch. A = current, B = no final ORDER BY (rows checked in order
# anyway), C = author by LATERAL OFFSET 0, D = no author join (lower bound).
set -euo pipefail
DB=${1:-conduit_seed}; N=${2:-60}; R=${3:-200}
W=/tmp/cmtpl; mkdir -p $W; chmod 777 $W
IN=$W/in-$DB-$N-$R.txt
if [ ! -s $IN ]; then
  sudo -u postgres psql -X -At -d $DB > $IN <<SQL
SELECT setseed(0.42);
SELECT array_agg(DISTINCT a.slug)::text
FROM (SELECT b, (SELECT max(id) FROM articles) - floor(power(random(), 3) * 20000)::int8 AS s
      FROM generate_series(1, $R) b, generate_series(1, $N) g) x
JOIN articles a ON a.id = x.s GROUP BY x.b ORDER BY x.b;
SQL
  sed -i '/^{/!d' $IN
fi
HEAD="SELECT r.k, a.id, c.id, c.body, c.created_at, c.updated_at, c.author_id"
FROM="FROM unnest(\$1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true"
ORD="ORDER BY r.k, c.created_at DESC, c.id DESC"
A="$HEAD, u.username, u.bio, u.image $FROM LEFT JOIN users u ON u.id = c.author_id $ORD"
B="$HEAD, u.username, u.bio, u.image $FROM LEFT JOIN users u ON u.id = c.author_id"
C="$HEAD, u.username, u.bio, u.image $FROM LEFT JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = c.author_id OFFSET 0) u ON true $ORD"
D="$HEAD, NULL::text, NULL::text, NULL::text $FROM $ORD"
E="WITH c AS MATERIALIZED (SELECT r.k, a.id AS aid, c.id, c.body, c.created_at, c.updated_at, c.author_id $FROM), u AS MATERIALIZED (SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.id = ANY (ARRAY(SELECT DISTINCT c.author_id FROM c WHERE c.author_id IS NOT NULL))) SELECT c.k, c.aid, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image FROM c LEFT JOIN u ON u.id = c.author_id ORDER BY c.k, c.created_at DESC, c.id DESC"
STAT="(string_to_array(split_part(pg_read_file('/proc/' || :pid || '/stat'), ') ', 2), ' '))[12:13]::int8[]"
ex() { awk '{print "EXECUTE q('\''" $0 "'\'');"}' "$@"; }
run() {
  local f=$W/run-$1.sql
  { echo "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0; SET enable_memoize = off;"
    echo "PREPARE q(text[]) AS $2;"
    echo "SELECT pg_backend_pid() AS pid \\gset"
    echo "\\o /dev/null"; head -10 $IN | ex; echo "\\o"
    echo "SELECT x[1] + x[2] AS t0 FROM (SELECT $STAT AS x) s \\gset"
    echo "\\o /dev/null"; ex $IN; echo "\\o"
    echo "SELECT round((x[1] + x[2] - :t0) * 10.0 / $R, 2) AS ms_per_batch FROM (SELECT $STAT AS x) s;"
  } > $f
  echo "$1: $(sudo -u postgres psql -X -At -d $DB -f $f 2>&1 | tail -1) ms/batch"
}
if [ "${U:-0}" = 1 ]; then
  # U: comment authors as one users-by-id statement (distinct, sorted ids), timed alone; D + U vs A
  UIN=$W/uin-$DB-$N-$R.txt
  awk '{print "SELECT coalesce(array_agg(DISTINCT c.author_id ORDER BY c.author_id), '\''{}'\'')::text FROM unnest('\''" $0 "'\''::text[]) r(slug) JOIN articles a ON a.slug = r.slug CROSS JOIN LATERAL (SELECT c.author_id FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c;"}' $IN > $W/uin.sql
  sudo -u postgres psql -X -At -d $DB -f $W/uin.sql > $UIN
  echo "authors per batch: $(awk -F, '{s+=NF} END {printf "%.0f", s/NR}' $UIN)"
  runu() {
    local f=$W/run-$1.sql
    { echo "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0;"
      echo "PREPARE q(int8[]) AS $2;"
      echo "SELECT pg_backend_pid() AS pid \\gset"
      echo "\\o /dev/null"; head -10 $UIN | ex; echo "\\o"
      echo "SELECT x[1] + x[2] AS t0 FROM (SELECT $STAT AS x) s \\gset"
      echo "\\o /dev/null"; ex $UIN; echo "\\o"
      echo "SELECT round((x[1] + x[2] - :t0) * 10.0 / $R, 2) AS ms_per_batch FROM (SELECT $STAT AS x) s;"
    } > $f
    echo "$1: $(sudo -u postgres psql -X -At -d $DB -f $f 2>&1 | tail -1) ms/batch"
  }
  for r in 1 2 3; do run A "$A"; run D "$D"; runu U "SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.id = ANY (\$1)"; done
  exit 0
fi
# B's and E's rows equal A's, in order?
{ echo "SET plan_cache_mode = force_generic_plan; SET jit = off; SET enable_memoize = off;"
  echo "PREPARE a(text[]) AS $A;"; echo "PREPARE b(text[]) AS $B;"; echo "PREPARE e(text[]) AS $E;"
  head -20 $IN | awk '{print "\\o /tmp/cmtpl/a.out\nEXECUTE a('\''" $0 "'\'');\n\\o /tmp/cmtpl/b.out\nEXECUTE b('\''" $0 "'\'');\n\\o /tmp/cmtpl/e.out\nEXECUTE e('\''" $0 "'\'');\n\\o\n\\! cmp -s /tmp/cmtpl/a.out /tmp/cmtpl/b.out || echo B-DIFF\n\\! cmp -s /tmp/cmtpl/a.out /tmp/cmtpl/e.out || echo E-DIFF"}'
} > $W/ord.sql
sudo -u postgres psql -X -At -d $DB -f $W/ord.sql > $W/ord.out 2>&1
echo "order check: B $(grep -c B-DIFF $W/ord.out), E $(grep -c E-DIFF $W/ord.out) of 20 batches differ; errors $(grep -c ERROR $W/ord.out); rows/batch $(wc -l < $W/a.out)"
for r in 1 2 3; do run A "$A"; run B "$B"; run E "$E"; run D "$D"; done
