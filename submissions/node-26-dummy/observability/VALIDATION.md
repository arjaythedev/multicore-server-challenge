# SQL and pool diagnostics validation — 2026-11-01

## HTTP/event-loop follow-up — actual checks and overhead

Added opt-in `BENCH_HTTP_DIAGNOSTICS=1` / controller `--http`, with fixed router
labels, bounded histograms, size-conditioned handler/flush durations, 5% sampled
comments phases, event-loop delay/ELU and CPU deltas. No SQL text, pool sizing,
workers, keep-alive, schema or PostgreSQL configuration changed.

Actual checks on Node 26.13.0 and the private PostgreSQL 18.6 instance (55432):

- Typecheck and build passed. Clean conformance builds also passed.
- Conformance **197/197**, one worker with both diagnostics off; **197/197**,
  six workers with both diagnostics on, fresh dev-seed clones.
- HTTP focused tests cover deterministic sampled phases, byte-size groups,
  401/204, finish/close deduplication, premature close before/after end,
  listener cleanup, final flush, requests spanning a ten-second interval, and a real HTTP client disconnect while its
  handler is still pending. Off/unset runs assert no diagnostic timer, output
  or initialization, even with intentionally invalid output configuration.
- Existing pool contract tests passed (callbacks/Promises, reuse, exhaustion,
  acquisition errors, transactions/release and natural process exit).
- Bounded-output tests passed (slow/blocked stdout, real unread pipe, rotation,
  file permissions, EPIPE, disk errors, final record and flush deadline).
- Controller fixture tests passed: explicit off, --http, --pool, manifest,
  pool mode preserves SQL tracking; no real configuration command executed.
- OTel integration passed with six workers, pool/query spans under HTTP,
  PID correlation, balanced pool connections and final HTTP records/files on
  Cluster shutdown. Final repeat: 188 spans, 74 pool, 74 query; HTTP output
  counters showed zero drops/errors for all worker records.

### New overhead measurement: both diagnostics plus files

Same isolated `node26_diag_checks` database and read-only workload, six workers,
tracing off, loopback, 100 RPS. Each run: 30 seconds warmup, 60 seconds measured
(6000 requests). Two pairs, order OFF→ON then ON→OFF. ON enables pool + HTTP +
event-loop metrics and **file output**, OFF disables both. File cap 10 MiB;
output is drained by the verifier. CPU is primary+workers user/system time from
`/proc`, CLK_TCK=100; it excludes PostgreSQL and generator CPU.

| Pair | Mode | p50 ms | p95 ms | p99 ms | Node CPU s | Stdout bytes |
|---|---|---:|---:|---:|---:|---:|
| 1 | OFF | 5.011 | 9.456 | 10.209 | 12.53 | 0 |
| 1 | ON | 5.080 | 9.881 | 10.370 | 14.45 | 215,048 |
| 2 | ON | 5.034 | 9.476 | 10.268 | 14.00 | 209,622 |
| 2 | OFF | 4.982 | 9.460 | 10.161 | 12.59 | 0 |

All four runs: **zero HTTP errors**, zero generator scheduling lateness >100 ms.
Mean Node CPU: **12.56 s OFF versus 14.225 s ON**, observed **+13.3%**.
Pair CPU increases: +15.3% and +11.2%. Mean per-run p95: 9.458 versus 9.678 ms;
p99: 10.185 versus 10.319 ms. Mean emitted diagnostic stdout: 212,335 bytes per
minute across six workers, also persisted to JSONL (excluding final/startup
records from measured log volume).

This is a measurable cost, not zero-overhead instrumentation. It measures the
combined diagnostic stack, not the marginal HTTP-only cost. Two local pairs do
not establish production/high-concurrency overhead or predict 20k latency.
Keep instrumentation off for clean performance benchmarks; high-VU ON/OFF
validation and client/server network attribution remain manual follow-ups.

### Ethernet feasibility (read-only)

