# Node.js 26 + TypeScript 7 + PostgreSQL 18

Front: direct

All 19 Conduit API operations implemented with `node:http`, parameterized SQL,
and strict TypeScript. Five application source files: all handlers and queries
in `src/handlers.ts`, shared helpers in `src/utils.ts`, routing/lifecycle in
`src/server.ts`, worker supervision in `src/cluster.ts`, and opt-in pool
instrumentation/output in `src/pool-diagnostics.ts`.

Runtime: Node 26; compiler: TypeScript 7.0.2. Dependencies are pinned:
`pg` 8.23.1, `bcrypt` 6.0.0, and `jose` 6.2.14. No ORM or HTTP framework.

## Run

Node.js 26, npm, Python 3, and a C++ build toolchain are required.
`sudo bash install.sh` installs these prerequisites on Ubuntu/Debian.
PostgreSQL 18 and the repository's seed database must be prepared separately.

```bash
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_lg \
JWT_SECRET=dev-secret HOST=127.0.0.1 PORT=3110 bash start.sh
```

`build.sh` checks Node 26, installs locked dependencies including development
tools, builds bcrypt from source, removes only this submission's `dist/`, then
compiles TypeScript with `noEmitOnError`. `start.sh` runs the emitted JavaScript.
`npm run typecheck` checks types without emitting files.

`DATABASE_URL` and `JWT_SECRET` are required. The start script defaults to
`HOST=0.0.0.0`, `PORT=3110`, and `NODE_ENV=production`. `GET /api/tags` is the
database-backed health endpoint. There is no separate `/health` route.

## Workers and database budget

`WORKERS` defaults to the available CPU count, capped at 90; valid values are
1–90. Each worker owns one pool with `min(10, floor(90 / WORKERS))` connections.
The application can never allocate more than 90 connections, leaving 10 of
PostgreSQL's 100 for administration and other clients. On six CPUs the maximum
is 60. Primary computes and logs the budget and never connects to PostgreSQL.
`PG_POOL_SIZE` is an internal value supplied by primary, not a tuning option.

An unexpected worker exit (even exit code 0) stops the entire cluster with exit
code 1; workers are never restarted. SIGINT/SIGTERM drain HTTP requests and close
database pools. Workers have a nine-second shutdown deadline; primary kills
remaining workers after ten seconds and exits unsuccessfully if forced cleanup
was needed. HTTP keep-alive is 75 seconds.

## API behavior

The implementation follows `SPEC.md` and the conformance suite. Authentication
uses HS256 with mandatory expiration and decimal-string subjects; credentials
and tokens are never cached. Password hashing/verification is asynchronous
bcrypt (cost 10 for new hashes), with a 72-byte UTF-8 password limit.

Article creation, tags, and links commit together. Failures roll back and release
the connection. IDs remain strings internally; numeric response fields are
checked for safe JSON integer conversion. An unrepresentable comment ID causes
an error rather than rounding; comment creation rolls back in that case.
Pagination is validated strictly, slugs are generated using the reference SQL,
and every data response reads PostgreSQL. No schema changes or result caches.

## Validation

From the repository root, with PostgreSQL administrator access configured via
the usual `PGHOST`, `PGPORT`, `PGUSER`, and optional `PGPASSWORD` variables:

```bash
PORT=3111 WORKERS=1 bash test/run.sh submissions/node-26-dummy
PORT=3111 bash test/run.sh submissions/node-26-dummy
```

The harness builds and starts the app on a temporary clone of `conduit_dev`,
runs conformance, and removes that clone. It never tests against your working
application database.

Supplemental integration tests, from this submission directory:

```bash
TEST_DATABASE_URL=postgres://postgres@127.0.0.1:5432/postgres npm test
```

The supplied URL must have permission to create/drop databases and change grants
in its own test clone. `test.mjs` creates a uniquely named clone of `conduit_dev`
and removes it in cleanup. It checks transaction rollback, bigint conversion,
pagination boundaries, a saturated connection budget, draining active requests,
pool closure, fail-fast on worker crashes and unexpected exit 0, and forced
termination of an unresponsive worker. `TEST_PORT` defaults to 33112.

Verified on Node 26.13.0 and PostgreSQL 18.6, using an isolated PostgreSQL instance
and the fingerprint-verified dev seed: conformance **197/197** with one worker
and **197/197** with the default six workers. Strict compilation and supplemental
integration checks pass. These are correctness checks, not performance scores.

