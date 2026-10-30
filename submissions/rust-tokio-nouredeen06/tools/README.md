# Local reproduction

The user reported a crash after earlier stress testing, then explicitly requested
a test within the laptop's resource limits. Use only the guarded laptop helper
below for that measurement. The unrestricted setup, seed, clone and load commands
later in this document are retained for a separate test machine.

These tools are for development only. The submitted server starts from start.sh
and reads the challenge environment variables without Docker or these helpers.

## Bounded correctness checks

The user now allows tests when resource headroom is available. On this laptop use:

```sh
bash tools/bounded-check.sh cargo test --offline --locked --bin conduit -- --test-threads=1
bash tools/bounded-check.sh cargo clippy --offline --locked --all-targets -- -D warnings
bash tools/check-writes.sh
bash tools/check-conformance.sh
```

Run one command at a time. `bounded-check.sh` requires at least 8 GiB available
RAM and low memory pressure, and verifies cgroup v2 limits before starting. It
caps descendants at half of one CPU core, 1.5 GiB memory, zero swap and 64 tasks,
with a ten-minute deadline. Compilation uses one Cargo job. It requires a working
user systemd manager with delegated CPU/memory controllers; failure is an error,
never a reason to rerun the command without limits.

Docker containers do not inherit that budget. `check-writes.sh` therefore gives
its temporary PostgreSQL fixture a separate 0.25-CPU / 384-MiB cap and uses only
a few dozen rows. `check-conformance.sh` uses 0.25 CPU / 768 MiB for PostgreSQL,
builds a debug app and the unchanged official suite, loads and fingerprints the
official dev seed, and runs the 197 checks. Host-side fixture files stay under .local.
Both fixtures require the pinned PostgreSQL image to be present locally, use
ephemeral tmpfs data, and clean up on completion. They do not test power-loss
durability and must not be used for throughput claims. No original benchmark
container, volume, host setting or unrelated service is modified.

The resource limit caps each check's consumption; it is not an unconditional
guarantee about other applications or the whole laptop.

## Guarded laptop measurement

`laptop-load.py` is specific to this workstation's systemd/cgroup v2 setup,
NVMe device and existing full-seed PostgreSQL volume. It uses the unchanged
load generator in `.local/loadgen` and the existing release application binary:

```sh
python3 tools/laptop-load.py --output .local/laptop-load-unique-run
```

It requires at least 16 GiB available RAM, low starting memory pressure and five
consecutive CPU-temperature samples below 80 C. The NVMe composite temperature
must also be more than 4 C below the lower of its reported high/critical limits.
PostgreSQL gets four CPU cores,
8 GiB memory and disk bandwidth capped at 128 MiB/s reads and 64 MiB/s writes.
The application and generator share a separate four-core / 2-GiB budget. Both
groups have zero swap and task limits. The helper verifies kernel cgroup limits.
`--disk-read-mib` and `--disk-write-mib` can lower the bandwidth caps; their
defaults are also the maximum accepted values. Lower caps increase clone time
and can affect the measured result, so they are recorded in the run plan.

An independent watchdog samples once per second. It stops its own test processes
if available RAM falls below 8 GiB, temperature reaches 95 C once or remains at
least 90 C for eight samples, its scheduling stalls, or a test group approaches
its nonreclaimable-memory limit / reports OOM. Sustained CPU pressure, memory
pressure with less than 12 GiB headroom, or I/O pressure with at least 80% actual
device utilization also stop the test. I/O throttling can itself produce I/O and
dirty-page memory PSI with abundant free RAM and an idle disk; those signals are
therefore paired with headroom/utilization, while hard caps remain unconditional.
The watchdog also stops if the NVMe composite temperature reaches 1 C below the
lower of its reported high/critical limits, or if its sensor becomes unavailable.
On this laptop the starting threshold is 70.85 C and the stop threshold 73.85 C.

Each session now starts from a disposable Btrfs reflink of the stopped PostgreSQL
volume. The source is mounted read-only; `cp --reflink=always` must succeed, with
no fallback to bulk copying. The copy helper is limited to 0.5 CPU / 128 MiB.
This avoids the large database-copy writes that caused I/O stalls during the
initial performance-mode attempts. PostgreSQL continues to use persistent disk,
fsync, synchronous commit and the unchanged challenge configuration.

Probes use a 20-second ramp, 60-second measurement and 10-second tail. A search
shares its disposable database between stages, accumulating writes as the
upstream search does. Each stage has a unique generator run ID. This differs
from the earlier helper, which created a fresh database for every stage; the
strategy is recorded in the run plan. It steps through 1k, 4k, 8k, 12k, 16k and 20k
virtual users, stopping on a failed verdict or a limited generator, with a midpoint
probe if appropriate. The highest passing load then gets a 60-second ramp and
300-second measurement. `--confirm-users N` runs only that longer measurement.
Think-scale remains 0.1; do not multiply virtual users into an official score.