`eno2` was administratively UP but operationally DOWN/NO-CARRIER, with no IP.
The LAN/default route used `wlo1`; no network setting was changed. A cable/link
is needed before a server-side Ethernet A/B. After connecting/configuring it,
verify `ip route get <MacBook-IP> from <Ethernet-IP>` and use that Ethernet IP
as the target. Keep seed/workload/instrumentation identical. No high-load test
or service restart was performed; only the private test PostgreSQL was started.

## Follow-up refactor and bounded logging validation

The diagnostics implementation was extracted into `src/pool-diagnostics.ts`,
dynamically imported only when enabled. The controller now records the actual
SQL tracking setting and enables bounded per-run, per-worker JSONL files.
SQL algorithms, pool sizing, schema and PostgreSQL settings were not changed.

Repeated after this refactor on Node 26.13.0 and the private PostgreSQL 18.6
instance on port 55432:

- `npm run typecheck`, `npm run build`, and the clean `build.sh` invoked by
  conformance: passed.
- Conformance: **197/197** with `WORKERS=1`, diagnostics off; **197/197** with
  `WORKERS=6 BENCH_DIAGNOSTICS=1`. Each used a fresh private dev-seed clone.
- `test-pool.mjs`: passed disabled/unset, callback/Promise acquisitions,
  query/transaction/release, new/reused clients, pool exhaustion, acquisition
  failures, final accounting and natural process-exit checks.
- `observability/test-output.mjs`: passed rotation, 0600 files, whole JSON lines,
  callback/drain ordering, bounded queues, final-record priority, EPIPE, file
  errors, idempotent finish, and bounded shutdown. A child with a real unread
  stdout pipe saved its final record to disk and exited successfully; separate
  tests exercise controlled blocked/slow streams.
- `observability/test-ctl.mjs`: passed actual `top`/`none` manifest values,
  read failures, pool-mode preservation, explicit off, trace5 --pool, size
  validation and duplicate RUN_ID rejection. These use isolated command stubs
  allowing only SHOW, not live configuration changes.
- `observability/verify.mjs otel`: passed with **144 spans**, **56 pool spans**,
  **56 query spans**, HTTP ancestry and PID correlation for all six workers.
  Cluster shutdown produced all six final records, matched JSONL to stdout,
  verified file limits and balanced physical connection creation/removal.
  The first attempt overlapped conformance's `npm ci` and failed loading an
  OTel module; the independent rerun after installation completed passed.

No SQL EXPLAIN/equivalence or fixed-rate overhead benchmark was repeated in
this follow-up. The results below predate the file-output change and do not
measure its extra disk/serialization/output-queue cost. No high-load benchmark
or production Tempo/UI check was performed. Existing services were untouched;
only the private test PostgreSQL instance was started for these checks.

## Original SQL/diagnostics validation

User-supplied baseline remains **10,000 VUs / 300 seconds: 2,625.9 RPS,
p95 69.2 ms, p99 117.9 ms, 0% errors, PASS**. This change has not been tested
at 10k/15k/20k VUs. The reported 20k run includes client `no_local_port` failures
and cannot establish a clean backend capacity limit.

## Correctness

Node 26.13.0; TypeScript 7.0.2; PostgreSQL 18.6. A separate PostgreSQL instance
on port 55432 used a fingerprint-verified dev seed. Own test clones/processes
were used for writes, concurrency, errors, shutdown and load checks.

- Strict typecheck/build passed.
- Conformance: **197/197** with one worker, diagnostics off; **197/197** with six
  workers, diagnostics on. The six-worker run was repeated after the shutdown fix.
- SQL equivalence: **80 page/count pairs** in each repeatable-read snapshot,
  offsets 0/10/20/40, anonymous/authenticated viewers, filter precedence and
  empty results. Full articles with multiple/no tags and maximum feed offset
  were also checked. The working full DB has no tagless fixture; that case was
  explicitly tested in the isolated clone instead.