## First SQL optimizations (2026-10-31)

Changes are limited to query shape and eliminating a redundant user lookup:

- Tag/favorited pages select ordered IDs with LIMIT/OFFSET from the indexed link
  table before fetching articles, authors, tags and favorite counts.
- Their capped counts read only the link table. Its foreign keys and composite
  primary key guarantee the same count without joining `articles`.
- Feed uses the reference LATERAL query: at most `limit + offset` IDs per followed
  author, then the global page, then enrichment. The sum uses bigint to avoid
  overflow at the maximum allowed offset.
- `/api/user` verifies the JWT and fetches the user in one SQL statement instead
  of two. Missing/deleted users still return 401; no verification cache is added.
- Global/author page queries retain their direct index paths: an experimental
  ID-first variant added PK lookups and increased estimated cost, so was omitted.

Read-only checks on the existing full-size `conduit_lg` used a single repeatable
read snapshot, sequential queries, and EXPLAIN **without ANALYZE**. For one fixture
per filter, viewer 100, limit 20, offset 0, planner total costs were:

| SQL | Before | After |
|---|---:|---:|
| Tag page | 817.25 | 130.80 |
| Tag capped count | 692.13 | 38.42 |
| Favorited page | 384.89 | 368.75 |
| Favorited capped count | 30.82 | 6.81 |
| Feed page | 482.53 | 477.82 |
| Global / author page | 309.01 / 332.66 | unchanged |

These are **planner cost units, not milliseconds or measured speedups**. The tag
page now uses `article_tags_tag_idx`; its count no longer probes `articles_pkey`.
This verifies removal of unnecessary work, not its share of CPU during the 10k
VU run. Feed improvement is workload-dependent: many follows or deep offsets
can still require many candidates. No indexes, schema, PostgreSQL configuration,
pool budgets, or production data were changed. No load benchmark was run.

Reproduce the read-only equivalence/plan checks from this submission directory:

```bash
npm run build
TEST_SQL_DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_lg \
TEST_SQL_ALLOW_MISSING_FIXTURE=1 TEST_SQL_EXPECT_TAG_INDEX=1 node test-sql.mjs
```

The check now compares actual handler SQL against previous query shapes: 80
page/count pairs covering all filters, anonymous/authenticated viewers, offsets,
missing filters and filter precedence. It also checks the maximum feed offset,
single-query current-user lookup, and unknown-user 401. It uses one connection,
a read-only transaction, and a 10-second per-statement timeout. The database must
contain the standard seed fixtures. It now runs EXPLAIN ANALYZE for selected
queries. No-tag fixtures must be supplied in an isolated clone; the opt-in
ALLOW_MISSING_FIXTURE skips absent fixtures on a read-only working database.
EXPECT_TAG_INDEX asserts the actual index choice on the tuned full database.
Results and SQL parameters are not logged.

Remaining hypothesis: excess scanning/index probes contribute to PostgreSQL CPU
saturation. Their contribution and the resulting RPS/p95 change still need an
identical-workload before/after benchmark or SQL profiling under load. A larger
pool is not justified by the available measurements. Rebuild and restart the
application to use these changes; an already running server is not updated.

## Page enrichment and pool diagnostics (2026-11-01)

The global unfiltered list now selects article rows with LIMIT/OFFSET before
enrichment, without an extra article PK lookup. Tag names use scalar lookups by
tag ID in the shared article projection. PostgreSQL still chooses the physical
access path: the tuned full database uses `tags_pkey`, while default costs on the
small dev seed can prefer a sequential scan. Filtered page selection, LATERAL,
favorites counts and capped counts retain their existing semantics.

`BENCH_DIAGNOSTICS=1` installs diagnostics on the existing pool in each worker.
Unset/0 does not import the diagnostics module and installs no diagnostic
wrappers, timers or event listeners. The pool's
max, idle timeout, release behavior and transaction handling are unchanged.

From this submission directory, after building, start in the foreground:

```bash
bash observability/ctl.sh run pool pool-001
bash observability/ctl.sh run trace5 trace-pool-001 --pool
```

