#!/usr/bin/env bash
# feed count proof (FEED_PROOF) in replay: timing at batch 16/33/64 and a row diff vs the current feed statement
set -uo pipefail
F=/root/mc/sql-proof.sql
A=$(awk "/^-- feed packed/{f=1;next} /^-- /{f=0} f" /root/mc/sql-oldest.sql | sed "/^$/d")
B=$(printf "%s" "$A" | sed "s/), c AS MATERIALIZED (SELECT q.i, CASE WHEN EXISTS/), h AS MATERIALIZED (SELECT ARRAY(SELECT t.a FROM (SELECT f.a FROM q, unnest(q.fl) AS f(a) GROUP BY f.a HAVING count(*) >= 2 ORDER BY count(*) DESC LIMIT 8) t WHERE EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = t.a OFFSET 999 LIMIT 1)) AS ha), c AS MATERIALIZED (SELECT q.i, CASE WHEN q.fl \&\& (SELECT ha FROM h) THEN 1000::int8 WHEN EXISTS/")
[ "$A" != "$B" ] || { echo "sed did not apply"; exit 1; }
printf -- "-- feed packed\n%s\n\n-- feedp packed\n%s\n" "$A" "$B" > $F
for b in 16 33 64; do /root/mc/replay.sh $F "feed packed" 200 $b conduit_seed > /dev/null; done   # warm + inputs
for r in 1 2; do for b in 16 33 64; do
  a=$(/root/mc/replay.sh $F "feed packed" 200 $b conduit_seed | tail -1)
  p=$(/root/mc/replay.sh $F "feedp packed" 200 $b conduit_seed | tail -1)
  echo "proof r$r b$b feed: $a | feedp: $p"
done; done
IN=/tmp/replay/in-conduit_seed-feed-200-33.sql
for k in A B; do
  { echo "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0; SET enable_memoize = off;"
    if [ $k = A ]; then echo "PREPARE q(int4[], int8[], int4[], int8[]) AS $A;"; else echo "PREPARE q(int4[], int8[], int4[], int8[]) AS $B;"; fi
    head -60 $IN; } | psql -X -q -At -d conduit_seed > /tmp/proof-$k.out 2>&1
done
echo "proof diff rows: A $(wc -l < /tmp/proof-A.out) B $(wc -l < /tmp/proof-B.out) differ $(diff /tmp/proof-A.out /tmp/proof-B.out | grep -c "^<")"
grep -m2 -i error /tmp/proof-B.out
