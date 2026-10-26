#!/usr/bin/env python3
"""One fixed-load measurement of one server.

Recreates the `conduit` database from the seed template (a file copy), starts the server with its own start.sh, pinned to
SRV cpus, drives it with the challenge's load generator pinned to LG cpus, and reports, over the steady window:

  * requests/s, p50 / p95 / p99 latency, errors and the load generator's verdict,
  * CPU of the server process group and of ALL postgres processes (backends and background workers), in cores,
  * the same CPU per request in microseconds (cores / requests per second).

Postgres is not touched here: start it however you like (this repo's measurements pin it to cpus 0-5, see README.md) and
point PGHOST/PGUSER/PGPORT at it as for psql. `pg_stat_statements` is optional (it is reset when present).

usage: bench.py --server DIR --users N [--scale S] [--ramp 10] [--measure 40] [--env K=V ...] [--tag NAME]

environment: LOADGEN (path to bench/cmd/loadgen, default `loadgen`), RESULTS (output directory, default ./results),
             DATABASE_URL for the server (default postgres://conduit:conduit@127.0.0.1:5432/conduit).
"""
import argparse, glob, json, os, re, signal, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--server", required=True, help="submission directory containing start.sh")
ap.add_argument("--users", type=int, required=True)
ap.add_argument("--scale", type=float, default=0.5, help="think-time scale (0.5 = twice the request rate per user)")
ap.add_argument("--ramp", type=int, default=10)
ap.add_argument("--measure", type=int, default=40)
ap.add_argument("--srv-cpus", default=os.environ.get("SRV_CPUS", "0,6"))
ap.add_argument("--lg-cpus", default=os.environ.get("LG_CPUS", "4,5,10,11"))
ap.add_argument("--template", default="conduit_seed")
ap.add_argument("--articles", type=int, default=500000)
ap.add_argument("--env", action="append", default=[], help="K=V passed to the server (repeatable)")
ap.add_argument("--tag", default="run")
ap.add_argument("--no-fresh", action="store_true", help="keep the current database instead of recreating it")
ap.add_argument("--port", type=int, default=3000)
ap.add_argument("--host", default="127.0.0.1")
a = ap.parse_args()

LOADGEN = os.environ.get("LOADGEN", "loadgen")
RESULTS = os.environ.get("RESULTS", "results")
os.makedirs(RESULTS, exist_ok=True)
SECRET = "multicore-server-challenge"


def sh(cmd):
    return subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True).stdout


def comm_of(pid):
    f = open("/proc/%d/stat" % pid).read()
    return f[f.index("(") + 1:f.rindex(")")], f[f.rindex(")") + 2:].split()


def server_pids(pgid):
    """every process in the server's process group except the launching shell"""
    out = []
    for d in glob.glob("/proc/[0-9]*"):
        try:
            comm, rest = comm_of(int(d.split("/")[-1]))
            if int(rest[2]) == pgid and comm not in ("bash", "sh", "taskset"):
                out.append(int(d.split("/")[-1]))
        except Exception:
            pass
    return out


def postgres_pids():
    out = []
    for d in glob.glob("/proc/[0-9]*"):
        try:
            if open(d + "/comm").read().strip() == "postgres":
                out.append(int(d.split("/")[-1]))
        except Exception:
            pass
    return out


def ticks(pids):
    user = system = 0
    for p in pids:
        try:
            f = open("/proc/%d/stat" % p).read().rsplit(")", 1)[1].split()
            user += int(f[11])
            system += int(f[12])
        except Exception:
            pass
    return user, system


def peak_rss_mb(pids):
    best = 0
    for p in pids:
        try:
            for l in open("/proc/%d/status" % p):
                if l.startswith("VmHWM"):
                    best = max(best, int(l.split()[1]) // 1024)
        except Exception:
            pass
    return best


if not a.no_fresh:
    sh('psql -qc "DROP DATABASE IF EXISTS conduit WITH (FORCE)" -c "CREATE DATABASE conduit TEMPLATE %s STRATEGY FILE_COPY" -d postgres' % a.template)
    sh('psql -qc "CHECKPOINT" -d postgres')
    sh("""psql -d conduit -Atc "SELECT sum(pg_prewarm(oid)) FROM pg_class WHERE relkind IN ('r','i','t') AND relnamespace = 'public'::regnamespace" """)
    sh("sync")
try:
    sh('psql -d conduit -qc "SELECT pg_stat_statements_reset()"')
except Exception:
    pass

senv = dict(os.environ, DATABASE_URL=os.environ.get("DATABASE_URL", "postgres://conduit:conduit@127.0.0.1:5432/conduit"),
            JWT_SECRET=SECRET, HOST=a.host, PORT=str(a.port))
for kv in a.env:
    k, v = kv.split("=", 1)
    senv[k] = v
log = open(os.path.join(RESULTS, "%s.server.log" % a.tag), "w")
srv = subprocess.Popen(["taskset", "-c", a.srv_cpus, "bash", os.path.join(a.server, "start.sh")], env=senv, stdout=log, stderr=log, preexec_fn=os.setsid)
try:
    for _ in range(120):
        if subprocess.run(["curl", "-sf", "-o", "/dev/null", "http://%s:%d/api/tags" % (a.host, a.port)]).returncode == 0:
            break
        time.sleep(0.5)
    else:
        print("server did not become healthy")
        sys.exit(1)
    time.sleep(1)
    out = os.path.join(RESULTS, "%s.json" % a.tag)
    lg = subprocess.Popen(["taskset", "-c", a.lg_cpus, LOADGEN, "run", "-target", "http://%s:%d" % (a.host, a.port),
                           "-users", str(a.users), "-ramp", "%ds" % a.ramp, "-measure", "%ds" % a.measure, "-tail", "5s",
                           "-think-scale", str(a.scale), "-secret", SECRET, "-run-id", a.tag + str(int(time.time())),
                           "-articles", str(a.articles), "-out", out, "-q"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(2 + a.ramp)  # start of the measured window
    sp = server_pids(srv.pid)
    t0 = time.time()
    su0, ss0 = ticks(sp)
    pu0, ps0 = ticks(postgres_pids())
    time.sleep(a.measure)
    t1 = time.time()
    su1, ss1 = ticks(sp)
    pu1, ps1 = ticks(postgres_pids())
    hz = os.sysconf("SC_CLK_TCK")
    dt = t1 - t0
    lg.wait(timeout=180)
    merged = os.path.join(RESULTS, "%s.merged.json" % a.tag)
    subprocess.run([LOADGEN, "merge", "-o", merged, out], capture_output=True, text=True)
    mj = json.load(open(merged))
    ov = mj.get("overall", mj)
    print(json.dumps({k: ov.get(k) for k in ("count", "rps", "p50_ms", "p95_ms", "p99_ms", "error_rate", "errors") if k in ov}))
    print("server utime=%.2f stime=%.2f" % ((su1 - su0) / hz / dt, (ss1 - ss0) / hz / dt))
    print("server cores=%.2f postgres cores=%.2f (of %s)  server peak RSS=%d MB  verdict=%s" % (
        (su1 - su0 + ss1 - ss0) / hz / dt, (pu1 - pu0 + ps1 - ps0) / hz / dt, a.srv_cpus, peak_rss_mb(sp), mj.get("verdict", mj.get("pass"))))
finally:
    try:
        os.killpg(srv.pid, signal.SIGTERM)
    except Exception:
        pass
    time.sleep(0.5)
