# Zig: io_uring, own HTTP, own Postgres client, batched reads

**Front: direct**

No framework or database driver: raw `io_uring` syscalls, a hand-written HTTP/1.1 server, a hand-written PostgreSQL
protocol client (SCRAM-SHA-256, extended protocol, binary parameters and results, pipelined), a streaming JSON writer, HS256
JWTs and bcrypt. The runtime now links **libc and libdeflate**; optional gzip uses libdeflate's level-1 encoder. Production
PostgreSQL access still does not use `libpq`.

## Review status

The [latest PR #45 maintainer rerun](https://github.com/arjaythedev/multicore-server-challenge/pull/45#issuecomment-6420772705)
benchmarked **`e0cc458`** on the official 8-vCPU box: **110,000 users held for 5 minutes**, **28,835 req/s**,
p50 21.2 ms, **p95 162.4 ms**, **p99 476.7 ms** and **0.77% errors**. The submission was **merged at #2** on the
[leaderboard](../../LEADERBOARD.md). The earlier ~100 ms GET stalls and false 404s were resolved, and the server did not
restart. The 120,000-user hold failed with **2.74% errors** despite p95 of 285 ms.

The passing hold still had **66,926 `conn_closed`/EOF transport errors** (~0.8% of reads, ~0.05% of writes).
These are the official results for `e0cc458`, not measurements of any subsequent local changes.

### Current local PR #79 / #82 implementation

The backlog identified in [PR79_PR82_ANALYSIS.md](PR79_PR82_ANALYSIS.md) is now implemented locally, including the
correctness-audit fixes described below. That comparison remains a **historical, pre-implementation analysis**, not a list
of current missing features. Optional packed reads, the read coordinator, gzip, ACK delay, write arrays and bcrypt
calibration remain **off by default**; see [Configuration](#configuration) for the actual defaults and bounds.

**Final current validation:** **49/49 native units in both ReleaseSafe and ReleaseFast**, both production builds,
**88/88 explicit full-seed configurations** (the base 20 cases × four modes, plus two combined-feature cases × four modes),
both exact repository verifiers (**197/197 each**), real low-memlock recovery and SQL regressions all passed. Production
binaries were unchanged between the 80-case sweep and the eight-case publication gate. One recovered PostgreSQL tag-insert
deadlock is documented in the reports; all 200 affected concurrent writers completed with correct persisted totals and
zero bad responses. An earlier `final_suite.py` sweep used the **development seed**, not the full seed, and remains separate.

The final local five-minute hold completed **3,175,759 measured requests with zero errors**, p95 **1.457 ms**, p99
**3.079 ms**, not LG-limited. The final ABBA comparison was essentially flat (**+0.28%** at the tested offered load),
not proof of a throughput or capacity gain. See [OPTIMIZATION_REPORT.md](OPTIMIZATION_REPORT.md) and
[VERIFICATION.md](VERIFICATION.md) for settings, artifacts, limits and phase-specific results. No new official score or
superiority over PR #79 / #82 is claimed. **Implementation and validation attribution: GPT-6.1 Sol (max effort)**,
at the author's request.

### Historical local connection EOF phase

The following evidence predates the PR #79 / #82 implementation and audit. Its **34-test / 32-configuration** totals are
retained for that phase only; the SEND_ZC fallback and shutdown barrier remain in the current implementation.

A local reproduction used archived `e0cc458` with only a diagnostic warning added, a **2 MiB child-server soft
`RLIMIT_MEMLOCK`**, and the existing 6 MiB stream test. A real `SEND_ZC` completion returned `res=-12` (`ENOMEM`),
`flags=2` (`MORE`); the original error branch closed a healthy TCP connection, producing `RemoteDisconnected` while the
server stayed alive. Controls passed with the local 8 MiB default limit and with 2 MiB plus `SEND_ZC=0`.

The retained fix retries that send once with ordinary copied `SEND`, retaining the unchanged response buffer and the
zero-copy notification barrier. Transient `ENOMEM` does not disable future zero-copy sends; unsupported-operation
`EINVAL`/`EOPNOTSUPP` still disables zero-copy for the affected worker.

A second, source-proven lifetime gap involved asynchronous `SHUTDOWN`: connection retirement waited for receive, send and
zero-copy completions, but not shutdown, so `CLOSE` could release a numeric FD before queued shutdown work used it. The fix
tracks `Conn.shutdown_live` and the shutdown CQE's FD/generation, waiting for either successful or failed completion before
retirement. Poll-cancel completions use a separate ignored tag. `Conn` remains **64 bytes**, with **no additional syscall
on a successful request**.

The shutdown regression failed before the fix, then that phase's combined source passed **34/34 unit tests in both
ReleaseFast and ReleaseSafe**, cleanly with expected injected warnings quieted only in unit tests. Closed-fallback coverage
checked **24 receive/send/notification/shutdown completion permutations**. Production Fast and Safe binaries were rebuilt.
The EOF-phase combined fix passed **all 32 full-seed matrix configurations**, two additional pressure-aware adaptive runs,
and the exact repository verifier on both seeds (**197/197 each**). Actual-pressure streams passed in all four Fast/Safe ×
provided-buffer/poll combinations, including a final strict same-TCP-socket recheck. This completed the **EOF-only phase's**
local validation, not validation of the later PR #79 / #82 implementation. Those then-uncommitted fixes are included in
this follow-up contribution.

Two official-load-generator checks in that EOF phase each held **20,000 users for 120 seconds**, one at the local default 8 MiB memlock
and one deliberately constrained to 64 KiB: **1,271,735 measured requests, zero errors**, both PASS and not LG-limited.
The pressure run recovered **at least 535,895 ENOMEM sends** from intact worker-statistics snapshots; these lifetime counters
include ramp/tail. Its p95/p99 were **1.058/2.287 ms**, versus **1.093/2.303 ms** in the default-limit run. These same-host
checks are not an official capacity claim or statistically controlled comparison; details and the conservative-counter
qualification are in [VERIFICATION.md](VERIFICATION.md).

A separate Safe/2 MiB adaptive HTTP run once saw a fresh GET return EOF after chunk-abuse checks, with `zc_nomem=0`.
Subsequent HTTP/chunk and close-churn probes passed even before the shutdown fix. **The native EOF's cause is not proven**;
the shutdown gap has source and deterministic-unit proof, not a demonstrated causal reproduction of that EOF.
**Remote errno data is unavailable: neither mechanism is established as the cause of all 66,926 official EOFs, and no
120k capacity or new official score is claimed.** See [VERIFICATION.md](VERIFICATION.md) for investigation evidence and
phase-specific validation status.

### Historical PR #79 / #82 experiments before the final audit

- A full-seed ABBA comparison, with **two 2,000-user / 45-second runs per build**, averaged **13,151 req/s for the candidate
  versus 13,160 req/s for the baseline**: **no demonstrated win**.
- A separate local **20,000-user / five-minute hold**, `think-scale=0.5`, measured **3,174,038 requests**, about
  **10,580 req/s**, **p95 1.643 ms / p99 30.991 ms**, **zero errors**, and was **not LG-limited**.

Both observations are **pre-audit**, not final-binary results or official capacity evidence. Final post-audit runs are
reported separately in [OPTIMIZATION_REPORT.md](OPTIMIZATION_REPORT.md) and [VERIFICATION.md](VERIFICATION.md).

## Stack

| Piece | Version |
|---|---|
| Zig | 0.17.0 (official tarball, SHA-256 pinned in `install.sh`) |
| I/O | `io_uring` (single issuer, deferred task work, multishot accept, multishot recv on a provided-buffer ring; poll + `recv` if the kernel rejects buffer rings) |
| HTTP | own HTTP/1.1: keep-alive, pipelining, `Content-Length` and chunked bodies, half-close |
| Postgres | own protocol-3.0 client, no `libpq`; PostgreSQL 18 on the box |
| JSON | own writer (fused vectorised escape/copy, digit-pair timestamps) and strict reader for request bodies |
| JWT | HS256 with `std.crypto` HMAC-SHA256; reusable key pads and exact-issued-payload fast path, with signature, `alg` and expiry still checked on every request |
| bcrypt | own EksBlowfish, cost 10, bit-identical to `std.crypto.pwhash.bcrypt`; up to four interleaved lanes, optionally calibrated at startup |
| Compression / dependencies | libc + system libdeflate, level 1 for optional gzip; `install.sh` installs `libdeflate-dev` with `apt-get` as well as the pinned Zig toolchain |

`build.sh` runs `zig build -Doptimize=ReleaseFast -Dcpu=native` (built on the box, so SHA-NI / BMI2 paths follow the CPU).
The libc/libdeflate link requirement applies even with `GZIP=0`; install `libdeflate-dev` before building.

See [COMPETITIVE_ANALYSIS.md](COMPETITIVE_ANALYSIS.md) for historical leaderboard context and local-rig comparisons,
with the official review status kept separate from the superseded local measurements.

## How it uses the cores

- `WORKERS` defaults to ceil(CPUs/4), at least one (2 on the 8-vCPU box). **Each worker is its own process by default**,
  with its own `SO_REUSEPORT` listener, `io_uring` and Postgres connections. `PROCS=1` instead runs the HTTP workers as
  threads of one process. A process can hold at most `LimitNOFILE` (200,000) connections, so multiple processes retain
  descriptor headroom (historically, with a 30,000-descriptor limit, one process accepted 16 k clients and two accepted
  all 40 k). A small supervisor stops everything if any child exits.
- Optional **`READ_COORDINATOR=1`** keeps that multi-process HTTP layout but moves read backends and batching into a
  separate, single-threaded coordinator process. Fork-shared SPSC request/reply rings and eventfd wakeups join the
  sharing domains; writes and bcrypt stay with the HTTP processes. IPC copies and queueing remain real costs, not
  zero-copy shared object access. With default sizing on eight CPUs this is 6 shared read and 2 local write connections.
- About **one Postgres connection per CPU** (8 on the box, `DB_CONNS`), a quarter of them for writes. More backends than
  cores only add context switches and cache pressure inside Postgres: on a 6-CPU slice 36 connections cost ~20% more
  Postgres CPU than 6 at the same throughput. Depth, not width, keeps each backend busy: `PG_DEPTH=4` bounds standalone
  and grouped write depth; independent `READ_DEPTH` inherits `PG_DEPTH` (normally 4). Both clamp to 1–32. The server
  refuses to start above 95 actual connections; integer sizing can round the requested budget, so record startup counts.
- An **idle keep-alive connection costs one 64-byte table slot** (`Conn`, indexed by fd) plus its kernel socket. Receive
  buffers come from a shared provided-buffer ring and belong to a connection only while one of its requests is incomplete.
  Historical RSS measurements were ~23 MB for 100,000 idle connections and 11 MB per worker process for 50,000 busy
  users; these have not been remeasured for the current checkout.
- bcrypt runs on its own threads at normal priority (`BCRYPT_THREADS`, roughly CPUs/4 in total, rounded per HTTP process).
  The default collection window is 250 ms (`BCRYPT_WAIT_MS`) with up to four interleaved hashes. Optional startup lane
  calibration (`BCRYPT_AUTO=1`, unless `BCRYPT_LANES` is explicitly set) and idle-window bypass (`BCRYPT_IDLE_MS>0`) do not
  change thread priority. Jobs older than `BCRYPT_STALE_MS` (default 9,500 ms, clamped to 1,000–9,500) get 503 rather than
  consuming hashing CPU past the client's 10 s deadline; those rejections still count as errors.
- In the historical saturation runs (one Postgres thread, one server thread; see Historical results), the Postgres thread
  was at 80–90% and the server thread at about half: the batch planner moved the limit to Postgres CPU per request.

## Optimizations and why

- **Front: direct, with owned responses.** No Nginx hop. Normal API rendering transfers its allocation, including header
  headroom, to the connection's send lifetime instead of copying the whole response. The allocation base survives partial
  sends and is released only after send and zero-copy notification completion. Externally owned bytes still have a copied path.
  Worker-local storage retains a **256 × 4 KiB fast slab cache**, plus **11 power-of-two pool classes from 4 KiB through
  4 MiB**. Each class retains at most 64 buffers and 256 KiB, or one buffer when the class is larger than 256 KiB.
  Excess/non-class buffers and buffers above 4 MiB are freed rather than pooled. These are idle-storage bounds, not a cap
  on live responses or total RSS; reused storage is not a response/result cache.
- **Zero-copy pressure recovery.** `SEND_ZC=1` uses `IORING_OP_SEND_ZC` from `SEND_ZC_MIN` bytes (default 256). On `ENOMEM`,
  retry once with ordinary copied `SEND`, without changing the buffer, bypassing the notification barrier or disabling
  future zero-copy sends. A failed copied retry follows the ordinary close path. `EINVAL`/`EOPNOTSUPP` disables unsupported
  zero-copy sends for that worker. The historical pressure evidence and its causality limits are retained above.
- **Connection retirement.** Receive, send, zero-copy notification and asynchronous `SHUTDOWN` completion all gate
  closing/reusing the numeric FD. Success or failure of the FD/generation-tagged shutdown CQE retires that barrier;
  poll-cancel completions cannot retire it. Optional ACK socket commands have their own CQE barrier. `Conn` stays 64 bytes;
  the shutdown bookkeeping adds no successful-request syscall.
- **Failed PostgreSQL I/O lifetime.** A failed PG socket keeps its FD and in-flight send/receive buffers until **both SEND
  and RECV CQEs retire**. PG I/O is generation-tagged; stale completions cannot mutate a replacement connection. Synchronous
  `shutdown` is used only on PG failure to wake pending I/O, not on the successful-request path. Unknown-outcome writes
  are failed, never blindly replayed.
- **SWAR integer prefix router.** HTTP routing dispatches on 32-bit little-endian route prefixes (`tags`, `user`, `prof`,
  `arti`) instead of a sequence of prefix string comparisons; the remaining path and method checks still apply.
- **Zero-allocation request staging.** Both `StageItem` (reads) and `Member` (writes) embed small-size inline buffers (128 B
  and 256 B respectively) with heap fallback only for oversized bodies. Write group commit records (`WRec`) are statically
  embedded in each `PgConn`, and `BatchRec`s cycle through a pre-allocated worker slab pool, eliminating heap allocations
  across hot staging and group-commit paths.
- **Prepared binary SQL.** Most standalone requests need one statement; timestamps and integers stay binary on the PG
  wire. Favorite/unfavorite combine mutation and decoration in one CTE. Their counts reconcile the viewer's **snapshot
  membership with the requested final state**, rather than relying on `RETURNING` rows: concurrent idempotent conflicts
  can return no changed row. Array favorites apply the same rule to distinct targeted viewers, avoiding duplicate deltas.
  Publishing an article uses up to four statements in one transaction. Session settings only:
  `plan_cache_mode=force_generic_plan`, `jit=off`, `max_parallel_workers_per_gather=0`.
- **Read connection affinity.** Routing can prefer the PostgreSQL backend that recently executed the same statement kind
  when its queue depth is within a hardcoded slack of 2 of the least-loaded connection. An available idle backend always
  wins over a busy one, regardless of affinity. `READ_ROUTE_SLACK` is not a supported configuration variable.
- **SQL shaped for generic plans** (checked equal to the SPEC reference SQL, see Tests): list pages pick their ids first
  and decorate only the rows returned; per-row favorited/following checks are index probes, not hashed sub-plans over the
  viewer's whole set; tag names come from the `tags` primary key instead of a join that hashes all 200 tags per article;
  a list and its capped count are one statement (`WITH c AS (count) SELECT … LEFT JOIN LATERAL (page)`) so an empty page
  still carries the count; follow / comment / delete / update fold lookup and write into one CTE; comment threads (up to
  100 rows) test "does the viewer follow this author" against the viewer's followee set hashed once (historically -27% on a hot thread).
- **Batch-local feed proofs.** Standalone feeds resolve the viewer's followees once; per-kind, two-phase and packed batches
  reuse followee arrays and probe at most **8 batch-selected shared authors** for a 1,000th article (`OFFSET 999`). Following
  a proven-heavy author establishes the capped count of 1,000. Other viewers use an exact capped-count fallback, including
  feeds assembled from several sparse authors. Pages and empty-page counts remain independent; feed `following=true` is
  preserved. No author IDs, seed assumptions or count results are cached across batches.
- **Overlap-aware comments.** The two-phase planner shares comments only when at least two are staged and the distinct
  slug percentage is at most `COMMENTS_SHARED_PCT` (default 50, capped at 100). Low-overlap comments use the dedicated
  per-kind/single path. Packed plans always leave comments on that dedicated path.
- **Default two-phase planner; shared work is done once.** With `ADAPTIVE_WINDOW=1` (default),
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
- **Optional single-statement packed reads (`PACKED_READS=1`).** Eligible plans combine global/tag/author/favorited lists,
  feeds, single articles, profiles and tags in one statement snapshot. Distinct article entities are returned once, with
  narrow request headers containing ordered page IDs and viewer-membership arrays. JSON is rendered directly from those
  batch-owned row views, without synthesizing and reparsing PG rows; the PG receive buffer stays live until all dependent
  responses have been rendered. Comments and login/user lookups keep their dedicated paths. `PLAN_MIN`/`PLAN_MAX` still
  govern admission/capacity, small reads retain the cheap path, and a failed packed batch is retried in isolation.
- **Group commit.** A write connection runs one transaction at a time; writes that arrive while it commits wait and then
  go out together as one transaction, one WAL flush for all of them. Every response is sent after its commit. A failed group
  rolled back as a whole, so each member is retried alone (nothing is replayed after a commit). Sign-ups and profile
  updates, which fail by design on a unique violation, are never grouped. `WRITE_GROUP_MAX` defaults to 32 (clamped 1–128);
  `WRITE_WINDOW_US` defaults to 0 (no deliberate collection delay, capped at 10,000 µs). Optional `WRITE_ARRAYS=1` uses a
  homogeneous array statement for follow/unfollow, favorite/unfavorite or comment-create groups of at least two; mixed or
  ineligible groups keep individual executions. **Explicit BEGIN/COMMIT and each member's original retry wire are retained**
  for rollback/isolation, with no response before commit. The earlier laptop-disk result (20-second queues to p95 9 ms)
  predates these new knobs and is not a measurement of array writes.
- **bcrypt, 4 lanes in assembly.** One hash is ~1.07 M Blowfish blocks, each a chain of dependent S-box loads. The kernel
  (`src/bcrypt.zig`) keeps four lanes in the 15 usable registers (one shared index temp, renamed by the core), extracts bytes with
  BMI2 `rorx`, and runs the whole 521-block key-expansion loop in registers. Historical Ryzen 7 7445HS timings: 39 ms for one hash, 13.7 ms
  per hash in a full batch (compiled code spills at four lanes: 15.2 ms at three, 39 ms at four). Without BMI2 the build uses
  the compiled kernel.
- **Selective gzip and optional delayed ACKs.** `GZIP=1` uses libdeflate level 1 only when it saves body bytes; `GZIP=2`
  instead requires fewer **estimated** TCP segments, using socket MSS and a 200-byte header allowance. Both normally start
  at `GZIP_MIN=1024` body bytes (minimum configurable threshold 1024). Negotiation respects quality values and wildcard
  overrides. If identity is forbidden (`identity;q=0`), acceptable enabled gzip is forced even below that threshold or
  when it grows the response; if it cannot be sent, the response is **empty 406**, never forbidden identity. **204 stays
  bodyless and unaffected.** `GZIP=0` is the default, including the empty-406 rule when identity is forbidden.
  `ACK_DELAY=1` queues asynchronous `TCP_QUICKACK=0` after keep-alive sends, without disabling `TCP_NODELAY`; FD/generation
  lifetime waits for its CQE. `EINVAL`, `EOPNOTSUPP` or `ENOSYS` disables ACK delay for that worker. It defaults to 0.
- **Fused JSON and exact JWT fast path.** Clean SIMD string blocks are scanned and copied together; timestamps use digit
  pairs. Only the exact issued JWT payload layout uses the claims shortcut, **after signature and algorithm verification**
  and with expiry still checked. Extra/reordered claims, including `nbf`, use the general parser; security is not cached.
- **Startup result-shape validation.** Prepare/Describe checks every prepared statement's result column count and OIDs
  against its decoder expectations, at startup and reconnect. This is correctness hardening, not a measured throughput gain.
- **Writes and reads have separate connections**, so a write commit does not occupy a read backend; CPU/I/O contention
  can still affect both.
- **Robust to the box**: half-closed clients still get their response; a client holding an incomplete request for 30 s is
  closed; Postgres connections that die are replaced within a second (requests in between get 503; nothing is replayed);
  TCP keep-alive probes detect vanished peers after 10 min.

## Configuration

`DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT` as in SPEC.md. `WORKERS` defaults to ceil(CPUs/4), at least one; `PROCS` defaults
to `WORKERS` (`1` puts HTTP workers in one process). Started workers round up to a multiple of `PROCS`.
`DB_CONNS` defaults to max(4, CPUs), capped at 95; `DB_WRITE_CONNS` defaults to max(started workers, DB_CONNS/4).
Per-worker rounding/minima can change the actual total; startup rejects more than 95 actual PG connections. At most 64
workers and 64 child processes including an optional coordinator are allowed. `PIN_CPUS=0` keeps CPU pinning off.

| Read / database option | Default | Meaning / limits |
|---|---|---|
| `PG_DEPTH` | 4 | Standalone/grouped write depth, clamped 1–32 |
| `READ_DEPTH` | `PG_DEPTH` (normally 4) | Independent read depth, clamped 1–32; changing it does not change write depth |
| `PACKED_READS` | 0 | Nonzero selects the single-statement packed planner for eligible reads |
| `READ_COORDINATOR` | 0 | Nonzero adds a separate fork-shared read coordinator; retains HTTP multiprocessing |
| `READ_WINDOW_US` | 100000 | Batching hold cap, not total response time; 0 disables deliberate holding |
| `READ_HOLD_MIN` | 2048 | Dispatch without a hold at this staged count, as backend capacity permits |
| `ADAPTIVE_WINDOW` | 1 | Flush when any read backend is idle; otherwise shorten the hold by staged depth, capped by `READ_WINDOW_US`; 0 selects fixed-window mode |
| `PLAN_MIN` | 16 | Minimum eligible plan size; 0 disables planned reads, including packed plans |
| `PLAN_MAX` | 2048 | Reads per plan, clamped 1–2048; independent of the per-kind cap |
| `PLAN_SPLIT` | 0 | Nonzero divides waiting reads over backends with room instead of one plan taking the whole cap |
| `BATCH_MAX` | 64 | Per-kind reads per statement, clamped 1–256; 1 disables per-kind batching |
| `COMMENTS_SHARED_PCT` | 50 | Two-phase comment sharing when distinct slugs / staged comments is at most this percentage; capped at 100; packed plans exclude comments |

| Response / network option | Default | Meaning / limits |
|---|---|---|
| `SEND_ZC` | 1 | Nonzero enables zero-copy sends, with bounded ENOMEM retry and unsupported-operation fallback |
| `SEND_ZC_MIN` | 256 | Minimum send bytes for zero-copy eligibility; minimum 1 |
| `GZIP` | 0 | 0 = identity policy, 1 = save body bytes, 2 = save estimated TCP segments; values capped at 2; identity exclusion still requires gzip or empty 406 |
| `GZIP_MIN` | 1024 | Body-byte threshold, floored at 1024; bypassed when identity is forbidden and gzip is available |
| `ACK_DELAY` | 0 | Nonzero enables async `TCP_QUICKACK=0`; worker-local disable on unsupported kernels |

| Write option | Default | Meaning / limits |
|---|---|---|
| `WRITE_GROUP_MAX` | 32 | Members per group, clamped 1–128 |
| `WRITE_WINDOW_US` | 0 | Optional collection hold, capped at 10000 µs |
| `WRITE_ARRAYS` | 0 | Nonzero enables eligible homogeneous array mutations; explicit transaction and isolated retries retained |

| Bcrypt option | Default | Meaning / limits |
|---|---|---|
| `BCRYPT_THREADS` | Per-process share of CPUs/4, at least 1 | Normal-priority hashing threads in each HTTP process |
| `BCRYPT_LANES` | 4 | Clamped 1–4; an explicit setting suppresses auto calibration |
| `BCRYPT_AUTO` | 0 | Nonzero benchmarks real cost-10 hashes at startup to choose 1–4 lanes, unless `BCRYPT_LANES` is explicit |
| `BCRYPT_WAIT_MS` | 250 | Maximum fill-window wait for a partial batch |
| `BCRYPT_IDLE_MS` | 0 | Disabled at 0; otherwise lets the primary hasher bypass the fill window after this idle interval, without changing priority |
| `BCRYPT_STALE_MS` | 9500 | Stale queued-job cutoff, clamped 1000–9500 ms |

`STATS=1` prints per-worker request, batch and queue counters, including `zc_nomem`, `send_errors` and, when array writes
are enabled, `array_groups`. The pressure fallback warns **once per worker**:
`SEND_ZC returned ENOMEM; falling back to copied SEND`.

Test hooks (off by default, enabled by presence): `NO_PBUF`, `TEST_FAIL_GROUPS`, `TEST_FAIL_BATCHES` (poisons per-kind,
two-phase and packed batches).

## Tests

See [VERIFICATION.md](VERIFICATION.md) and [OPTIMIZATION_REPORT.md](OPTIMIZATION_REPORT.md) for completed final post-audit
results and phase-specific evidence. The commands below are reproduction procedures requiring an available test seed.
[Review status](#review-status) separates the official `e0cc458` score, historical EOF checks, pre-audit experiments and
current local validation. An official rerun of the local follow-up is still needed.

- `zig build test`: unit tests (bcrypt against `std`, JSON, JWT, HTTP framing, percent-decoding, wire protocol), plus read
  scheduling/affinity and stable batch/planner text keys, including the 127/128/129-byte inline/heap boundary. Send-pressure
  regressions cover copied-retry failure bounds, notification ordering, closed connections and future zero-copy eligibility;
  lifetime checks include the shutdown barrier and all 24 receive/send/notification/shutdown completion permutations.
  Current coverage also includes owned-response/pool reuse, ACK CQE barriers, generation-tagged PG failure/replacement,
  gzip identity exclusion/empty 406/bodyless 204, SPSC fork ordering/backpressure, packed decoding, fused escaping,
  exact JWT claims and result OID validation.
- `tests/sqldiff.py`: the SQL in `src/sql.zig` against the SPEC reference SQL on random viewers, filters, limits and offsets
  (deep and out-of-range offsets, the heaviest followers); build the dumper with `zig build sqldump` first.
- `tests/read_regression.py PORT [--latency-ms MAX_MS]`: independent fixture-backed expectations for articles, comments,
  profiles and filtered lists; synchronized 64-client bursts cover distinct, duplicate, missing and boundary-length keys.
- `tests/batchdiff.py REF_PORT TEST_PORT`: concurrent read responses compared byte for byte with a non-batching server;
  `HOT=1` makes the batches duplicate-heavy. `tests/planner_check.sh` is the older standalone planner/failure check.
- `tests/writetest.py PORT [CLIENTS]`: defaults to 200 concurrent writers; checks immediate article/comment/profile
  visibility and independently persisted totals, including with `TEST_FAIL_GROUPS=1`.
- `tests/httptest.py PORT`: raw-socket HTTP framing, pipelining, half-close, malformed/oversized input and smuggling guards;
  also 32 concurrent clients × 32 close/reopen cycles, checking 2,048 responses with no automatic retries.
- `tests/streamtest.py PORT`: large heap-backed writes/responses, partial sends, ordered pipelines and abandoned readers;
  also 16 concurrent persistent clients each reading a large/small/large sequence on the same TCP socket, with no automatic
  client retry or reconnect allowed.
- `tests/reconnect.py PORT`: deliberately terminates the application's same-role backends in its test database and checks
  recovery. Never run this against production.
- `tests/feed_caps.py PORT`: 64 synchronized fixture-backed checks for empty/999/1000/1001 feeds, a 1+999 sparse-author
  fallback, deep/empty pages and independent article/flag expectations. Uses `DATABASE_URL` or normal `PG*` settings,
  `psql` and the server's `JWT_SECRET`; run only against a disposable test database.
- `tests/perf_features.py PORT`: run with `GZIP=1` or `2`; independently decompresses large article/comment responses,
  checks UTF-8/escapes, q-values/wildcards, forced small gzip, empty 406, same-socket negotiation and bodyless 204.
- `tests/favorite_counts.py --dsn DSN`: standalone SQL regression using the actual single/array favorite statements,
  binary OIDs, duplicate targets and normal/idempotent add/delete, including independently confirmed concurrent conflict
  waits with blocker COMMIT/ROLLBACK. It defines 16 cases (eight conflict waits); this is separate from the matrix runner.
  Requires Zig and **libpq via Python `ctypes` for tests only**, not a production libpq dependency. Use an explicit
  disposable-database DSN; `--save-sql` / `--sql-file` support red/green replay.

### Matrix runner

`tests/verify.py` runs the official Go conformance suite and fixture-backed read regressions in **22 cases per invocation**:

- Existing modes: `adaptive`, `per-kind`, `planner`, `split`, `failed-per-kind`, `failed-planner`, `failed-writes`, `threads`.
- Added read modes: `packed`, `failed-packed`, `depth1`, `coordinator`, `coordinator-failed`, `coordinator-threads`.
- Added write/CPU modes: `write128`, `failed-arrays`, `bcrypt-auto`.
- Added network modes: `network`, `network-segments`, `coordinator-network`.
- Combined publication modes: `all-features`, `failed-all-features`.

Fixed-window read cases use 20 ms to exercise batching. The 11 cases `per-kind`, `planner`, `split`, `failed-per-kind`,
`failed-planner`, `packed`, `failed-packed`, `depth1`, `coordinator`, `coordinator-failed` and `coordinator-threads` also run
feed-cap fixtures and byte-for-byte comparisons with `HOT=0` and `HOT=1`. Failure cases must log the injected failure.
`adaptive` adds idle and busy-backend-release scheduling checks, HTTP/stream tests, writes and backend recovery;
`failed-writes`, `write128` and `failed-arrays` also run concurrent writers. The latter two must show nonzero array-group
counters. Network cases add independent gzip, HTTP and stream checks; `coordinator-network` also tests backend recovery.
`threads` and `coordinator-threads` exercise multiple HTTP workers in one process. Both combined modes enable the read
coordinator, packed reads/depth 1, gzip mode 2, ACK delay, 128-member array writes/1 ms collection and bcrypt calibration/idle
policy together. They add feed/differential, writer, gzip, HTTP, stream and backend-recovery checks, require actual arrays
and calibration in both workers, and prove both failure injections in `failed-all-features`.

Unit tests, SQL differential checks and `favorite_counts.py` are separate. Twenty-two cases × Fast/Safe × normal/fallback =
**88 configurations**, verified as the original 80 plus eight added combined-feature runs on the same production binaries.
This is distinct from the historical eight-case / 32-configuration matrix; results must identify the seed and binary.

Requirements:

- Python 3.10+ (no third-party Python packages), `psql` on `PATH`, a libc/libdeflate-linked server build and PostgreSQL with a
  challenge-seeded template database (`--template`, default `conduit_dev`; examples below use `conduit_seed`).
- Noninteractive admin access through the usual `PGHOST`, `PGPORT`, `PGUSER` and authentication settings (for example,
  `.pgpass`): privileges to clone the chosen template, create/drop databases, lock tables and inspect backend activity.
  A local test superuser suffices. The template must have no active connections while it is cloned.
- The seed's `conduit/conduit` application role and TCP access to PostgreSQL. The runner constructs the clone's
  `DATABASE_URL` using `PGHOST`/`PGPORT` (default `127.0.0.1:5432`; a Unix-socket `PGHOST` also uses TCP loopback for the app).
- Go and the repository's `../../bench` sources: by default the runner builds `./cmd/conformance` there. Supply an
  already-built official binary with `--conformance` to skip that build and the Go requirement.
- For the constrained-memlock pressure check, run the application unprivileged and without `CAP_IPC_LOCK`, which can
  bypass the limit. The inherited hard memlock limit must allow the requested soft limit.

Run from this submission directory, after configuring PostgreSQL admin access:

```sh
bash build.sh
python3 tests/verify.py --template conduit_seed --output zig-out/verification
python3 tests/verify.py --template conduit_seed --case adaptive --memlock-bytes 2097152 --output zig-out/verification-memlock

zig build -Doptimize=ReleaseSafe -Dcpu=native --prefix zig-out/safe
python3 tests/verify.py --template conduit_seed --binary zig-out/safe/bin/conduit --fallback --output zig-out/verification-safe-fallback
```

`--fallback` sets `NO_PBUF=1` and `SEND_ZC=0`, forcing poll/recv and ordinary sends. `--binary` defaults to `bin/conduit`;
`--port` defaults to 3101 and reserves that port and the next for the reference and test servers. Repeat `--case` to
select cases (for example, `--case packed --case failed-packed`); omit it to run all **22**. To reuse the official binary
from the first example, pass `--conformance zig-out/verification/conformance`.

`--memlock-bytes 2097152` sets a **2 MiB soft `RLIMIT_MEMLOCK` only on child servers**, not on the runner or PostgreSQL.
The constrained-memlock `adaptive`, `all-features` and `failed-all-features` cases require the actual `SEND_ZC` `ENOMEM` warning when zero-copy is enabled, rather
than assuming the configured limit caused pressure. Keep `SEND_ZC=1` for this check. `--fallback` sets `SEND_ZC=0` and
therefore does not exercise zero-copy pressure and skips that assertion.

Every case gets a **fresh disposable clone**, shared only by its reference and test servers, because conformance mutates
seeded rows and uses fixed usernames. The template is not modified. Cleanup stops the servers and drops the clone;
per-check logs, server logs and `summary.json` remain under `--output` (default `zig-out/verification`), including on failure.
Use a dedicated test PostgreSQL instance: the scheduling checks take a table lock, and the reconnect check terminates
application backends in the clone.

## Historical results (local rig; superseded)

> These tables predate the adaptive-flush, lookup-key lifetime, EOF and PR #79 / #82 follow-up changes. They are retained
> as experiment history, not measurements of current defaults, official passing results or current leaderboard comparisons.
> See [VERIFICATION.md](VERIFICATION.md) for local validation and [Review status](#review-status) for the separate official
> `e0cc458` result (merged at #2). The 100 ms latency trade-off below describes the historical build, not current idle dispatch.

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
- **Merging the planner's statements into fewer statements (assessment at the time)**: measured per-statement overhead
  was 1–3 µs (the largest, the global count, 60 µs per plan), so it was not pursued in that historical phase. The later
  optional packed path removes phase boundaries and duplicate row movement too; this old estimate is not its evaluation.
- **Oldest-first selection across kinds** is kept (it prevents a late kind from waiting behind a capped batch), though it
  made no measurable difference on its own.

## Rules

No response, query-result, table, JWT-verification or bcrypt-result cache survives a request/batch (rule 5). Feed proofs
and entity/viewer sharing are batch-local; reusable buffers, connections, prepared statements, HMAC key pads and optional
startup bcrypt calibration do not cache request results. Every write is committed before
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
  not drive much beyond 40,000 users cleanly. They do not establish the local follow-up's capacity on the official box or
  supersede the scored `e0cc458` hold. Pre-audit PR #79 / #82 runs likewise do not validate final audited binaries.
- Optional packed/coordinator/network/write/bcrypt policies are implemented, not proven universally faster. The coordinator
  adds IPC copying/queueing; gzip mode 2 estimates segment savings rather than measuring actual packets. Full-seed final
  validation and an official capacity rerun remain separate from the recorded native unit/build passes.

