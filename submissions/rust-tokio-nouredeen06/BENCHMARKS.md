# Measurements and validation

These are local measurements on a shared workstation, not an official challenge
score or proof of the server's maximum capacity. The strongest existing submission
was the starting point; the changes here are incremental. SQL-level improvements
are clear in the paired query experiments. Whole-service throughput differences
in the short probes are small enough that host variability matters.

The user reported that earlier load testing crashed their laptop, then explicitly
requested a test within the laptop's resource limits. The new measurements use
hard CPU, memory and disk quotas plus an independent temperature/resource
watchdog. Do not repeat the older unrestricted high-load commands on this laptop.

## Current revision: capped laptop measurements

The subsequent [performance-mode rerun](results/performance-mode-attempt.md)
initially stopped during preparation because of disk saturation, an SSD temperature
alarm and a CPU cutoff. A later reflink snapshot avoided bulk copying and the
HTTP load began, but the user requested stopping tests before the measurement
finished. No completed result exists; the earlier passing result must not be
relabeled as a performance-mode score.

See [results/laptop-load.md](results/laptop-load.md) for the October 24–25 tests
of the current release binary, including the full stepping search, sustained
measurements, failed verdicts, the protective temperature stop and the laptop's
observed quiet/power-saving profile. The machine-readable report is
[results/laptop-load.json](results/laptop-load.json).

PostgreSQL was limited to four CPU equivalents and 8 GiB memory; the application
and colocated generator shared four CPU equivalents and 2 GiB. Disk bandwidth
was limited to 128 MiB/s reads and 64 MiB/s writes. The full official seed and
unchanged upstream generator were used, with think-scale 0.1. These results
measure the selected budget on a shared laptop, not unrestricted capacity or an
official score, and are not directly comparable with the historical runs below.

## Latest batching changes: bounded correctness checks

The historical throughput measurements later in this document predate the latest
edits to read_batch.rs and writer.rs. The current source passed the bounded
correctness checks described here; its later capped load tests are linked above.

The changes are limited to application-side work:

- The sharing selector parses each visited Bind frame once, compares only
  distinct keys, and returns false as soon as their count exceeds half the cohort.
  Up to 32 requests use a 16-entry stack array; larger configured cohorts use a
  temporary vector. Previously the inner comparison reparsed earlier frames.
- Integer parameter arrays reserve 20 + 12N bytes, the maximum encoded size of
  N valid int8 values including their lengths and the array header. Nulls use
  less space. The array count is converted once; emitted bytes are unchanged by
  construction. Text-array allocation is unchanged.
- Each database actor retains its job vector allocation. Every success/error
  branch removes its jobs with pop or drain; no request arguments, rows or reply
  handles survive into the next cohort. BEGIN/COMMIT/ROLLBACK and retry ordering
  are unchanged. A debug assertion documents the empty-buffer invariant.
- Writes now use the same owned Bind/Execute encoding as reads. This removes the
  separate parameter vector, each parameter's allocation and its second encoding
  pass. After BEGIN, a write group uses one driver request/Sync boundary instead
  of one per statement. This reduces protocol messages and response-channel work;
  the previous implementation already pipelined requests, so it is not a claim
  that N sequential network round trips became one. COMMIT is still awaited
  separately before any successful reply. On a statement error, the driver drains
  through ReadyForQuery, the actor rolls back, and every job is retried in
  isolation, including statements that PostgreSQL skipped after the first error.

Validation of the current source:

- 14 ordinary unit tests passed, including the new sharing threshold, odd-size,
  stack/heap boundary and malformed-frame cases; two inherited diagnostics and
  the opt-in database test were skipped by that command.
- The database test then passed separately against PostgreSQL 18.6. It covers
  single writes, a 16-request group, null/Unicode/array/binary parameters, result
  ordering, empty results, immediate visibility from a second connection, an
  error in the middle of a group followed by isolated retries, and a deferred
  constraint failure at COMMIT followed by successful connection reuse. Traces
  confirmed group sizes 1, 16, 3, 2 and 2.
- All 197 unchanged official API checks passed against a fresh development seed;
  the unchanged seed loader verified its reference fingerprints. This run used
  the debug application build and one app worker, two read connections, one
  write connection and one bcrypt worker.
- Clippy with all targets and warnings denied passed.
- The ordinary build.sh release build passed under the same limits, peaking at
  596 MiB. The official API run above exercised the debug build; the new release
  binary was subsequently used for the capped measurements linked above.

Build/test cgroups were limited to 50% of one CPU, 1.5 GiB memory, no swap and
64 tasks, with a ten-minute deadline and low scheduler/I/O priority. The helper
refuses to start with less than 8 GiB available RAM or elevated memory pressure,
and verifies the kernel's limits before invoking the command. The unit-test build
and run peaked at 323 MiB; Clippy peaked at 214 MiB. The host retained about
18–19 GiB available RAM, with no measured memory pressure at the checkpoints.

