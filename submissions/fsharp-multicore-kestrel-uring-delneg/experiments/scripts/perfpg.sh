#!/usr/bin/env bash
# perfpg.sh <label> <envfile>: a screen; 30 s of perf record over every postgres process in the measure window;
# top symbols to /root/mc/screens/<label>/perfpg.txt (numbers of this run are not comparable to others).
L=$1; ENVF=$2
/root/mc/screen.sh fsharp-multicore-kestrel-uring-delneg $L 6000 0.1 $ENVF &
S=$!
sleep 100
perf record -F 499 -g -p "$(pgrep -d, -x postgres)" -o /tmp/perfpg-$L.data -- sleep 30 > /dev/null 2>&1
wait $S
perf report -i /tmp/perfpg-$L.data --no-children --sort sym --stdio 2>/dev/null | grep -v "^#" | grep "%" | head -70 > /root/mc/screens/$L/perfpg.txt
perf report -i /tmp/perfpg-$L.data --children --sort sym --stdio -g none 2>/dev/null | grep -v "^#" | grep "%" | head -70 >> /root/mc/screens/$L/perfpg.txt
echo "perfpg $L: $(wc -l < /root/mc/screens/$L/perfpg.txt) lines"