The original container stays stopped. A temporary capped container uses only the
new snapshot volume. Normal completion stops its processes and removes that
volume; `snapshot-cleanup.json` records whether removal succeeded. A protective
interruption may leave the disposable snapshot if I/O delays container shutdown;
inspect only that named snapshot, never remove the source seed volume. The
underlying `bench.py --existing-database` option is intended only for a caller-owned
disposable snapshot; its caller owns cleanup. Results include the binary hash, raw load-generator
data, per-process statistics, cgroup limits and host monitoring. These shared-host
results measure the chosen budget, not unrestricted server capacity or an
official challenge score.

## Isolated PostgreSQL and benchmark tools

From this submission directory:

```sh
bash tools/setup-local.sh --all
source /tmp/nouredeen-challenge/env.sh
```

Requires Docker and Go 1.27 or newer. The script creates a dedicated container,
persistent volume and loopback port 55432. The PostgreSQL 18 image is pinned by
its digest. Configuration matches the challenge's pgtune formulas for 8 CPUs and
16 GB. Existing seed databases are preserved; the official seed scripts create
missing dev/full seeds and verify their fingerprints. No CPU affinity, host
sysctls, or unrelated services are changed. LOCAL_DIR, PG_CONTAINER, PG_VOLUME and
LOCAL_PGPORT can select a separate local instance. Keep LOCAL_DIR consistent when
reusing a container because the container bind-mounts its configuration file.

The host's CPUs are unrestricted by this setup. App, PostgreSQL and generator
share the local machine, so its results cannot be called official challenge
scores or directly compared with the leaderboard.

## Baseline and candidate

```sh
bash build.sh
CARGO_TARGET_DIR="$PWD/target-baseline" bash ../rust-tokio-Scooter1337/build.sh
python3 tools/bench.py --binary target-baseline/release/conduit \
  --loadgen /tmp/nouredeen-challenge/loadgen --pg-container nouredeen-challenge-pg18 \
  --env BCRYPT_THREADS=1 --users 18000 --output .local/results/baseline
python3 tools/bench.py --binary target/release/conduit \
  --loadgen /tmp/nouredeen-challenge/loadgen --pg-container nouredeen-challenge-pg18 \
  --users 18000 --output .local/results/candidate
python3 tools/summarize.py .local/results/baseline .local/results/candidate
```

Each benchmark creates a fresh copy of `conduit_seed`, starts the selected binary,
waits for health, runs the unchanged upstream load generator, merges its results,
and removes its server process/database. Default timings are a 15 s ramp, 45 s
measurement and 5 s tail, with think-scale 0.1. This accelerates think times and
sessions but does not simulate the socket/memory costs of ten times as many users.
Use `--ramp 60s --measure 300s --tail 15s` for a longer run, or `--think-scale 1`
for the ordinary user model. Do not run timing experiments concurrently.

The server defaults in the harness model the submission's 8-CPU settings. Repeat
`--env KEY=VALUE` to compare process options. It raises only its inherited process
file limit to match the official LimitNOFILE=200000. Check the host's available
client ports before testing large populations on one loopback address.
The colocated Go generator uses four scheduler workers by default; set
`--loadgen-procs` to change this. Earlier recorded probes used the host default
of 20. This process setting is recorded, and runs flagged `lg_limited` must never
be interpreted as server capacity. Cleanup failures are recorded without losing
completed measurement files.

Output contains raw upstream histograms, merged endpoint/timeline results, server
logs, sampled app/PG CPU and app RSS, settings, and binary SHA-256. Summaries use
only samples within the measured window. Keep raw files under the ignored .local
folder; copy selected summaries into a report with the environment and limitations.

## Correctness and query timing

```sh
PORT=3111 bash ../../test/run.sh "$PWD"
TEMPLATE=conduit_seed PORT=3111 bash ../../test/run.sh "$PWD"
cargo test --release --locked
cargo clippy --locked --all-targets -- -D warnings
python3 tools/sql_list_bench.py --database conduit_seed \
  --baseline ../rust-tokio-Scooter1337
python3 tools/sql_count_bench.py --database conduit_seed \
  --baseline ../rust-tokio-Scooter1337
```

The SQL comparison checks both directions with EXCEPT ALL in one snapshot. Timing
uses alternating prepared generic plans, discards the first three executions,
and reports medians and shared-buffer accesses. It measures the query, not the
whole service or an official score.

`regression.py` operates through HTTP and creates its own fixture users, articles,
follows, favorites and comments. Run it against a disposable cloned database:

```sh
psql -d postgres -c 'CREATE DATABASE conduit_regression_local TEMPLATE conduit_dev'
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:55432/conduit_regression_local \
  HOST=127.0.0.1 PORT=3111 APP_THREADS=2 DB_CONNS=1 DB_WRITE_CONNS=1 \
  READ_BATCH_US=3000 WRITE_BATCH_US=3000 BATCH_TRACE=1 bash start.sh
# In another shell:
python3 tools/regression.py --base http://127.0.0.1:3111
```

The delays force concurrent requests into shared SQL executions. Repeat with normal
settings. Stop that server and drop only its disposable database when finished.
`target/release/group-check` is an inherited database-driver test; point DATABASE_URL
at the disposable database. It checks packed-query ordering, error draining,
connection reuse and fresh READ COMMITTED snapshots between statements.

To release local database memory while retaining seed data:

```sh
docker stop nouredeen-challenge-pg18
# Later, rerun setup-local.sh to reconstruct helpers and start it again.
```
