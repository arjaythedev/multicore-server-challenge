#!/bin/bash
# feed: one capped id walk for count and page vs count walks + per-followee page; batch 16 and 8, warm-up first
F=/root/mc/sql-feedx.sql
/root/mc/replay.sh $F "feed packed" 100 16 >/dev/null; /root/mc/replay.sh $F "feedx packed" 100 16 >/dev/null
for b in 16 8; do for r in 1 2; do for k in "feed packed" "feedx packed"; do
  echo "b$b r$r $k: $(/root/mc/replay.sh $F "$k" 300 $b)"; done; done; done
