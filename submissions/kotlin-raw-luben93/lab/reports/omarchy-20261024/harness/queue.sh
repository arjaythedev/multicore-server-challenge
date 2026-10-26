#!/usr/bin/env bash
# Runs the follow-up chains strictly one after another, after chain2 (native official search) ends.
H=/home/luben/code/UC/.tmp/mcsc-help
while pgrep -f "$H/chain2.sh" >/dev/null; do sleep 15; done
for c in 6 3 4 5; do echo "=== chain$c $(date +%T)"; bash $H/chain$c.sh > $H/chain$c.log 2>&1; done
echo "=== all done $(date +%T)"
