#!/usr/bin/env bash
# perfcomm.sh <label>...: per-thread and per-dso share of app samples from /tmp/perf-<label>.data
for L in "$@"; do echo "== $L"; perf report -i /tmp/perf-$L.data --no-children --sort comm --stdio 2>/dev/null | grep -E "^ +[0-9.]+%" | head -12 > /root/mc/screens/$L/comm.txt; cat /root/mc/screens/$L/comm.txt; done
