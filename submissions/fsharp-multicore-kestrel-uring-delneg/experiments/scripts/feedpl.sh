#!/usr/bin/env bash
# feedpl.sh [db] [pages=44] [reps=100]: the planner's feed statement over fixed random batches (viewers who follow
# someone; limit 10, offset 0 (70%) or 10-40), generic plans as the app; backend CPU ms per batch.
# P0 = current (count proof h), P1 = + #102's page cutoff (the batch's 8 most shared followees' (limit+offset)-th
# newest id bounds each followee scan), C = counts only (no pages), rows checked equal P0 vs P1.
set -euo pipefail
DB=${1:-conduit_seed}; N=${2:-44}; R=${3:-100}
W=/tmp/feedpl; mkdir -p $W; chmod 777 $W
IN=$W/in-$DB-$N-$R.txt
if [ ! -s $IN ]; then
  sudo -u postgres psql -X -At -d $DB > $IN <<SQL
SELECT setseed(0.42);
CREATE TEMP TABLE fv AS SELECT row_number() OVER () AS n, follower_id AS v FROM (SELECT DISTINCT follower_id FROM follows) s;
CREATE TEMP TABLE r0 AS SELECT b, g, 1 + floor(random() * (SELECT count(*) FROM fv))::int8 AS idx,
  10::int8 AS l, CASE WHEN random() < 0.7 THEN 0 ELSE 10 * (1 + floor(random() * 4)) END::int8 AS o
  FROM generate_series(1, $R) b, generate_series(1, $N) g;
CREATE TEMP TABLE r AS SELECT r0.b, r0.g, fv.v, r0.l, r0.o FROM r0 JOIN fv ON fv.n = r0.idx;
SELECT (SELECT array_agg(DISTINCT v)::text FROM r r2 WHERE r2.b = r.b) || '|' || array_agg(v ORDER BY g)::text || '|' || array_agg(l ORDER BY g)::text || '|' || array_agg(o ORDER BY g)::text FROM r GROUP BY b ORDER BY b;
SQL
  sed -i '/|/!d' $IN
