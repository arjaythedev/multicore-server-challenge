#!/usr/bin/env bash
# Runs jobs from /root/mc/queue.txt one at a time (first line first); idle polling when empty. Log: /root/mc/queue.log
Q=/root/mc/queue.txt; touch $Q
while :; do
  line="$(head -1 $Q)"
  if [ -z "$line" ]; then sleep 5; continue; fi
  sed -i '1d' $Q
  echo "[$(date +%T)] START $line" >> /root/mc/queue.log
  bash -c "$line" >> /root/mc/queue.log 2>&1
  echo "[$(date +%T)] END rc=$? $line" >> /root/mc/queue.log
done
