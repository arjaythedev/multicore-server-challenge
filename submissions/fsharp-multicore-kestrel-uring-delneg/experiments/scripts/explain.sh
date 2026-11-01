#!/usr/bin/env bash
# explain.sh <sqlfile> <kind> <B> [db]: EXPLAIN (ANALYZE, BUFFERS) of the 5th replay batch (inputs from replay.sh)
F=$1; K=$2; B=$3; DB=${4:-conduit_seed}; KB=${K%% *}
SQL=$(awk -v k="-- $K" "\$0==k{f=1;next} /^-- /{f=0} f" "$F" | sed "/^$/d")
IN=/tmp/replay/in-$DB-$KB-200-$B.sql; [ -f $IN ] || /root/mc/replay.sh $F "$K" 200 $B $DB > /dev/null
E=$(sed -n 5p $IN | sed "s/^EXECUTE q(//; s/);$//")
{ echo "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0; SET enable_memoize = off;"
  echo "PREPARE q AS $SQL;"; sed -n 1,4p $IN; echo "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) EXECUTE q($E);"; } | psql -X -q -d $DB 2>&1 | grep -v -E "^ *$|^\(|^-+$|^ *(QUERY PLAN|[0-9]+ rows)" | grep -E "Scan|Loop|Buffers|Time|loops|Sort|Hash|Join|Aggregate|CTE" | head -${5:-80}
