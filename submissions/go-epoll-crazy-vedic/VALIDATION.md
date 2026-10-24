# Validation record

Source is contained in this submission folder. Development machine: Linux x86_64,
Ryzen AI 7 350, 16 logical CPUs, approximately 27 GiB RAM; PostgreSQL 18.6.
This is not the official eight-vCPU/16-GB host.

Both deterministic seeds were generated and matched the unchanged fingerprints.
Full seed: 500,000 articles, approximately 2315 MB. Integration tests and the
conformance runner always operate on disposable copies, never on a seed template.

## Checks

Final validation on 2026-10-24: **PASS**. Conformance passed 197/197 on each
seed; integration tests with the race detector passed on each seed. Both fuzz
smokes, go vet, cgo and no-cgo builds, and shell/Python syntax checks passed.

Commands:

```bash
bash build.sh
go vet ./src/...
bash -n build.sh install.sh start.sh tools/check.sh tools/benchmark.sh
RACE=1 TEMPLATE=conduit_dev FUZZ_TIME=3s bash tools/check.sh
RACE=1 TEMPLATE=conduit_seed bash tools/check.sh
```

The suite includes:

* All 197 unchanged challenge conformance checks on both development and full seeds.
* Shared versus individual SQL for global/tag/author/favorited lists, article
  content, comment threads, distinct viewers, unknown filters, missing articles,
  and offsets beyond the last page.
* A subsequent tag batch reading fresh changes instead of an earlier result.
* Failed write-group rollback, individual retry isolation, and a later flight
  remaining intact after a preceding SQL error.
* A real malformed binary SQL parameter followed by read-pipeline reconnection.
* Mutation responses reading committed favorite counts from a fresh snapshot.
* Concurrent HTTP reads and tag creation against the actual reactor and dispatcher.
* Fragmented/chunked HTTP input, pipelining, deadline rescheduling and wheel wraparound.
* Four bcrypt lane counts compared with x/crypto, wrong passwords, NUL/Unicode,
  72-byte inputs, and fresh cost-10 hashes.
* JWT library agreement, very large expiry values, future nbf, malformed tokens,
  numeric subjects, and unknown claims.
* Race detection and bounded HTTP/JWT fuzz smokes.

## Performance status

After the implementation and correctness checks, the requested CPU profiling run
was completed on 2026-10-24. It used a disposable copy of the full synthetic seed,
4,000 synthetic users, THINK_SCALE=0.1, GOMAXPROCS=4, eight read connections, two
write connections, and pipeline depth two. A 15-second warmup preceded the
60-second measurement, with ten-second ramps for both phases.

The measured window completed 635,642 requests (10,594 requests/second), with
zero errors, p95 2.044 ms, and p99 3.683 ms. PostgreSQL averaged 2.31 CPU cores
(all local postgres processes), while the application averaged 0.86 cores.
Application RSS increased from approximately 143 MiB to 402 MiB during the
measured window; this CPU capture does not diagnose retained memory.

At the time of this historical profile, BCRYPT_WAIT was 150ms; the current default was later raised to 300ms after the lane-fill comparison documented in the submission README. The CPU profile includes startup, warmup, ramps, measurement, and tail. Of its
77.76 sampled CPU seconds, 30.85% was attributed to the syscall boundary,
29.12% to bcrypt implementation functions, and 2.39% directly to JSON string
escaping. Login p95 was 211 ms with the configured 150 ms bcrypt fill window.
Several write endpoints had p99 around 160–190 ms, coinciding with a queue
buildup; the capture does not establish the PostgreSQL wait or query responsible.

Artifacts, source hashes, configuration, pprof listings, and derived analysis are
in `.bench/pprof-synthetic-20261024/`. The workload processes stopped and their
disposable database was removed. This local run did not determine maximum
capacity or select a tuning configuration. No official score, eight-core ceiling,
or validated PGO build is claimed. Build output and measurement artifacts are
excluded from Git.

## Optimization implementation and comparisons

A subsequent implementation pass added queued-key routing, absolute read
collection windows, endpoint-specific sharing selection, shared author/tag
metadata, a recent-prefix feed with an exact fallback, consolidated pipeline
flushes, adaptive sparse bcrypt collection, owned HTTP field rebasing, HTTP Date
reuse, local database transport selection, stage histograms, PostgreSQL wait
sampling and live heap snapshots. TLS settings explicitly supplied by the caller
are preserved in automatic mode. Large borrowed HTTP fields are cleared when a
request slot returns to idle.

Final checks for this pass: race-enabled integration tests and 197/197 conformance
checks passed on the full seed with the selected defaults. Both bounded fuzz
smokes passed. The development seed also passed integration/race checks and
197/197 conformance checks with shared ordinary-list metadata, the recent feed
and separate favorite counts enabled. Additional equivalence checks compare the
metadata/feed SQL with the reference on multiple viewers and pagination offsets,
and check commit/error boundaries when several flights share one flush. Go vet,
cgo and no-cgo builds and shell/Python syntax checks passed.

Local 30-second comparisons used 4,000 users, THINK_SCALE=0.1, GOMAXPROCS=4,
PostgreSQL on the same host, and separate disposable full-seed clones:

