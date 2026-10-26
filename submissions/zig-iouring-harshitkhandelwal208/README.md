# Zig: io_uring, own HTTP, own Postgres client, batched reads

**Front: direct**

No framework, no libc, no driver: raw `io_uring` syscalls, a hand-written HTTP/1.1 server, a hand-written PostgreSQL
protocol client (SCRAM-SHA-256, extended protocol, binary parameters and results, pipelined), a streaming JSON writer, HS256
JWTs and bcrypt, all on the Zig standard library.

## Review status

The [latest PR #45 reviewer rerun](https://github.com/arjaythedev/multicore-server-challenge/pull/45#issuecomment-6414650660)
benchmarked the original `9b75e6f` on the official box: **570 users held for 5 minutes**, 151 req/s, p50 0.6 ms,
p95 90.8 ms, p99 103.4 ms, 0.75% errors and 3% target CPU. It remains **unranked** because some GETs still stalled
around 100 ms and lookups returned false 404s for existing rows.

Both symptoms were reproduced and fixed locally: adaptive dispatch now flushes staged reads at any queue depth when a
read backend is idle, and per-kind batches and planner lookups borrow text keys from stable stored items rather than
loop-local copies. See [VERIFICATION.md](VERIFICATION.md) for reproductions, regression coverage and local results.
These fixes still need an official rerun; no new official passing result or ranking is claimed.

## Stack

| Piece | Version |
|---|---|
| Zig | 0.17.0 (official tarball, SHA-256 pinned in `install.sh`) |
| I/O | `io_uring` (single issuer, deferred task work, multishot accept, multishot recv on a provided-buffer ring; poll + `recv` if the kernel rejects buffer rings) |
| HTTP | own HTTP/1.1: keep-alive, pipelining, `Content-Length` and chunked bodies, half-close |
| Postgres | own protocol-3.0 client, no `libpq`; PostgreSQL 18 on the box |
| JSON | own writer (vectorised string escape) and strict reader for request bodies |
| JWT | HS256 with `std.crypto` HMAC-SHA256; the key pads are derived once, every request still verifies signature, `alg` and `exp` |
| bcrypt | own EksBlowfish, cost 10, bit-identical to `std.crypto.pwhash.bcrypt`; hand-written x86-64 kernel runs four hashes in lock step |
| Dependencies | none (`install.sh` only unpacks the pinned Zig toolchain) |

`build.sh` runs `zig build -Doptimize=ReleaseFast -Dcpu=native` (built on the box, so SHA-NI / BMI2 paths follow the CPU); the
binary is about 760 KB.

See [COMPETITIVE_ANALYSIS.md](COMPETITIVE_ANALYSIS.md) for historical leaderboard context and local-rig comparisons,
with the official review status kept separate from the superseded local measurements.

## How it uses the cores

- `WORKERS` workers, by default one per four CPUs (2 on the 8-vCPU box). **Each worker is its own process**: its own
  `SO_REUSEPORT` listener, its own `io_uring`, its own Postgres connections; nothing is shared on the request path. A
  process can hold at most `LimitNOFILE` (200,000) connections, so one process per worker keeps the connection count
  bounded by memory and CPU instead (with a 30,000-descriptor limit, one process accepted 16 k clients and two processes
  accepted all 40 k). A small supervisor stops everything if any worker exits.
- About **one Postgres connection per CPU** (8 on the box, `DB_CONNS`), a quarter of them for writes. More backends than
  cores only add context switches and cache pressure inside Postgres: on a 6-CPU slice 36 connections cost ~20% more
  Postgres CPU than 6 at the same throughput. Depth, not width, keeps each backend busy: a connection pipelines up to 4
  batches (`PG_DEPTH`). The server refuses to start above 95 connections.
- An **idle keep-alive connection costs one 64-byte table slot** (`Conn`, indexed by fd) plus its kernel socket. Receive
  buffers come from a shared provided-buffer ring and belong to a connection only while one of its requests is incomplete.
  Historical RSS measurements were ~23 MB for 100,000 idle connections and 11 MB per worker process for 50,000 busy
  users; these have not been remeasured for the current checkout.
- bcrypt runs on its own threads at normal priority (`BCRYPT_THREADS`, default CPUs/4 in total). A login waits up to
  250 ms (`BCRYPT_WAIT_MS`) for company, then up to four hashes run interleaved; a job that waited 9.5 s is dropped
  with a 503 to avoid computing expired work past the load generator's 10.0 s deadline.
  At a lower priority the threads starve while Postgres saturates the CPUs and logins time out.
- In the historical saturation runs (one Postgres thread, one server thread; see Historical results), the Postgres thread
  was at 80–90% and the server thread at about half: the batch planner moved the limit to Postgres CPU per request.

## Optimizations and why

- **Front: direct.** No Nginx hop, no gzip; one `send` per response (head and body in one buffer). Responses >= 256
  bytes use zero-copy `io_uring` sends (`IORING_OP_SEND_ZC`) to avoid copying into the kernel socket buffer, with
  automatic fallback to standard `send` if the kernel does not support it. Response assembly uses a 256-entry 4 KB slab pool,
  recycling response buffers in $O(1)$ without general allocator churn.
- **SWAR integer prefix router.** HTTP routing dispatches on 32-bit little-endian route prefixes (`tags`, `user`, `prof`,
  `arti`) instead of a sequence of prefix string comparisons; the remaining path and method checks still apply.
- **Zero-allocation request staging.** Both `StageItem` (reads) and `Member` (writes) embed small-size inline buffers (128 B
  and 256 B respectively) with heap fallback only for oversized bodies. Write group commit records (`WRec`) are statically
  embedded in each `PgConn`, and `BatchRec`s cycle through a pre-allocated worker slab pool, eliminating heap allocations
  across hot staging and group-commit paths.
- **One statement, one round trip per request**, prepared once per connection, binary in and out (Postgres never formats a
  timestamp or integer). Favorite and unfavorite toggles fold the modifying `INSERT`/`DELETE` and article decoration into a
  single modifying CTE with delta counters (`favCols`), cutting statement execution and lock holding times in half.
  Publishing an article uses up to four statements, each in one transaction. Session settings only:
  `plan_cache_mode=force_generic_plan`, `jit=off`, `max_parallel_workers_per_gather=0`.
- **Read connection affinity.** Routing can prefer the PostgreSQL backend that recently executed the same statement kind
  when its queue depth is within a hardcoded slack of 2 of the least-loaded connection. An available idle backend always
  wins over a busy one, regardless of affinity. `READ_ROUTE_SLACK` is not a supported configuration variable.
- **SQL shaped for generic plans** (checked equal to the SPEC reference SQL, see Tests): list pages pick their ids first
  and decorate only the rows returned; per-row favorited/following checks are index probes, not hashed sub-plans over the
  viewer's whole set; tag names come from the `tags` primary key instead of a join that hashes all 200 tags per article;
  a list and its capped count are one statement (`WITH c AS (count) SELECT … LEFT JOIN LATERAL (page)`) so an empty page
  still carries the count; follow / comment / delete / update fold lookup and write into one CTE; comment threads (up to
  100 rows) test "does the viewer follow this author" against the viewer's followee set hashed once (-27% on a hot thread).
- **Reads are batched by a two-phase planner, and what requests share is done once.** With `ADAPTIVE_WINDOW=1` (default),
  all staged reads flush without a batching hold when a read backend is idle, as backend capacity permits—not just lone
  reads. This is rechecked when in-flight work completes. When all read backends are busy, the hold is capped at
  `READ_WINDOW_US` (100,000 µs by default): >= 1,024 staged reads shortens it to 10 ms, >= 512 to 25 ms, >= 256 to
  35 ms, >= 128 to 50 ms, always capped by the configured window. Earlier deadlines replace an armed timer.
  `READ_WINDOW_US=0` disables holding even in adaptive mode; `READ_HOLD_MIN` (2,048) also forces dispatch as capacity
  permits. Fixed-window behavior, including holding with an idle backend, requires `ADAPTIVE_WINDOW=0`.
  The batch (at most 2,048 reads, oldest first) goes out as a plan: phase A runs one statement per kind of request present,
  each over the batch's distinct keys (capped counts and page rows, `unnest(...) WITH ORDINALITY`); phase B enriches the
  union of the articles phase A returned, once each (author, favourite count, tag names), and resolves each viewer's favourited / following flags with one `= ANY` range
  scan per viewer. Every request's reply is assembled from those rows, in the layout its handler already reads. Nothing
  outlives its plan. If a plan fails, its requests are re-run one by one. Reads that a plan does not take (fewer than
  `PLAN_MIN`) use the per-kind path with `BATCH_MAX`. `GET /api/tags` is one execution whose rows answer every waiting
  request.
- **Group commit.** A write connection runs one transaction at a time; writes that arrive while it commits wait and then
  go out together as one transaction, one WAL flush for all of them. Every response is sent after its commit. A failed group
  rolled back as a whole, so each member is retried alone (nothing is replayed after a commit). Sign-ups and profile
  updates, which fail by design on a unique violation, are never grouped. On a laptop disk this turned 20-second write
  queues (p95 1.1 s on every write endpoint) into p95 9 ms.
- **bcrypt, 4 lanes in assembly.** One hash is ~1.07 M Blowfish blocks, each a chain of dependent S-box loads. The kernel
  (`src/bcrypt.zig`) keeps four lanes in the 15 usable registers (one shared index temp, renamed by the core), extracts bytes with
  BMI2 `rorx`, and runs the whole 521-block key-expansion loop in registers. On a Ryzen 7 7445HS: 39 ms for one hash, 13.7 ms
  per hash in a full batch (compiled code spills at four lanes: 15.2 ms at three, 39 ms at four). Without BMI2 the build uses
  the compiled kernel.
- **Writes and reads never wait for each other**: writes have their own connections, so a commit never holds up queued reads.
- **Robust to the box**: half-closed clients still get their response; a client holding an incomplete request for 30 s is
  closed; Postgres connections that die are replaced within a second (requests in between get 503; nothing is replayed);
  TCP keep-alive probes detect vanished peers after 10 min.

## Configuration

`DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT` as in SPEC.md. Optional: `WORKERS` (default CPUs/4), `PROCS` (default = `WORKERS`;
`1` runs the workers as threads of one process), `DB_CONNS` (default CPUs, max 95), `DB_WRITE_CONNS`, `PG_DEPTH` (4),
`BCRYPT_THREADS`, `BCRYPT_LANES` (4), `BCRYPT_WAIT_MS` (250), `PIN_CPUS` (0: optional CPU pinning), `STATS=1`.

Read batching: `READ_WINDOW_US` (100000: cap on the batching hold, not an end-to-end latency bound; `0` disables holding),
`READ_HOLD_MIN` (2048: dispatch without a hold once this many reads are staged, as capacity permits), `ADAPTIVE_WINDOW`
(1: flush all staged reads when any read backend is idle; otherwise shorten the hold by staged depth, never exceeding
`READ_WINDOW_US`; `0` selects fixed-window mode even with idle backends), `SEND_ZC` (1: zero-copy network sends via
`IORING_OP_SEND_ZC` for responses >= 256 bytes with automatic fallback to standard `prep_send`), `PLAN_MIN` (16: smallest
batch the planner takes; `0` turns the planner off, leaving per-kind batches only), `PLAN_MAX` (2048: reads per plan),
`PLAN_SPLIT` (0: when `1`, the waiting reads are shared over the connections that have room instead of one plan taking up
to `PLAN_MAX`), `BATCH_MAX` (64: reads of one kind per statement on the per-kind path; `1` turns that batching off).

Test hooks (off by default): `NO_PBUF`, `TEST_FAIL_GROUPS`, `TEST_FAIL_BATCHES` (poisons per-kind batches and planner plans).

## Tests

See [VERIFICATION.md](VERIFICATION.md) for the current reproduction steps and recorded local results. The commands below
are ways to run the checks, not a claim that this checkout has passed an official rerun.

- `zig build test`: unit tests (bcrypt against `std`, JSON, JWT, HTTP framing, percent-decoding, wire protocol), plus read
  scheduling/affinity and stable batch/planner text keys, including the 127/128/129-byte inline/heap boundary.
- `tests/sqldiff.py`: the SQL in `src/sql.zig` against the SPEC reference SQL on random viewers, filters, limits and offsets
  (deep and out-of-range offsets, the heaviest followers); build the dumper with `zig build sqldump` first.
- `tests/read_regression.py PORT [--latency-ms MAX_MS]`: independent fixture-backed expectations for articles, comments,
  profiles and filtered lists; synchronized 64-client bursts cover distinct, duplicate, missing and boundary-length keys.
- `tests/batchdiff.py REF_PORT TEST_PORT`: concurrent read responses compared byte for byte with a non-batching server;
  `HOT=1` makes the batches duplicate-heavy. `tests/planner_check.sh` is the older standalone planner/failure check.
- `tests/writetest.py PORT [CLIENTS]`: defaults to 200 concurrent writers; checks immediate article/comment/profile
  visibility and independently persisted totals, including with `TEST_FAIL_GROUPS=1`.
- `tests/httptest.py PORT`: raw-socket HTTP framing, pipelining, half-close, malformed/oversized input and smuggling guards.
- `tests/streamtest.py PORT`: large heap-backed writes/responses, partial sends, ordered pipelines and abandoned readers.
- `tests/reconnect.py PORT`: deliberately terminates the application's same-role backends in its test database and checks
  recovery. Never run this against production.

### Matrix runner

`tests/verify.py` runs the official Go conformance suite and fixture-backed read regressions in all eight cases:
`adaptive`, `per-kind`, `planner`, `split`, `failed-per-kind`, `failed-planner`, `failed-writes` and `threads`.
The five fixed-window read cases use a 20 ms window to exercise batching and also run byte-for-byte comparisons with
`HOT=0` and `HOT=1`. Failure cases must log the injected failure. The `adaptive` case adds idle and busy-backend-release
scheduling checks, HTTP/stream tests, concurrent writes and backend termination/recovery;
`failed-writes` also runs the write test, and `threads` uses two workers in one process. Unit tests and SQL differential
checks are separate from this runner.

Requirements:

- Python 3.10+ (standard library only), `psql` on `PATH`, a built server and a running PostgreSQL instance with a
  challenge-seeded template database (`--template`, default `conduit_dev`; examples below use `conduit_seed`).
- Noninteractive admin access through the usual `PGHOST`, `PGPORT`, `PGUSER` and authentication settings (for example,
  `.pgpass`): privileges to clone the chosen template, create/drop databases, lock tables and inspect backend activity.
  A local test superuser suffices. The template must have no active connections while it is cloned.
- The seed's `conduit/conduit` application role and TCP access to PostgreSQL. The runner constructs the clone's
  `DATABASE_URL` using `PGHOST`/`PGPORT` (default `127.0.0.1:5432`; a Unix-socket `PGHOST` also uses TCP loopback for the app).
- Go and the repository's `../../bench` sources: by default the runner builds `./cmd/conformance` there. Supply an
  already-built official binary with `--conformance` to skip that build and the Go requirement.

Run from this submission directory, after configuring PostgreSQL admin access:

```sh
bash build.sh
python3 tests/verify.py --template conduit_seed --output zig-out/verification

zig build -Doptimize=ReleaseSafe -Dcpu=native --prefix zig-out/safe
python3 tests/verify.py --template conduit_seed --binary zig-out/safe/bin/conduit --fallback --output zig-out/verification-safe-fallback
```

`--fallback` sets `NO_PBUF=1` and `SEND_ZC=0`, forcing poll/recv and ordinary sends. `--binary` defaults to `bin/conduit`;
`--port` defaults to 3101 and reserves that port and the next for the reference and test servers. Repeat `--case` to
select cases (for example, `--case planner --case failed-planner`); omit it to run all eight. To reuse the official binary
from the first example, pass `--conformance zig-out/verification/conformance`.

Every case gets a **fresh disposable clone**, shared only by its reference and test servers, because conformance mutates
seeded rows and uses fixed usernames. The template is not modified. Cleanup stops the servers and drops the clone;
per-check logs, server logs and `summary.json` remain under `--output` (default `zig-out/verification`), including on failure.
Use a dedicated test PostgreSQL instance: the scheduling checks take a table lock, and the reconnect check terminates
application backends in the clone.

## Historical results (local rig; superseded)

> These tables predate the current adaptive-flush and lookup-key lifetime fixes. They are retained as experiment history,
> not measurements of current defaults, official passing results or evidence of current leaderboard superiority.
> See [VERIFICATION.md](VERIFICATION.md) for current local validation and [Review status](#review-status) for the official
> benchmark of the original `9b75e6f`. The 100 ms latency trade-off below describes the historical build, not current idle dispatch.

**Setup.** Ryzen 7 7445HS (6 cores, 12 threads); Postgres 18.6 built from source; the full seed (500,000 articles, about
5 M favourites, 2.5 M comments); a fresh copy of the database and a restarted Postgres before every run. Load: the
challenge's `loadgen`, closed loop, think time scaled to 0.5 (3.5 s mean), 22,000 users unless stated, a 10 s ramp and a
40 s window. **Layout:** server on CPUs 0 and 6 (one core), Postgres on CPUs 1–3 and 7–9, load generator on CPUs 4, 5, 10
and 11. A run the load generator flags as limited by its own CPU is not counted (none in these tables). "Steady" drops
the first 5 seconds of the window: every submission has a start-up spike when the last users become active at the end of
the ramp (the full-window column includes it). "App" is this server's CPU per request, "Postgres" the CPU of all Postgres
processes per request, both in microseconds; raw runs are in `benchmarks/results/`.

### At 22,000 users (two rounds each)

| contender | steady p95 ms | steady p99 ms | full p95 ms | app µs/req | Postgres µs/req | total µs/req | req/s |
|---|---|---|---|---|---|---|---|
| **historical build** (100 ms window) | 138 | 147 | 138 | 33 | 46 | **79** | 11,112 |
| earlier build (`ed2e521`) | 1.0 | 1.8 | 1.8 | 34 | 147 | 181 | 11,658 |
| #47 (WorriedArrow), default window | 32 | 38 | 42 | 37 | 55 | 92 | 11,528 |
| #47, 2 ms window | 7.9 | 9.4 | 8.9 | 37 | 79 | 116 | 11,629 |
| historical build, planner off | 1.0 | 1.9 | 1.9 | 33 | 144 | 177 | 11,666 |
| #7 (Scooter1337) | 2.1 | 3.1 | 2.7 | 38 | 124 | 162 | 11,672 |
| #59 (semyonfox) | 3.3 | 4.5 | 12.5 | 36 | 105 | 141 | 11,614 |
| #64 (touhidsiddiqueeraj-bit) | 2.1 | 3.1 | 4.2 | 39 | 124 | 163 | 11,653 |
| #53 (fourneau) | 1.1 | 1.8 | 18.3 | 38 | 199 | 238 | 11,591 |
| #61 (MegaPanchamZ) | 1.9 | 4.5 | 3.2 | 58 | 161 | 218 | 11,636 |
| #58 (gilnett) | 0.9 | 2.1 | 6.9 | 41 | 172 | 214 | 11,606 |
| #52 (umitaltintas) | 1.2 | 2.6 | 1.9 | 56 | 156 | 211 | 11,664 |
| #10 (tigokraft) | 0.9 | 1.5 | 37.7 | 44 | 188 | 232 | 11,618 |
| #22 (jh-d) | 1.0 | 2.1 | 2.0 | 43 | 213 | 256 | 11,658 |

In these historical runs, the 100 ms build used 79 µs of CPU per request against 92 for #47's tested default window,
but its steady p95 was about 140 ms versus 1–3 ms for the low-latency builds. With the earlier 150 ms window it measured
77 µs and a p95 of about 200 ms (see the window tables). These are old local comparisons, not current performance or
ranking claims, and none of these tables measures the official 8-vCPU box.

### Historical window trade-off

At 22,000 users (planner, two rounds each):

| read window | steady p95 ms | steady p99 ms | Postgres µs/req | total µs/req |
|---|---|---|---|---|
| 20 ms | 31 | 34 | 55 | 87 |
| 50 ms | 72 | 77 | 48 | 79 |
| 100 ms | 136 | 144 | 45 | 76 |
| 150 ms (earlier default) | 199 | 211 | 43 | 74 |

### Saturation: how many users each build holds

Same budget for every build: one server thread (CPU 0), one Postgres thread (CPU 1), load generator on eight threads.
For these historical local experiments, a run was labelled a pass when p95 < 500 ms, p99 < 1 s and errors < 1%; this is
not an official ranking result. Beyond 28,000 connections from one address the ephemeral
port range is widened (`net.ipv4.ip_local_port_range`) for the test and restored after. The load generator on this budget
cannot drive much beyond 40,000 users, so the knees are bracketed, not measured exactly.

The read window, at 38,000 users (two rounds each):

| read window | steady p95 ms | steady p99 ms | full-window p95 ms | Postgres µs/req | total µs/req | req/s | passes |
|---|---|---|---|---|---|---|---|
| 80 ms | 357 | 373 | 390 | 47 | 76 | 18,086 | 2/2 |
| **100 ms (default at the time)** | **279** | **284** | **360** | 47 | 76 | 18,155 | 2/2 |
| 120 ms | 338 | 351 | 365 | 47 | 75 | 17,972 | 2/2 |
| 150 ms (earlier default) | 415 | 425 | 502 | 46 | 75 | 17,480 | 1/2 |

The builds, at the knee:

| build | last pass | first fail | knee (estimate) |
|---|---|---|---|
| earlier build (`ed2e521`) | 28,000 users: p95 291 ms, 13.6 k req/s | 32,000 users: p95 623 ms | ~29,500 |
| historical build, 100 ms window (default at the time) | 38,000 users: p95 360 ms (both rounds pass) | 40,000 users: p95 526 and 567 ms (both rounds fail) | ~39,000 |
| historical build, 150 ms window (earlier default) | 38,000 users: p95 477 and 527 ms (one round passes) | 40,000 users: flagged by the load generator | ~37,500 |
| #47, default window | 38,000 users: p95 397 ms, p99 477 ms, one round | 40,000 users: p95 813 ms, p99 1,408 ms, one round | ~39,000 |
| #64 | 20,000 users: p95 218 ms | not measured above 20,000 | not measured |

On this historical budget the 100 ms build and #47's tested default window held about the same number of users, about
39,000, within the noise of one or two rounds. At 38,000 users the historical build's p95 (360 ms, two rounds) was below
#47's (397 ms, one round). At 36,000 users the earlier 150 ms build had 432 ms against #47's 295 ms, also one round each,
so the latency comparison depended on load. The historical 100 ms build used about 10% less CPU per request and held
about 1.3 times the users of `ed2e521` in these runs; this does not establish current or official-box performance.

### What was tried and not kept

- **Balanced split of a plan over the free read connections (`PLAN_SPLIT=1`)** lowers p95 at 22,000 users (to about 4 ms with
  a 16-request hold and 2 ms cap, against 9 ms for the 5 ms window it was tried on) but costs about a third more Postgres time,
  because small plans carry more work each.
  Not the default; it is a knob.
- **Capping plans at 64 requests** (tried with the earlier 5 ms window) gave the same Postgres cost as that window (71 µs) and a
  p95 of 8 ms against 9 ms: no real latency gain.
- **Merging the planner's statements into fewer statements**: measured per-statement overhead is 1–3 µs (the largest,
  the global count, 60 µs per plan), so merging would save little. Not done.
- **Oldest-first selection across kinds** is kept (it prevents a late kind from waiting behind a capped batch), though it
  made no measurable difference on its own.

## Rules

No cache of any kind survives a request (rule 5: no response, query-result or table cache; no remembered JWT verification or
bcrypt result; the process keeps only connections, prepared statements and the HMAC key pads). Every write is committed before
its response (rule 6). bcrypt cost 10 on every hash and verify; HS256 signature, `alg` and `exp` checked on every request
(rule 7). Postgres is only configured through session settings; no schema, index, function or extension is touched
(rules 2, 3). Nothing detects the load test (rule 8). Needs Linux ≥ 5.19 with `io_uring` enabled (Ubuntu 24.04's 6.8 qualifies).

## Known limits

- Chunked request bodies may have at most 1024 chunks, size lines of at most 64 bytes and 4 KiB of trailers (the framing is
  re-checked whenever more bytes arrive, so what it scans is bounded). Bodies over 8 MB and heads over 16 KB are refused.
- Needs Linux 5.19 or newer for the provided-buffer ring; older kernels use the poll + `recv` path.
- Busy read backends can still cause queuing. `READ_WINDOW_US` caps the batching hold, not database execution or total
  response time; `READ_WINDOW_US=0` removes the hold but cannot remove backend contention. Adaptive mode does not hold
  staged reads behind a timer while a read backend is idle. The old 100 ms latency trade-off is historical; see
  [VERIFICATION.md](VERIFICATION.md) for current regression coverage and local results.
- The historical saturation numbers came from a single-thread budget on a 12-thread desktop; the load generator could
  not drive much beyond 40,000 users cleanly. They do not establish the fixed checkout's capacity on the official box.

