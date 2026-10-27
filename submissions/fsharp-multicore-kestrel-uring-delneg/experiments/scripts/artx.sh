#!/usr/bin/env bash
# artx.sh [db] [n=700] [reps=100]: planner phase B enrichment variants over fixed random article sets (newest-skewed),
# one backend each, generic plans as the app; prints backend CPU ms per batch. A = names by per-tag subquery (ours),
# B = tag ids (#47) + one tagnames statement, C = names by join, D = tag ids alone (lower bound).
set -euo pipefail
DB=${1:-conduit_seed}; N=${2:-700}; R=${3:-100}
W=/tmp/artx; mkdir -p $W; chmod 777 $W
IN=$W/in-$DB-$N-$R.txt
if [ ! -f $IN ]; then
  sudo -u postgres psql -X -At -d $DB > $IN <<SQL
SELECT setseed(0.42);
SELECT array_agg(a.id)::text || '|' || array_agg(a.author_id)::text
FROM (SELECT b, (SELECT max(id) FROM articles) - floor(power(random(), 3) * 20000)::int8 AS s
      FROM generate_series(1, $R) b, generate_series(1, $N) g) x
JOIN articles a ON a.id = x.s GROUP BY x.b ORDER BY x.b;
SQL
  sed -i '/|/!d' $IN
fi
NAMES_SUB="ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = r.id)"
NAMES_JOIN="ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = r.id)"
IDS="ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = r.id)"
REST="(SELECT count(*) FROM favorites f WHERE f.article_id = r.id), u.username, u.bio, u.image FROM unnest(\$1::int8[], \$2::int8[]) r(id, author) JOIN users u ON u.id = r.author"
TAGN="SELECT t.id, t.name FROM tags t WHERE t.id IN (SELECT at.tag_id FROM article_tags at WHERE at.article_id = ANY (\$1::int8[])) ORDER BY t.name"
STAT="(string_to_array(split_part(pg_read_file('/proc/' || :pid || '/stat'), ') ', 2), ' '))[12:13]::int8[]"
run() { # name, select-list column, with-tagnames(0/1)
  local f=$W/run-$1.sql
  { echo "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0; SET enable_memoize = off;"
    echo "PREPARE q AS SELECT r.id, $2, $REST;"
    [ $3 = 1 ] && echo "PREPARE t AS $TAGN;"
    echo "SELECT pg_backend_pid() AS pid \\gset"
    echo "\\o /dev/null"
    awk -F'|' -v t=$3 'NR<=10{print "EXECUTE q('\''" $1 "'\'', '\''" $2 "'\'');"; if (t==1) print "EXECUTE t('\''" $1 "'\'');"}' $IN
    echo "\\o"
    echo "SELECT x[1] + x[2] AS t0 FROM (SELECT $STAT AS x) s \\gset"
    echo "\\o /dev/null"
    awk -F'|' -v t=$3 '{print "EXECUTE q('\''" $1 "'\'', '\''" $2 "'\'');"; if (t==1) print "EXECUTE t('\''" $1 "'\'');"}' $IN
    echo "\\o"
    echo "SELECT round((x[1] + x[2] - :t0) * 10.0 / $R, 2) AS ms_per_batch FROM (SELECT $STAT AS x) s;"
  } > $f
  echo "$1: $(sudo -u postgres psql -X -At -d $DB -f $f 2>&1 | tail -1) ms/batch"
}
if [ "${SPLIT:-0}" = 1 ]; then
  for r in 1 2 3; do
    run D "$IDS" 0
    REST0="$REST"
    REST="0::int8, u.username, u.bio, u.image FROM unnest(\$1::int8[], \$2::int8[]) r(id, author) JOIN users u ON u.id = r.author"; run D-nofc "$IDS" 0
    REST="(SELECT count(*) FROM favorites f WHERE f.article_id = r.id), NULL::text, NULL::text, NULL::text FROM unnest(\$1::int8[], \$2::int8[]) r(id, author)"; run D-nouser "$IDS" 0
    REST="$REST0"; run D-notags "NULL::int4[]" 0
    REST="(SELECT count(*) FROM favorites f WHERE f.article_id = r.id), u.username, u.bio, u.image FROM unnest(\$1::int8[], \$2::int8[]) r(id, author) JOIN LATERAL (SELECT * FROM users u WHERE u.id = r.author OFFSET 0) u ON true"; run D-latuser "$IDS" 0
    REST="$REST0"
  done
else
for r in 1 2 3; do
  run A "$NAMES_SUB" 0; run B "$IDS" 1; run C "$NAMES_JOIN" 0; run D "$IDS" 0
done
fi
