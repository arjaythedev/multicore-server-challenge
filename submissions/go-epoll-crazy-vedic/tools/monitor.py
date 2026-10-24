#!/usr/bin/env python3
"""Sample application, PostgreSQL, and host resource use without extra packages."""
import csv
import glob
import os
import sys
import time
import json
import subprocess

app_pid = int(sys.argv[1])
ticks = os.sysconf("SC_CLK_TCK")


def process(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            fields = f.read().rsplit(")", 1)[1].split()
        return int(fields[11]) + int(fields[12])
    except (OSError, ValueError, IndexError):
        return None


def snapshot():
    with open("/proc/stat") as f:
        cpu = [int(v) for v in f.readline().split()[1:9]]
    pg = {}
    for path in glob.glob("/proc/[0-9]*/comm"):
        try:
            with open(path) as f:
                if f.read().strip() != "postgres":
                    continue
            pid = int(path.split("/")[2])
            value = process(pid)
            if value is not None:
                pg[pid] = value
        except OSError:
            pass
    return time.time(), cpu, process(app_pid), pg


writer = csv.writer(sys.stdout)
writer.writerow(["unix_s", "host_cpu_percent", "app_cpu_cores", "postgres_cpu_cores", "app_rss_mb", "mem_available_mb"])
wait_file = open(sys.argv[3],"a") if len(sys.argv)>3 else None
previous = snapshot()
while previous[2] is not None:
    time.sleep(1)
    current = snapshot()
    if current[2] is None:
        break
    elapsed = current[0] - previous[0]
    total = sum(current[1]) - sum(previous[1])
    idle = sum(current[1][3:5]) - sum(previous[1][3:5])
    app = (current[2] - previous[2]) / ticks / elapsed
    pg = sum(value - previous[3].get(pid, value) for pid, value in current[3].items()) / ticks / elapsed
    rss = available = 0
    try:
        with open(f"/proc/{app_pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    rss = int(line.split()[1]) / 1024
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    available = int(line.split()[1]) / 1024
    except OSError:
        break
    writer.writerow([f"{current[0]:.3f}", f"{100*(total-idle)/max(1,total):.2f}", f"{app:.3f}", f"{pg:.3f}", f"{rss:.2f}", f"{available:.2f}"])
    sys.stdout.flush()
    if wait_file is not None:
        query = "SELECT coalesce(json_agg(x),'[]'::json) FROM (SELECT application_name,state,wait_event_type,wait_event,extract(epoch FROM clock_timestamp()-query_start) AS query_age_s,pg_blocking_pids(pid) AS blockers FROM pg_stat_activity WHERE application_name LIKE 'conduit-go-zenithvedic%' AND datname=current_database()) x"
        try:
            result = subprocess.run(["psql","-X","-qAt","-d",sys.argv[2],"-c",query],capture_output=True,text=True,timeout=2,check=True)
            sample = {"unix_s":time.time(),"sessions":json.loads(result.stdout)}
        except (subprocess.SubprocessError,ValueError) as error:
            sample = {"unix_s":time.time(),"sampler_error":type(error).__name__}
        wait_file.write(json.dumps(sample)+"\n"); wait_file.flush()
    previous = current