| Run | App cores | PG cores | p95 ms | p99 ms | Jobs/flight | Execution reduction |
|---|---:|---:|---:|---:|---:|---:|
| Preserved control | 0.722 | 1.935 | 1.785 | 5.675 | 1.15 | 3.8% |
| All SQL experiments | 0.657 | 2.183 | 1.993 | 3.053 | 1.52 | 9.1% |
| Scalar metadata, recent feed | 0.657 | 1.919 | 2.004 | 3.979 | 1.53 | 9.3% |
| Scalar metadata, reference feed | 0.751 | 1.972 | 1.980 | 3.135 | 1.49 | 8.8% |
| Four readers, reference feed | 0.702 | 1.730 | 2.141 | 3.269 | 1.75 | 9.8% |
| Four readers, PGO | 0.681 | 1.734 | 2.131 | 3.321 | 1.75 | 9.7% |

All runs had zero errors and approximately 10.55k requests/second. These are
fixed-load comparisons, not capacity searches. The selected PGO run used about
9% less combined application/PostgreSQL CPU than the preserved control, with a
median latency increase from 0.254 to 0.552 ms. Results are exploratory single
runs with normal machine variation and occasional WAL waits; they do not isolate
each optimization or establish a statistically precise gain.

Ordinary scalar metadata and the reference feed remain the defaults because the
SQL experiments did not establish an advantage. Shared metadata for collected
requests remains active. Reader defaults now scale with GOMAXPROCS, capped at
eight; the local four-thread configuration uses four readers. Pipeline depth is
two, the read collection window is 50 microseconds, and the idle-write collection
age is bounded at ten milliseconds. READ_LINGER=0 selects lower collection
latency. Durability remains unchanged.

`src/default.pgo` is the CPU profile from `optimize-readers4-d`. It is portable
compiler input; executables are built from source. Builds use `-pgo=auto`, with
PGO_PROFILE=off available for reproducible controls. Artifacts and source hashes
for these comparisons are under `.bench/optimize-*/`.

### Normal-think-time hold

The selected PGO build passed a five-minute measured hold with 40,000 virtual
users, THINK_SCALE=1, GOMAXPROCS=4, four readers and two writers. It maintained
40,000 HTTP connections and completed **3,177,784 measured requests** at
**10,592.6 requests/second**, with **zero errors**, p95 **2.367 ms** and p99
**4.199 ms**. The load generator was not flagged as limited.

Application CPU averaged 0.668 cores and all local PostgreSQL processes averaged
1.871 cores. Application RSS peaked at approximately 498 MiB. Four GC collections
completed before shutdown; live sampled heap was about 107 MiB at an intermediate
collection and about 118 MiB after the final forced collection with the server
state kept reachable. Most retained memory was the fixed reactor arenas. Jobs per
flight averaged 1.81, with 10.2% fewer SQL executions than database jobs.

This is a local stability and connection-density check, with the load generator
on the same development machine. It does not establish an official eight-vCPU
score or maximum capacity. Source hashes match the final implementation. The
workload and resource sampler stopped, and disposable databases were removed.
The complete results, CPU/heap profiles, sampled PostgreSQL waits and source
snapshot are under `.bench/optimize-normal-hold/`.


## CGo bcrypt and SQL plans (2026-10-24)

The default build now has a four-lane C++20 bcrypt implementation behind cgo.
It accepts only ordinary ASCII passwords of at most 72 bytes; all other values
use the Go implementation. Every request still uses cost 10, fresh salts, and
normal bcrypt verification. The native path returns its computed bytes to Go,
where verification comparison remains constant-time. Tests compare generated
hashes with x/crypto, check incorrect passwords, and exercise one/four-lane work.
The adapted C++ source and license are identified in ATTRIBUTION.md.

A matched 40,000-user accelerated stress sample used GOMAXPROCS=8, 6 read and
2 write connections, four bcrypt workers, THINK_SCALE=0.3, and a 30-second
measurement on the local 16-logical-CPU development machine. The CGo build
recorded 898 native jobs and no fallbacks, 34,733 requests/second, zero errors,
p95 172.5 ms, app CPU 1.74 cores and PostgreSQL CPU 5.23 cores. The CGO_ENABLED=0
control recorded 34,827 requests/second, zero errors, p95 140.2 ms, app CPU
1.77 cores and PostgreSQL CPU 5.17 cores. This run verifies dispatch and gives
no evidence that CGo improves total throughput; the small difference is within
run-to-run noise. These same-host stress tests are not official capacity scores.

SQL experiments run EXPLAIN ANALYZE with BUFFERS and SETTINGS on a disposable
full-seed clone, after warming prepared variants. They compare forced generic,
forced custom, and auto plans across global/tag/author/favorited lists and feeds
for both high-follow and median-follow viewers, plus article and comment reads.
Generic plans avoided roughly 0.2-0.3 ms of planning per statement without a
consistent execution penalty, supporting the existing generic-plan default.
Metadata batching and separate favorite counts used more buffers and did not
win consistently. A bounded recent-feed scan reduced the high-follow query
from about 4,309 to 342 shared buffers and 2.1-2.4 ms to about 0.4 ms, but had
no meaningful effect for a median-follow viewer (which falls back to the full
query). Matched 4,000-user end-to-end runs showed no throughput win and worse
feed latency with the recent scan; it remains opt-in. No SQL experiment changed
the challenge schema or PostgreSQL settings. Captured plans are in
`.bench/sqlplans-20261024-122230/`; benchmark reports are in the corresponding
`.bench/` run directories.
