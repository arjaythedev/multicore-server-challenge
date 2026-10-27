#!/usr/bin/env bash
# FEED_PROOF_N in replay: probe 4 / 8 / 16 shared followees, batch 33 and 64
F=/root/mc/sql-proofn.sql
B=$(awk "/^-- feedp packed/{f=1;next} /^-- /{f=0} f" /root/mc/sql-proof.sql | sed "/^$/d")
{ for n in 4 8 16; do echo "-- feedp$n packed"; printf "%s\n\n" "$(printf "%s" "$B" | sed "s/ORDER BY count(\*) DESC LIMIT 8)/ORDER BY count(*) DESC LIMIT $n)/")"; done; } > $F
grep -c "LIMIT 16)" $F
for r in 1 2; do for b in 33 64; do for n in 4 8 16; do
  echo "proofn r$r b$b n$n: $(/root/mc/replay.sh $F "feedp$n packed" 200 $b | tail -1)"
done; done; done