fi
PAD="NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz"
COLS="a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at"
Q="WITH q AS MATERIALIZED (SELECT r.k, r.v, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fl FROM unnest(\$1::int8[]) WITH ORDINALITY r(v, k)), h AS MATERIALIZED (SELECT ARRAY(SELECT t.a FROM (SELECT f.a FROM q, unnest(q.fl) AS f(a) GROUP BY f.a HAVING count(*) >= 2 ORDER BY count(*) DESC LIMIT 8) t WHERE EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = t.a OFFSET 999 LIMIT 1)) AS ha)"
CNT="SELECT -q.k, CASE WHEN q.fl && (SELECT ha FROM h) THEN 1000::int8 WHEN EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY (q.fl) ORDER BY a3.author_id, a3.id DESC OFFSET 999 LIMIT 1) THEN 1000::int8 ELSE (SELECT count(*) FROM articles a3 WHERE a3.author_id = ANY (q.fl)) END, $PAD FROM q"
PG0="SELECT p.k, $COLS FROM unnest(\$2::int8[], \$3::int8[], \$4::int8[]) WITH ORDINALITY p(v, lim, off, k) JOIN q ON q.v = p.v CROSS JOIN LATERAL (SELECT * FROM (SELECT y.id FROM unnest(q.fl) AS f(a) CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = f.a ORDER BY a3.id DESC LIMIT (p.lim + p.off)) y ORDER BY y.id DESC LIMIT p.lim OFFSET p.off) x0 LIMIT 100) x CROSS JOIN LATERAL (SELECT a.* FROM articles a WHERE a.id = x.id OFFSET 0) a"
BND=", pv AS MATERIALIZED (SELECT p.k, p.v, p.lim, p.off, q.fl FROM unnest(\$2::int8[], \$3::int8[], \$4::int8[]) WITH ORDINALITY p(v, lim, off, k) JOIN q ON q.v = p.v), bd AS MATERIALIZED (SELECT b.a, (SELECT a3.id FROM articles a3 WHERE a3.author_id = b.a ORDER BY a3.id DESC OFFSET b.take - 1 LIMIT 1) AS cut FROM (SELECT f.a, max(pv.lim + pv.off) AS take FROM pv, unnest(pv.fl) AS f(a) GROUP BY f.a HAVING count(*) >= @H@ ORDER BY count(*) DESC LIMIT @L@) b)"
PG1="SELECT p.k, $COLS FROM pv p CROSS JOIN LATERAL (SELECT coalesce(max(bd.cut), 0) AS cut FROM bd WHERE bd.a = ANY (p.fl)) c CROSS JOIN LATERAL (SELECT * FROM (SELECT y.id FROM unnest(p.fl) AS f(a) CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = f.a AND a3.id >= c.cut ORDER BY a3.id DESC LIMIT (p.lim + p.off)) y ORDER BY y.id DESC LIMIT p.lim OFFSET p.off) x0 LIMIT 100) x CROSS JOIN LATERAL (SELECT a.* FROM articles a WHERE a.id = x.id OFFSET 0) a"
STAT="(string_to_array(split_part(pg_read_file('/proc/' || :pid || '/stat'), ') ', 2), ' '))[12:13]::int8[]"
ex() { awk -F'|' '{print "EXECUTE q('\''" $1 "'\'', '\''" $2 "'\'', '\''" $3 "'\'', '\''" $4 "'\'');"}' "$@"; }
run() { # name, sql
  local f=$W/run-$1.sql
  { echo "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0; SET enable_memoize = off;"
    echo "PREPARE q(int8[], int8[], int8[], int8[]) AS $2;"
    echo "SELECT pg_backend_pid() AS pid \\gset"
    echo "\\o /dev/null"; head -10 $IN | ex; echo "\\o"
    echo "SELECT x[1] + x[2] AS t0 FROM (SELECT $STAT AS x) s \\gset"
    echo "\\o /dev/null"; ex $IN; echo "\\o"
    echo "SELECT round((x[1] + x[2] - :t0) * 10.0 / $R, 2) AS ms_per_batch FROM (SELECT $STAT AS x) s;"
  } > $f
  echo "$1: $(sudo -u postgres psql -X -At -d $DB -f $f 2>&1 | tail -1) ms/batch"
}
# equality of rows P0 vs P1 over the first 30 batches
eq() {
  local d=0
  head -30 $IN | while IFS='|' read -r a b c e; do
    printf "SET plan_cache_mode = force_generic_plan;\nPREPARE a(int8[], int8[], int8[], int8[]) AS $Q $CNT UNION ALL $PG0;\nPREPARE b(int8[], int8[], int8[], int8[]) AS $Q $BND $CNT UNION ALL $PG1;\n\\\\o /tmp/feedpl/a.out\nEXECUTE a('%s','%s','%s','%s');\n\\\\o /tmp/feedpl/b.out\nEXECUTE b('%s','%s','%s','%s');\n" "$a" "$b" "$c" "$e" "$a" "$b" "$c" "$e" > $W/eq.sql
    sudo -u postgres psql -X -At -d $DB -f $W/eq.sql > /dev/null 2>&1
    if ! cmp -s <(sort $W/a.out) <(sort $W/b.out); then echo "DIFF in batch"; fi
  done
  echo "eq check done ($(wc -l < $W/a.out) rows in last batch)"
}
bnd() { local x="${BND0//@H@/$1}"; echo "${x//@L@/$2}"; }
BND0="$BND"; BND=$(bnd 2 8); eq; BND=$(bnd 1 1000); eq
for r in 1 2 3; do
  run P0 "$Q $CNT UNION ALL $PG0"
  for hl in "2 8" "2 32" "1 64" "1 1000"; do run "P1-${hl// /-}" "$Q $(bnd $hl) $CNT UNION ALL $PG1"; done
done