The write fixture had its own 0.25-CPU / 384-MiB limit. The API fixture used
0.25 CPU / 768 MiB, 16 MiB shared buffers, and a 94-MB dev database. Both used
ephemeral tmpfs storage and were removed afterward. These tests exercise SQL and
transaction behavior, not power-loss durability or production capacity. The
original performance database remained stopped; no load generator ran.

Logs are retained in [results/bounded-checks.txt](results/bounded-checks.txt).

## Earlier unrestricted measurements: environment and method

- Intel Core i9-13900H, 20 logical CPUs, approximately 30 GiB RAM, Linux x86_64.
  No CPU affinity or host/kernel tuning. Other workstation applications remained
  active; background activity, thermal behavior and a system update affected some
  runs. The app, PostgreSQL and generator shared this machine.
- PostgreSQL 18.6 in the dedicated container created by tools/setup-local.sh,
  with the challenge's settings for 8 CPUs / 16 GB: 4 GB shared buffers,
  9,709 kB work_mem, 100 max connections, synchronous commit and fsync enabled.
  The processes were not constrained to an 8-CPU quota. A separate Ubuntu build
  validation container had a 4-CPU quota; it was stopped before load measurements.
- Full official seed: 100,000 users, 500,000 articles and the supplied favorites,
  comments, follows and indexes. Its reference fingerprint checks passed.
  Every application benchmark used a fresh database clone.
- Rust 1.99.1 for local performance binaries; the pinned Rust 1.99.0 toolchain and
  clean Ubuntu 24.04 were separately checked with install.sh and build.sh.
- Unchanged upstream load generator. Probes: 15 s ramp, 45 s measurement, 5 s tail.
  Holds: 60 s ramp, 300 s measurement, 15 s tail. Think-scale 0.1 accelerates both
  think times and session turnover. It does not simulate the connection/memory
  costs of ten times as many users, so do not multiply these VU counts into a score.
- Two app workers, six read connections and two write connections. Bcrypt workers
  were initially one; the final default is two. The metadata for every run records
  its settings. The process file limit matches the challenge's 200,000 descriptors.
  Early generator runs used the host's 20 Go scheduler workers. The later local
  harness default is four; the run arguments record that setting.

Baseline: rust-tokio-Scooter1337 at challenge commit
c3012257f2ee3dd2ccc72ada2eeba2b0d1278e8e. Baseline source was not modified.
`results/probes.json` contains the retained run summaries; `results/holds.json`
preserves endpoint statistics and verdicts for all three sustained attempts,
including the failed and invalid runs. Raw histograms, endpoint
statistics, logs, metadata and CPU/RSS samples remain in `.local/results/` in this
workspace and can be regenerated with tools/bench.py. They are excluded from Git.

## Sustained result

The previously tested configuration completed a five-minute measurement at 18,000 virtual
users and think-scale 0.1, after a 60-second ramp:

| Metric | Result |
|---|---:|
| Requests | 11,213,797 |
| Throughput | 37,379 req/s |
| p95 / p99 | 174.8 / 244.6 ms |
| Errors | 3,610 timeouts (0.0322%) |
| Login p99 | 315.1 ms |
| Application CPU / PostgreSQL CPU | 1.94 / 5.66 cores |
| Application peak RSS during measurement | 81 MiB |
| Upstream generator verdict | PASS; not LG-limited |

All reported errors were write-request timeouts. There were no HTTP error
responses or client-port errors in this run, and the server log contained no
database errors or server-process crashes. All 3,610 errors cluster into seconds
241–244 of the run, following a read-latency spike around second 238. This points
to a transient stall rather than proving a steady write-queue bottleneck; the
cause has not been isolated. Passing the
aggregate limits does not mean every request met the latency limits. No maximum
capacity or official user score is established by this shared-host experiment.

The generator used GOMAXPROCS=4, the server used two bcrypt workers, and the
candidate binary SHA-256 was
`5f891df47d0716be7053f8c063d0cc9b44fbd1bd9fb1c158bf032d37dcb3e578`.
See the `bcrypt2-hold-18000` entry in [results/holds.json](results/holds.json).

## Short comparisons

These 45-second probes used one bcrypt worker and the host's 20-worker Go
scheduler. The candidate here includes filtered-list and comment batching, before
the global-count fast path and final bcrypt setting. They are useful comparisons,
but are too short to establish sustained capacity.

| VUs | Baseline req/s | Candidate req/s | Baseline p99 | Candidate p99 |
|---|---:|---:|---:|---:|
| 6,000 | 15,873 | 15,877 | 4.0 ms | 4.1 ms |
| 12,000 | 31,627 | 31,036 | 7.3 ms | 77.0 ms |
| 18,000 | 43,110 | 43,832 | 101.1 ms | 92.3 ms |
| 24,000 | 42,527 | 44,057 | 299.8 ms | 294.9 ms |

