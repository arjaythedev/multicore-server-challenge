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
# B's row order equals A's?
{ echo "SET plan_cache_mode = force_generic_plan; SET jit = off; SET enable_memoize = off;"
  echo "PREPARE a(text[]) AS $A;"; echo "PREPARE b(text[]) AS $B;"
  head -20 $IN | awk '{print "\\o /tmp/cmtpl/a.out\nEXECUTE a('\''" $0 "'\'');\n\\o /tmp/cmtpl/b.out\nEXECUTE b('\''" $0 "'\'');\n\\! cmp -s /tmp/cmtpl/a.out /tmp/cmtpl/b.out || echo ORDER-DIFF"}'
} > $W/ord.sql
echo "order check: $(sudo -u postgres psql -X -At -d $DB -f $W/ord.sql 2>&1 | grep -c ORDER-DIFF) of 20 batches differ; rows/batch $(wc -l < $W/a.out)"
for r in 1 2 3; do run A "$A"; run B "$B"; run C "$C"; run D "$D"; done
