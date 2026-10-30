# Optimization plan

## Local resource constraint

The user reported that earlier load testing crashed their laptop. They now permit
tests when sufficient resources remain. Use tools/bounded-check.sh for development
builds and tests: it requires at least 8 GiB available RAM and low memory pressure,
verifies cgroup limits, caps work at half of one CPU core and 1.5 GiB memory,
disables swap, limits tasks and expires after ten minutes. Run checks sequentially.
The user subsequently explicitly requested a load test up to the laptop's
resource limits. Use tools/laptop-load.py for this authorized measurement: hard
quotas of four CPU cores / 8 GiB for PostgreSQL and four CPU cores / 2 GiB for the
app plus generator, no swap, bounded disk bandwidth, and an independent watchdog.
It reserves at least 8 GiB host RAM and stops on sustained heat or resource
pressure. This is a capped local measurement, not a search for a crash boundary.
The original PostgreSQL benchmark container remains stopped. Any small database
fixture also needs its own explicit CPU/memory limits because Docker containers
do not inherit the caller's cgroup budget. Unrestricted performance measurements
still belong on a separate test machine.

## Contract

Implement all 19 Conduit endpoints and pass the unchanged upstream conformance
suite. PostgreSQL 18 and the supplied schema are fixed. No cross-request result,
password or JWT verification caches. Every response sees data read during that
request; every write response waits for durable commit. bcrypt remains cost 10;
HS256 signatures, algorithm and expiry are verified every time. At most 95 database
connections, no host tuning, no CPU affinity. Serve HTTP/1.1 directly on HOST:PORT.
Dependencies must be pinned, source builds reproducible, and health ready in 60 s.

## Starting point

Use the MIT-licensed `rust-tokio-Scooter1337` submission as an explicitly credited
baseline, including its upstream tokio-postgres and native bcrypt licenses. It
already provides low-memory HTTP connections, durable group commit, bounded
interleaved bcrypt, SQL batching and recovery. Preserve upstream files; put every
deliverable in this folder.

## Work

1. Read rules, workload, fixed indexes and conformance checks. Establish isolated
   PostgreSQL 18 with the official dev and full seeds. Build tools and baseline.
2. Check candidate query plans on real data. Optimize repeated list/count work and
   overlapping article/comment reads within a single execution. Never retain data
   after the in-flight cohort finishes. Keep viewer-dependent fields separate.
3. Compare baseline/candidate with the same database, load and process settings.
   Keep changes supported by measured gains; tune batching and connection counts.
4. Verify conformance, SQL equivalence, fresh visibility, authorization, commit and
   concurrent-request behavior. Run Rust tests and static checks appropriate to
   the changes. Run a longer full-seed workload with endpoint latency/error data.
5. Document exact changes, commands, raw measurements and machine limitations.
   Local throughput is not an official score; that requires the official 8-vCPU
   box and separate load machines. Do not claim an unmeasured capacity.

## Acceptance

All 197 conformance checks pass. No modified files outside this submission.
No generated binaries or secrets in the submission. Include a reproducible
comparison against the credited baseline, regression coverage for new behavior,
and an honest record of rejected experiments and unmeasured limits.

## Previously validated revision

Before the latest source-only pass, all five work stages were completed. That
revision passed all 197 official checks,
SQL equivalence and boundary checks, 2,097 additional assertions in each of two
routing configurations, Rust tests and Clippy. Clean Ubuntu installation and the
pinned source build were verified. All deliverables are inside this folder.

The final five-minute local measurement passed at 37,379 req/s with p95 174.8 ms,
p99 244.6 ms and 0.0322% errors. BENCHMARKS.md records its limitations, earlier
failures and rejected experiments. Official scoring still requires the organizer's
server and separate load generators; it has not been performed or inferred.

## Batching follow-up

Implemented single-parse sharing selection, integer-array capacity reservation,
empty job-buffer reuse, one-time write encoding and packed write submission.
The user then allowed tests with resource headroom. Under verified cgroup limits,
14 unit tests, a PostgreSQL transaction integration test, Clippy and all 197
official API checks passed. Both small database fixtures were removed afterward.
The earlier throughput results must not be attributed to this revision. The
subsequently authorized capped measurements of the current binary are retained
separately in results/laptop-load.md and results/laptop-load.json, including
failed latency verdicts and a temperature-triggered interruption.
