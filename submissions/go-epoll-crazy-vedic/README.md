# Go and C++: epoll, shared PostgreSQL reads, durable group commit

Front: direct

Conduit server based on `go-epoll-o7livetype`, with attribution retained
in [ATTRIBUTION.md](ATTRIBUTION.md) and [LICENSE](LICENSE). There is no official
score for this submission. See [VALIDATION.md](VALIDATION.md) for local checks.

| Component | Pinned version |
|---|---|
| Go | 1.27.2 |
| PostgreSQL driver | pgx/pgconn 5.11.0 |
| Linux syscalls | golang.org/x/sys 0.49.0 |
| JWT fallback | golang-jwt/jwt/v5 5.3.1 |
| bcrypt reference/fallback | golang.org/x/crypto 0.58.0 |
| bcrypt fast path | four-lane C++20 through cgo; Go fallback for unsupported inputs |

## Build and run

`install.sh` installs the pinned Go toolchain and C++ build tools on Ubuntu 24.04. `build.sh` builds as
an ordinary user; `start.sh` executes the server in the foreground. The default build uses cgo and
links the system C++ runtime; set `CGO_ENABLED=0` to build the compatible Go-only fallback.

```bash
sudo bash install.sh
bash build.sh
psql -d postgres -c 'CREATE DATABASE conduit_work TEMPLATE conduit_dev'
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_work \
JWT_SECRET=local-secret HOST=127.0.0.1 PORT=3110 bash start.sh
```

Only DATABASE_URL and JWT_SECRET are required; HOST defaults to 0.0.0.0 and PORT
to 3000. The benchmark supplies direct-service values. Statements are prepared
before accepting traffic. Keep seed templates unchanged and run on copies.

## Design and optimizations

Epoll loops own client sockets and lend request slots only while work is active.
Each PostgreSQL connection has one owning goroutine. Reads, writes, and password
work have separate queues. The baseline's binary rows, direct JSON encoding,
strict JWT validation and prepared statements are retained.

* **Shared reads:** array parameters and request ordinals combine requests already
  collected by one worker. Global/tag/author/favorited pages enrich distinct
  articles once, sharing identical page selection and capped filter counts.
  Repeated article reads and comment threads share common content. Favorite and
  follow flags remain per viewer. Empty pages retain their counts.
* **Conservative selection:** shared enrichment is used only when at least half
  the requests have duplicate non-viewer arguments; other reads use ordinary
  statements. There is no timer-based read collection delay.
* **Tag fan-out:** only recipients already waiting in a collected batch share its
  fresh tag read. A subsequent request causes another database read.
* **Compatible routing:** bounded key and family affinity applies to queued work,
  with least-loaded and queue-age fallbacks. A read collection window has an
  absolute deadline; incoming requests cannot keep extending it.
* **Metadata:** distinct article, author and tag IDs are enriched inside the same
  SQL execution. Ordinary list enrichment and favorite-count strategies remain
  independently selectable for comparisons.
* **Feed:** a bounded recent prefix is accepted only when it supplies the complete
  requested page including offset. Sparse or deeper feeds use the full reference
  selection in the same snapshot.
* **Pipeline writes:** ready flights share a socket flush while retaining separate
  Sync/commit boundaries and conservative recovery after partial sends.
* **HTTP:** parsed fields are rebased onto owned input before arena reuse; workers
  reuse the validated frame. The formatted HTTP Date is reused within a second.
* **Durable responses:** results wait for their synchronization boundary.
  Favorite toggles fetch the resulting article in the same write flight after
  the mutation. Article creation/update fetch their returned article on the
  writer connection after commit.
* **Error recovery:** write pipelines use prepared Bind/Describe/Execute messages
  to avoid stale cached descriptions after skipped operations. Read pipelines
  using cached descriptions reconnect after SQL errors. Confirmed rollbacks retry
  individually; uncertain writes are never replayed, including server termination.
* **Timer wheel:** one intrusive timer node per socket replaces descriptor-table
  deadline scans, including correct rescheduling across wheel rotations.
* **Memory:** common requests use 1 KiB inline slots. Idle sockets retain no
  request/response buffers. Oversized result buffers and input references are released after completion;
  descriptor tables, request slots, and unsent output are bounded.
* **Bounded hashing:** saturation does not spawn extra bcrypt workers. Every new
  hash uses a fresh salt and cost 10; every login verifies its stored hash.
  Four same-cost hashes use an interleaved C++ path in one cgo call when all
  passwords are ASCII. Other byte sequences use the compatible pure-Go path.
  No result is cached and bcrypt cost is never reduced.
  JWT expiry checks avoid overflowing when converting large dates to nanoseconds.

No database data, response, password result, or token verification is cached
between requests. Only templates, key setup, connections, prepared statements and HTTP Date metadata
survive. Session settings use generic plans, disable JIT and per-query parallel
workers, and keep UTC. No schema, server durability/configuration, CPU affinity,
or kernel settings are changed. Input and slow-output bounds are inherited from
the baseline reactor. Idle keep-alive is 75 seconds.

## Configuration

Defaults are initial choices, pending measurements on official hardware.
GOMAXPROCS is respected normally. Total database connections must be at most 95.