- Pool tests passed: callback/Promise, pool.query callback/Promise, transaction
  success/rollback, client/release identity, new/reused clients, queue saturation,
  real 10s acquire timeout, startup connection failures, connect after end,
  histograms, final flush, natural exit, and disabled/unset modes.
- Lifecycle tests passed: draining active requests, pool closure, fail-fast on
  SIGKILL and unexpected exit 0, forced termination of an unresponsive worker.
- OTel ESM/Cluster check exported **185 spans**, including **73 pg-pool.connect**
  and **73 pg.query** spans. Both kinds had HTTP ancestors. Resource process.pid
  matched diagnostics for all six workers. All six final intervals arrived,
  and their cumulative created/removed connection counts matched.
- ctl.sh tests passed with stubbed external commands: pool skips the profiling
  script; baseline explicitly disables diagnostics; trace5 --pool enables both;
  manifests and argument validation work. No ALTER SYSTEM was executed.

The private OTel receiver used HTTP/JSON and 100% sampling to make assertions
deterministic. It exercised the same auto-instrumentation hooks, not the live
Tempo UI or the production protobuf exporter. The installed `pg` instrumentation
also instruments `pg-pool`; a separate enabled-instrumentation name is not needed.

## SQL plans

Read-only `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` on the existing full database.
These are individual warm-cache measurements, not workload speedups:

| Query | Execution before → after | Shared hits before → after | Enrichment loops before → after |
|---|---|---|---|
| Global list, viewer 100, limit 10, offset 0 | 0.536 → 0.243 ms | 152 → 166 | 10 → 10 |
| Global list, viewer 100, limit 10, offset 40 | 1.763 → 0.275 ms | 671 → 205 | 50 → 10 |
| Feed, viewer 629, limit 20, offset 0 | 1.822 → 1.494 ms | 2,092 → 2,138 | 20 → 20 |

Global list before:

```text
Limit (10 rows, skips 40)
  Article scan + author join (50 rows)
    Tag array / favorites count (50 loops)
      Tags Seq Scan (200 tags each loop)
```

Global list after:

```text
Sort by article ID DESC (10 rows)
  Article page (LIMIT 10 OFFSET 40) + author join (10 rows)
    Tag array / favorites count (10 loops)
      Article-tag index lookup
      Tags PK lookup (17 total lookups for this page)
```

The actual full-database plan uses `tags_pkey`. The untuned small dev instance
may choose a sequential scan for scalar tag lookups: PostgreSQL's cost model
still decides the physical access path. No index scan is forcibly enabled.
Slightly higher buffer-hit counts with scalar lookups are possible despite less
CPU work; buffer hits alone do not measure elapsed cost.

Feed selection and favorites counts are unchanged. The user's earlier feed-629
plan showed 1,354 favorites-count shared hits and 1,666 heap fetches across 20
index searches. Investigating those heap fetches remains future work; no VACUUM,
index/config change, or favorites rewrite was applied here.

## Example emitted record

Actual final record from the OTel integration check (formatting only changed):

```json
{
  "event": "pool_diagnostics",
  "pid": 48818,
  "worker_id": 5,
  "hostname": "padlos",
  "run_id": "verify-otel-on",
  "sequence": 1,
  "interval_start": "2026-11-01T01:48:00.445Z",
  "interval_end": "2026-11-01T01:48:00.829Z",
  "duration_ms": 383.5046209999998,
  "final": true,
  "current": {"total": 0, "idle": 0, "waiting": 0},
  "histogram_upper_bounds_ms": [0.1,0.25,0.5,1,2,5,10,20,50,100,250,500,1000,2500,5000,10000,"+Inf"],
  "histogram_cumulative": false,
  "successes": 14,
  "failures": 0,
  "acquisitions": {
    "all": {"count":14,"sum_ms":7.712003999999979,"max_ms":5.855456999999888,"buckets":[2,11,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0]},
    "new": {"count":1,"sum_ms":5.855456999999888,"max_ms":5.855456999999888,"buckets":[0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0]},
    "reused": {"count":13,"sum_ms":1.8565470000000914,"max_ms":0.2405980000000909,"buckets":[2,11,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]},
    "unknown": {"count":0,"sum_ms":0,"max_ms":0,"buckets":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]},
    "failed": {"count":0,"sum_ms":0,"max_ms":0,"buckets":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}
  },
  "connections": {
    "created": 1,
    "removed": 1,
    "unknown_removed": 0,
    "removed_lifetime": {"count":1,"sum_ms":242.728073,"max_ms":242.728073,"buckets":[0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0]}
  },
  "observed_max": {"total":1,"idle":1,"waiting":1}
}
```