All eight probes reported zero errors. The 12,000-VU candidate run coincided with
a host CPU burst; the result is retained rather than discarded. A repeated
24,000-VU baseline reached 43,593 req/s, demonstrating the run-to-run variation.
Disabling comment batching at 18,000 VUs produced 42,914 req/s versus 43,832 with
it enabled. These observations support retaining the changes, but do not prove a
precise whole-service improvement. The standalone SQL measurements below provide
stronger evidence for the reduction in repeated database work.

## Query experiments

Prepared generic plans, JIT off, alternating baseline/candidate executions on the
same database connection. Initial executions were discarded; figures are medians.
Both-direction EXCEPT ALL comparisons used one snapshot and covered mixed viewers,
filters, limits, empty pages and absent filters.

For eight matching requests on one page, the final filtered-list SQL measured:

| Query | Baseline | Candidate | Change |
|---|---:|---:|---:|
| Tag list | 0.819 ms | 0.413 ms | -49.5% |
| Author list | 0.597 ms | 0.398 ms | -33.4% |

The full results, including small batches that did not improve, are in
[results/sql-list.txt](results/sql-list.txt). These gains apply to eligible batches,
not every request. They do not imply a corresponding percentage increase in total
server throughput.

The global-list count fast path measured 0.191 → 0.160 ms at offset 0,
0.304 → 0.276 ms at offset 40, and 0.306 → 0.279 ms at offset 1,000.
It proves the cap by reading the 1,000th visible row and falls back to an exact
count for smaller databases. Boundary checks passed at 0, 1, 2, 999, 1,000 and
1,001 rows. See [results/sql-count.txt](results/sql-count.txt).

Rejected experiments: distinct page-key joins for the global feed usually added
overhead; an existence-first personal-feed count was inconsistent across viewers;
a bounded recent-article scan with an exact fallback was usually slower; sharing
personal-feed author scans reduced buffer accesses but its joins/materialization
cost more than the indexed reference query. None of those feed rewrites is shipped.
A 500 µs read collection delay did not improve throughput reliably, so the default
read delay remains zero.

## Why the bcrypt default changed

The short 24,000-VU runs initially passed the aggregate challenge limits while
login p99 was already around 9 seconds. A five-minute run with one bcrypt worker
then accumulated 19,220 password-request timeouts and 98 client-port errors caused
by connection churn. It failed the p95 limit. That run cannot establish a server
capacity ceiling because the local generator also ran short of ports.

With two bounded bcrypt workers, a subsequent 24,000-VU probe had zero errors and
login p99 was 566 ms. Cost 10, independent salts and full verification are unchanged.
This is why the final configuration uses two workers on eight CPUs, even though
the rare password endpoints have little weight in the aggregate percentiles.

A later 24,000-VU hold was explicitly flagged LG-limited: the generator's sampler
was 37.9 seconds late and it exhausted local ports. Its raw result is retained in
`.local/results/bcrypt2-hold-24000/merged.json`; it is excluded from capacity claims.
A cleanup error prevented the old harness from writing optional monitor metadata
for that run. The harness now saves measurements before attempting cleanup.

## Earlier validation, before the latest batching changes

- Unchanged conformance suite: 197/197 on the dev seed and full seed.
  The final binary was checked again on the dev seed with two bcrypt workers:
  197/197 passed.
- Clean Ubuntu 24.04: install.sh as root, build.sh as a normal user with pinned
  Rust 1.99.0, then 197/197 conformance on dev and full seed after the count change.
- Additional HTTP regression suite: 2,097 assertions with forced cohorts and
  2,097 with normal routing. Includes independent viewers, counts, pagination,
  unknown filters, fresh writes, concurrent tag creation, rollback isolation,
  newest-100 comments, pipelines, fragmented chunking and ambiguous framing.
  Trace logs confirmed shared comment batches of 16 and 32 requests with no SQL
  batch fallback errors.
- Rust release tests: 13 passed; two inherited diagnostic tests ignored.
  Clippy with all application targets and warnings denied passed.
- Inherited packed PostgreSQL driver checks: result ordering, empty results,
  error draining, connection reuse and fresh READ COMMITTED statement snapshots.

Logs are summarized in [results/validation.txt](results/validation.txt). Formatting
was checked for changed modules; cargo fmt --all traverses the inherited trimmed
vendor crate, whose declared benchmark source is absent, so it is not the relevant
formatting command for the application.

## Reproduce

See [tools/README.md](tools/README.md). Use `--env BCRYPT_THREADS=1` for the original
baseline configuration, and the harness defaults for the final candidate. Do not
run measured comparisons concurrently. The official score still requires the
organizer's 8-vCPU / 16-GB server, separate load machines and official search/hold
procedure.
