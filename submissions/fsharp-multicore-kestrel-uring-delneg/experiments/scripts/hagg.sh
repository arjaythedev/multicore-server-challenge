#!/usr/bin/env bash
# hashagg A/B in replay: each kind at its observed batch size, default vs enable_hashagg=off, two rounds
F=/root/mc/sql-oldest.sql
for r in 1 2; do
for kb in "feed packed:33" "author packed:15" "tag packed:14" "article:59" "comments:59" "list packed:42"; do
  k=${kb%%:*}; b=${kb##*:}
  a=$(/root/mc/replay.sh $F "$k" 200 $b conduit_seed | tail -1)
  o=$(EXTRA_SET="SET enable_hashagg = off;" /root/mc/replay.sh $F "$k" 200 $b conduit_seed | tail -1)
  echo "r$r $k b$b on: $a | hagg0: $o"
done; done