Match `run_id` to Tempo's `benchmark.run_id`, `pid` to resource `process.pid`,
and span UTC timestamps to interval bounds. Histogram acquisition duration
includes queueing, physical connection establishment and scheduling. New-client
duration is not a separate physical-connect timer; use `pg.connect` spans for
that. A waiting peak of 1 can be a nextTick-delivery transient even when idle
clients exist. One-second/event samples can miss shorter state transitions.

## Overhead experiment

Six workers, fixed 100 RPS, 30s warmup + 60s measured per run, tracing off.
Each measured run issued 6,000 requests against the same isolated dev clone,
using a deterministic read-only mix of article/detail/comments/tags/feed.
No task-driven tests ran concurrently with the retained measurements.

The initial OFF/ON pair overlapped correctness checks and was excluded. Two
subsequent pairs were retained; a replacement pair was run after the conversation
resumed later the same day. This time gap and normal host activity limit how
precisely small overhead differences can be attributed to instrumentation.

| Pair | Mode | p50 ms | p95 ms | p99 ms | Node CPU seconds | Log bytes |
|---|---|---:|---:|---:|---:|---:|
| 1 | OFF | 4.972 | 9.807 | 10.500 | 12.80 | 0 |
| 1 | ON | 5.028 | 9.548 | 10.245 | 13.01 | 41,356 |
| 2 | OFF | 4.929 | 9.707 | 10.091 | 11.94 | 0 |
| 2 | ON | 4.957 | 9.790 | 10.262 | 12.85 | 41,316 |
| 3 | OFF | 5.031 | 9.841 | 10.338 | 12.91 | 0 |
| 3 | ON | 5.016 | 9.367 | 10.036 | 12.17 | 41,251 |

Node CPU is user+system CPU summed across primary and workers, measured from
`/proc` with CLK_TCK=100; it excludes PostgreSQL and the generator. Log bytes are
worker stdout during the measured window, excluding startup/final records.
All retained runs had **zero HTTP errors** and zero scheduling delays over
100 ms. Mean Node CPU was **12.55 s OFF vs 12.677 s ON** per 60s measured window
(observed +1.0%). Individual pairs varied from -5.7% to +7.6%, so this does not
establish a precise 1% instrumentation cost. Mean per-run p95 was 9.785 ms OFF
vs 9.569 ms ON; the small reversal likewise should not be interpreted as a
speedup. Diagnostic output averaged **41,308 bytes/minute across six workers**.

The observed latency ranges overlap; this small fixed-rate check found no
consistent latency regression. The enablement does perform extra timing,
histogram updates, event sampling and serialization, so its overhead at high
concurrency still needs measurement. Do not extrapolate these results to 10k
or 20k VUs or compare them directly to the official workload baseline.

## Unchanged environment and limits

The existing backend, Docker services and PostgreSQL configuration were not
restarted or modified. `conduit_lg` was accessed only with read-only transactions.
No high-VU benchmark was run. Matching production workload results, production
Tempo UI inspection and production PostgreSQL CPU attribution remain outside
these local checks. No claim of a new 10k/20k score is made.
