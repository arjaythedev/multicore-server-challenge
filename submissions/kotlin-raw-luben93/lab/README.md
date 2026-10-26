# Lab: big-machine load tests

Runbook for a Claude Code session (or a person) on a machine with more cores and RAM than the cloud container
where this submission is developed. That container has 4 vCPUs and a hard limit of 20,000 file descriptors per
process, so it can only compare designs at low connection counts. This lab reproduces the parts of the scoring box
it can't: **8 cores for the server + Postgres, and 64k-120k real keep-alive connections**.

Report back through git (see "Reporting"); the developing session fetches the `lab-results` branch.

## 1. Machine

Ideal: >= 16 logical CPUs (8 for server + Postgres like the box, the rest for the load generator), >= 32 GB RAM,
root. Record what you have:

```bash
lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Core|Socket|NUMA'; free -g; uname -r; cat /etc/os-release | head -2
```

The box has 8 *vCPUs*. If this machine has SMT, give the server + Postgres 8 logical CPUs that are 4 physical cores
plus their SMT siblings (`lscpu -e` shows the core of each CPU), which is what a cloud vCPU is. Put the load
generator on the other cores. Below, `SRV_CPUS` / `LG_CPUS` are those two sets (e.g. `0-3,16-19` and `4-15,20-31`).

## 2. Setup (once)

Tools: Postgres **18**, Go **>= 1.27** (for the challenge's loadgen/conformance/seed tools; with an older Go set
`GOTOOLCHAIN=auto`), JDK **27** at `/opt/jdk` (Temurin, as `install.sh` would put it), curl, jq, python3, `fuser`
(psmisc), `taskset` and `flock` (util-linux), rustup (only for the Rust baseline). On Arch/Omarchy:

```bash
sudo pacman -S --needed postgresql go jq python psmisc util-linux curl rustup
curl -fsSL 'https://api.adoptium.net/v3/binary/version/jdk-27%2B35/linux/x64/jdk/hotspot/normal/eclipse' -o /tmp/jdk.tgz
sudo rm -rf /opt/jdk && sudo mkdir -p /opt/jdk && sudo tar -C /opt/jdk --strip-components=1 -xzf /tmp/jdk.tgz
/opt/jdk/bin/java -version
```

Postgres: a cluster listening on 127.0.0.1:5432 with scram auth for TCP, configured like the box **for 8 cores and
16 GB** (what `box/pg-conf.sh` prints on the box; don't run that script here, it would size for this machine):

```
max_connections = 100
shared_buffers = 4096MB
effective_cache_size = 12288MB
maintenance_work_mem = 1024MB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
work_mem = 9709kB
huge_pages = try
min_wal_size = 1GB
max_wal_size = 4GB
max_worker_processes = 8
max_parallel_workers = 8
max_parallel_workers_per_gather = 4
max_parallel_maintenance_workers = 4
```

`pg_hba.conf`: `host all all 127.0.0.1/32 scram-sha-256` (and trust/peer for the postgres superuser as you like).
Start Postgres **pinned to SRV_CPUS** so every backend inherits it, or pin afterwards with
`sudo lab/pin-postgres.sh "$SRV_CPUS"` (run it again after a Postgres restart). Then, from the repo root:

```bash
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres          # superuser access for the scripts
bash seed/make-seed.sh --dev && bash seed/make-seed.sh       # conduit_dev, then the full conduit_seed (must print OK)
sudo bash submissions/kotlin-raw-luben93/lab/box-sysctls.sh   # the box's sysctls (re-run after reboot)
```

Run the tests as root, or raise your hard `nofile` limit to >= 1048576 first: the scripts give the server 200000
fds (like the box's systemd unit) and the load generator 1048576.

## 3. Tests

All from the repo root. Each `bench.sh` line prints req/s, p50/p95/p99, errors, app and Postgres CPU (% of one
core, and µs per request), app RSS and fds, pass/fail, and loadgen CPU (`lg_limited=True` means the load generator,
not the server, was the limit: give it more cores). Lines are appended to `lab/results/ALL.txt`; raw run data goes to
`lab/results/runs/` (the repo's .gitignore ignores every `results/` directory, so none of that is committed).

**A. Calibration** (do this first, it tells us how this machine compares with the box). Real think times
(`think-scale 1.0`), users = connections:

```bash
export SRV_CPUS=... LG_CPUS=...
( cd submissions/rust-tokio-Scooter1337 && bash build.sh )
( cd submissions/kotlin-vertx-canleon && bash build.sh )
L=submissions/kotlin-raw-luben93/lab
$L/capacity.sh submissions/rust-tokio-Scooter1337 rust 1.0 32000 64000 90000 120000
$L/capacity.sh submissions/kotlin-vertx-canleon vertx 1.0 16000 32000 46000 64000
```

On the box these scored 100,000 and 46,000 users. Each run takes ~2.5 min plus a 60 s warm-up.

**B. Our server** (once branch `kotlin-raw-luben93` has a commit saying conformance passes; `git pull` first):

```bash
bash test/run.sh submissions/kotlin-raw-luben93          # conformance must say RESULT: PASS
( cd submissions/kotlin-raw-luben93 && bash build.sh )
$L/capacity.sh submissions/kotlin-raw-luben93 kraw-jvm 1.0 32000 64000 90000 120000
```

If the branch also has a native build (see its README), run the same for it with its own tag.

**C. Idle-connection limits**: does the server hold 120k mostly idle connections, and what does each cost?

```bash
( cd lab/connstress 2>/dev/null || cd submissions/kotlin-raw-luben93/lab/connstress; go build -o /tmp/connstress . )
# start the server by hand (HOST=0.0.0.0 PORT=3000 DATABASE_URL=... JWT_SECRET=x, ulimit -n 200000), then:
ulimit -n 1048576; taskset -c "$LG_CPUS" /tmp/connstress -target 127.0.0.1:3000 -n 120000 -rate 4000 -hold 30s -srcs 8
# while it holds: grep VmRSS /proc/<server pid>/status; ls /proc/<pid>/fd | wc -l
```

## 4. Reporting

Write `submissions/kotlin-raw-luben93/lab/reports/<machine>-<YYYYMMDD>.md` with the machine description (section 1
output, which CPUs you used for what), Postgres version, anything you had to change, and every result line (paste
`lab/results/ALL.txt` into it). Commit it on a branch named `lab-results`, branched from `kotlin-raw-luben93`, and
push. Don't push to `kotlin-raw-luben93` itself; that branch is being developed.
