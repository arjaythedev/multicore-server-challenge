#!/usr/bin/env bash
# per-thread CPU of the native server every 10 s for N samples -> stdout
P=$(pgrep -f conduit.kexe | head -1); N=${1:-30}
s() { for f in /proc/$P/task/*; do awk -v t=$(basename $f) '{print t, $14, $15}' $f/stat 2>/dev/null; done | sort; }
for i in $(seq $N); do
  s > /tmp/ts.a; sleep 10; s > /tmp/ts.b
  echo "== $(date +%T) total $(join /tmp/ts.a /tmp/ts.b | awk '{t+=$4-$2+$5-$3} END{printf "%.0f%%", t*100/1000}')"
  join /tmp/ts.a /tmp/ts.b | awk '{u=$4-$2; y=$5-$3; if(u+y>5) printf "  tid %s user %.0f%% sys %.0f%%\n",$1,u*100/1000,y*100/1000}' | sort -t' ' -k5 -nr | head -6
done; rm -f /tmp/ts.a /tmp/ts.b