Run one command at a time on a free configured port. `pool` preserves SQL
profiling settings and disables OTel/V8 profiling. `trace5 --pool` retains the
existing trace5 behavior, including its SQL-profiling configuration step.
Other modes explicitly set diagnostics to 0 unless `--pool` is passed. The
effective setting is recorded as `pool_diagnostics` in the run manifest.
`pg_stat_statements_track` records the actual `SHOW pg_stat_statements.track`
result, including in `pool` mode: this read does not change PostgreSQL settings.
Configuration stays in `observability/modes.env` and `runtime.env`.

Each worker writes one `pool_diagnostics` JSON line every 10 seconds to stdout,
plus a final partial interval on graceful shutdown. `run_id` matches OTel
`benchmark.run_id`; `pid` matches `process.pid`; hostname and UTC interval bounds
allow correlation with Tempo. `worker_id` and `sequence` distinguish processes
and consecutive intervals. Primary does not create a pool or emit pool metrics.

The controller also saves JSON lines under
`observability/runs/<RUN_ID>/pool/worker-<worker_id>-<pid>.jsonl`.
Each worker keeps the current file and one `.1` backup, each at most 10 MiB
(at most 120 MiB for a normal six-worker run). Rotation preserves whole records
and overwrites the oldest backup. Files are created with mode 0600. Set
`BENCH_DIAGNOSTICS_MAX_BYTES` in `observability/modes.env` to override the
per-file limit (4096–67108864 bytes); the manifest records this limit and path.
Direct launches can opt into file output via `BENCH_DIAGNOSTICS_DIR`.

Stdout and file output have independent queues capped at 64 KiB each per worker.
Stdout respects both write callbacks and backpressure (`drain`); a blocked pipe
does not block file logging. Overflow drops records, prioritizing the final
record over queued older records. `output.stdout` and `output.file` report
cumulative `pending_bytes`, `dropped`, and `errors` as observed before emitting
the current record. File failures disable that sink and are reported at shutdown;
they do not interrupt API requests. Disk writes add overhead only when enabled.

Histogram buckets are **non-cumulative**, with inclusive upper bounds in
`histogram_upper_bounds_ms`; the last bucket is overflow. Every histogram has
`count`, `sum_ms`, `max_ms` and `buckets`. Acquisitions are assigned to the interval
in which they finish. `all` includes failures; `new`, `reused`, `unknown` and
`failed` partition it. `new` means the first successful acquisition of a client
observed through the pool's physical `connect` event, not an increase in size.
Connection ages start at successful connection establishment.

Acquisition duration includes connection creation, scheduling and possible
queueing. It is **not pure queue wait**. `waitingCount` can briefly be nonzero
even with an idle connection because pg-pool schedules delivery on nextTick.
Gauge maxima are observations at events/acquisitions and one-second samples,
not guaranteed exact peaks. Histogram quantiles have bucket resolution.

Diagnostics do not create spans or log requests, SQL, parameters or credentials.
The wrapper delegates to the existing connect method, including OTel's wrapper,
and forwards the original client/release. Shutdown waits for asynchronous
`remove` events after `pool.end()`, then gives output queues up to 1500 ms to
flush. Files close independently of blocked stdout. The deadline prevents a
blocked consumer from hanging graceful shutdown; pending records can be lost
on timeout or sink failure. SIGKILL or the existing forced-shutdown deadline
can also prevent the final record. This is bounded diagnostic logging, not a
durable audit log (no fsync guarantee).

Validation scripts (use your isolated PostgreSQL instance/clone):

```bash
TEST_DATABASE_URL=postgres://postgres@127.0.0.1:55432/postgres node test-pool.mjs
node observability/test-ctl.mjs
node observability/test-output.mjs
TEST_DATABASE_URL=postgres://conduit:conduit@127.0.0.1:55432/node26_diag_checks node observability/verify.mjs otel
TEST_DATABASE_URL=postgres://conduit:conduit@127.0.0.1:55432/node26_diag_checks node observability/verify.mjs overhead
```

The OTel check uses a private local OTLP HTTP/JSON receiver with the same ESM
auto-instrumentation hooks. The overhead check uses six workers, 30s warmup and
60s measured at 100 RPS per run, tracing disabled, three alternating OFF/ON
pairs. It logs Node CPU ticks (Linux `getconf CLK_TCK`), latency, errors, stdout
bytes, and scheduler lateness. It is a local read-only diagnostic workload, not
the official 10k-VU benchmark. See [validation results](observability/VALIDATION.md).
