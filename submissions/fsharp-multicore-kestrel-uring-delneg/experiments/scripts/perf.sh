#!/usr/bin/env bash
# perf.sh <label> <envfile>: a screen with perf maps on; 30 s of perf record (app process, call graphs) in the
# measure window; top symbols to /root/mc/screens/<label>/perf.txt. Profiling costs CPU: the screen numbers of
# this run are not comparable to others.
L=$1; ENVF=$2
T=/root/mc/env/perf-$L.env; { cat $ENVF; echo DOTNET_PerfMapEnabled=1; } > $T
/root/mc/screen.sh fsharp-multicore-kestrel-uring-delneg $L 6000 0.1 $T &
S=$!
sleep 100
P=$(pgrep -x Server)
perf record -F 499 -g -p $P -o /tmp/perf-$L.data -- sleep 30 > /dev/null 2>&1
wait $S
perf report -i /tmp/perf-$L.data --no-children --sort comm,dso,sym --stdio 2>/dev/null | grep -v "^#" | grep "%" | head -80 > /root/mc/screens/$L/perf.txt
perf report -i /tmp/perf-$L.data --no-children --sort dso --stdio 2>/dev/null | grep "%" | head -20 >> /root/mc/screens/$L/perf.txt
echo "perf $L: $(wc -l < /root/mc/screens/$L/perf.txt) lines"
