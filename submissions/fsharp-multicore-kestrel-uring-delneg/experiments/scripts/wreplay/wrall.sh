#!/bin/bash
# favorite writes: per request vs batched (one insert + one article read + one commit per batch), two rounds
s=0
for r in 1 2; do for b in 1 4 8 16; do s=$((s+1)); echo "wr b$b r$r: $(/root/mc/wr/wreplay.sh $b 4800 0.$((20+s)))"; done; done
