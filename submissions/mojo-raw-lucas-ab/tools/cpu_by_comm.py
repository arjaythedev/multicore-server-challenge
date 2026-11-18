"""CPU ticks per process name (comm), summed over all processes, plus /proc/stat totals, as one JSON line.
Take one snapshot before and one after a run; tools/ab.sh turns the difference into cores.

    python3 tools/cpu_by_comm.py > before.json
"""
import json
import os

ticks = {}
for pid in os.listdir("/proc"):
    if not pid.isdigit():
        continue
    try:
        s = open(f"/proc/{pid}/stat").read()
    except OSError:
        continue
    comm = s[s.index("(") + 1:s.rindex(")")]
    f = s[s.rindex(")") + 2:].split()
    ticks[comm] = ticks.get(comm, 0) + int(f[11]) + int(f[12])  # utime + stime
cpu = list(map(int, open("/proc/stat").readline().split()[1:]))
print(json.dumps({"ticks": ticks, "total": sum(cpu), "idle": cpu[3] + cpu[4], "time": os.times().elapsed}))
