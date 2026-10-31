#!/usr/bin/env bash
# tag pages: one newest-first walk per distinct tag for count and page vs two walks (replay + row diff)
F=/root/mc/sql-tagw.sql
for b in 14 28; do /root/mc/replay.sh $F "tag packed" 200 $b > /dev/null; /root/mc/replay.sh $F "tagw packed" 200 $b > /dev/null; done
for r in 1 2; do for b in 14 28; do
  echo "tagw r$r b$b tag: $(/root/mc/replay.sh $F "tag packed" 200 $b | tail -1) | tagw: $(/root/mc/replay.sh $F "tagw packed" 200 $b | tail -1)"
done; done
for k in "tag" "tagw"; do
  SQL=$(awk -v k="-- $k packed" "\$0==k{f=1;next} /^-- /{f=0} f" $F | sed "/^$/d")
  { echo "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0; SET enable_memoize = off;"
    echo "PREPARE q AS $SQL;"; head -60 /tmp/replay/in-conduit_seed-tag-200-14.sql; } | psql -X -q -At -d conduit_seed > /tmp/tagw-$k.out 2>&1
done
echo "tagw diff rows: A $(wc -l < /tmp/tagw-tag.out) B $(wc -l < /tmp/tagw-tagw.out) differ $(diff /tmp/tagw-tag.out /tmp/tagw-tagw.out | grep -c "^<")"; grep -m2 -i error /tmp/tagw-tagw.out