| Variable | Default | Purpose |
|---|---:|---|
| DB_READ_CONNS / DB_WRITE_CONNS | min(8,max(2,GOMAXPROCS)) / 2 | Separate database owners |
| READ_SQL_BATCH | 1 | 0 disables shared SQL |
| READ_AFFINITY | 1 | 0 selects least-loaded routing |
| READ_ROUTE_SLACK | 8 | Maximum additional pending jobs for compatible routing |
| READ_BATCH / WRITE_BATCH | 32 / 128 | Maximum requests collected per flight |
| PIPELINE_DEPTH | 2 | Maximum flights per connection |
| READ_LINGER | 50us | Absolute idle-reader collection window |
| WRITE_LINGER | 1ms | Idle writer collection wait |
| WRITE_FLUSH_INTERVAL | 10ms | Maximum idle-write collection age |
| BCRYPT_WORKERS | max(1, GOMAXPROCS/4) | Fixed hashing concurrency |
| BCRYPT_WAIT | 300ms | Maximum total request age for batch fill; sparse arrivals use at most 2ms |
| MAX_CONNECTIONS | 190000 | Further limited by available descriptors |
| MAX_INFLIGHT / MAX_QUEUED | 4096 / 8192 | Combined request-slot budget |
| GOGC / GOMEMLIMIT | 400 / 3 GiB | Go GC settings when absent |
| SQL_METADATA_BATCH | 0 | Shared author/tag enrichment for ordinary lists |
| FEED_RECENT_SCAN / FEED_SCAN_WINDOW | 0 / 512 | Live recent-prefix strategy and bound |
| PG_FAVORITE_MODE | combined | combined/separate for scalar favorite counts |
| PG_LOCAL_TLS | auto | Plain local DB transport when TLS was not explicitly requested; preserve/disable override |
| PG_PLAN_MODE | force_generic_plan | auto/generic/custom plan experiment |
| STATS_INTERVAL | 0s | Optional cumulative JSON counters |
| CPU_PROFILE | unset | Local CPU profile, flushed on graceful shutdown |
| MEMORY_PROFILE_DIR | unset | Live heap snapshots after GC cycles, plus heap/alloc profiles at shutdown |

GOMEMLIMIT is a soft Go runtime limit and excludes PostgreSQL and kernel memory.
Stats include separate read/write queue, collection, flush and Sync-wait
histograms; per-statement job/execution/sharing counts, first-result waits and
result-drain times; bcrypt batch sizes, wait and computation times; GC cycles,
allocation, heap and output use. Durations include scheduling and I/O waits;
result-drain timing is not CPU-only encoding time. Histograms use powers of two
and report cumulative counters. Database workers identify themselves in
application_name so optional local wait sampling can distinguish them.

## Checks

```bash
bash tools/check.sh
RACE=1 TEMPLATE=conduit_seed FUZZ_TIME=5s bash tools/check.sh
```

The helper uses disposable clones, runs integration tests, then invokes the
unchanged conformance runner on a fresh copy. Tests cover shared versus ordinary
SQL, viewer isolation, empty results, fresh tags, rollback isolation, later
pipeline flights, post-commit counts, concurrent HTTP requests and tag creation,
HTTP framing, timer wraparound, bcrypt compatibility, and JWT validation. Fuzz
smokes cover framing and agreement with the JWT library. Race tests require a C
compiler for Go's race runtime; the server also uses the C++ compiler for bcrypt.

## Benchmarking and PGO

```bash
bash tools/benchmark.sh baseline upstream-1
bash tools/benchmark.sh candidate candidate-1
bash tools/benchmark.sh unshared no-coalescing-1
```

Each run clones the full seed and records source hashes, configuration,
resource samples, and loadgen output under ignored `.bench/<label>/`. Labels
must be new. The seed template is never the running application's database.

Defaults: 4000 users, 10s ramp, 30s warm-up, 60s measurement, normal think time.
Override USERS, RAMP, WARMUP, MEASURE, TAIL, THINK_SCALE, and process settings.
The harness defaults all sources to GOMAXPROCS=4, 4 readers, 2 writers, and
pipeline depth 2. TEMPLATE=conduit_dev selects the small seed; custom templates
need SEEDED_ARTICLES. Same-host runs and accelerated think times establish no
leaderboard score. Inspect lg_limited and use separate load boxes for capacity.

Candidate runs produce cpu.pprof. Inspect with:

```bash
go tool pprof -top .bench/candidate-1/server .bench/candidate-1/cpu.pprof
PGO_PROFILE="$PWD/.bench/candidate-1/cpu.pprof" bash build.sh
PGO_PROFILE="$PWD/.bench/candidate-1/cpu.pprof" bash tools/benchmark.sh candidate pgo-1
```

The build defaults to `-pgo=auto` and includes `src/default.pgo`, collected from
`optimize-readers4-d` after the structural changes. `PGO_PROFILE=off` disables it;
an explicit profile path replaces it. The profile is compiler input, not an
executable. The source and dependencies are still built on the target host.
Local comparisons selected scalar ordinary-list enrichment and the reference feed
as defaults; both SQL experiments remain configurable and covered by equivalence
checks. Read collection favors CPU efficiency and adds sub-millisecond median
latency locally; use READ_LINGER=0 when prioritizing low-load latency. These
choices have not established the best settings or a capacity score on the
challenge's eight-vCPU host.

The local `control` variant uses the preserved pre-optimization source under
`.bench/optimization-control/source`; it is available only in this working copy.
`tools/monitor.py` optionally records PostgreSQL activity/wait samples using psql.
After a run, derive measured-window resources and stage-counter differences with:

```bash
python3 tools/report.py .bench/candidate-1
```
