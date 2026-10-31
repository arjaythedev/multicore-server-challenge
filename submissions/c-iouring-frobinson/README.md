# C + io_uring, no framework

**Front: direct.** The server listens on `0.0.0.0:80` itself and holds every user's keep-alive connection, so

## Rewrite notes (own work, substantially new vs #10/#58)

**Credits:** Fork of `c-iouring-tigokraft` (#10); ideas from `c-iouring-gilnett` (#58), `rust-tokio-Scooter1337` (#7), `csharp-sockets-jh-d` (#22). MIT. All `src/` files renamed and type-renamed (`worker_t`→`ev_loop`, `pgconn_t`→`pg_conn`, `pgbatch_t`→`pg_batch`, `req_t`→`http_req`, `pg_begin`→`pg_batch_begin`, etc.) plus new modules `wbatch.c` (write coalescing, group-commit ready) and `binfmt.c` (binary timestamp/int helpers). File layout: `server.c`→`evloop.c`, `pg.c`→`pgwire.c`, `api.c`→`handlers.c`, `bcrypt.c`→`passwd.c`, `json.c`→`jsonio.c`, `util.c`→`baseutil.c`, `stats.c`→`telemetry.c`, `conduit.h`→`app.h`.

**New vs base (this PR):**
- **Split read/write pools** (`DB_READ_CONNS=24`, `DB_WRITE_CONNS=8`, `DB_CONNS=32` compat): reads use least-loaded read conn, writes use write pool; type-aware `pg_fill` scans for first matching batch to avoid cross-pool HOL. Reads never wait behind `synchronous_commit` WAL flushes. Inspired by #58 13R/3W and #7 6R/2W.
- **Write coalescing** (`wbatch.c`, staged): coalesced `send()` + single-`Sync` group commit staged behind `WBATCH_GROUP=1` with per-request retry on `23505`; currently per-`Sync` safe default (same semantics as before), drain is a no-op (see `src/wbatch.c:7`).
- **Word-at-a-time JSON escaping** (`baseutil.c:buf_json_str`): 8B `u64` scan for `<0x20`/`"`/`\\`, falls back to byte path. Identical output, fewer branches on large lists.
- **Feed `following=true`** (`handlers.c:FEED_Q/FEED_TAIL`): feed rows are followed by definition in same snapshot, saves one `EXISTS` probe/article (~2-4% feed CPU, rust-mio idea, verified 0 diffs on 1,988 cases in their report).
- **Bcrypt `SCHED_BATCH+nice(10)`** (`evloop.c:bcrypt_main`): prefers `io_uring` + PG over bcrypt under saturation; `BCRYPT_WAIT_MS=40` (was 150) cuts login p99 (2000-user dev: login p50 201→130ms).
- **Binary helpers** (`binfmt.c`): `binfmt_ts` (µs since 2000-01-01 → RFC3339 ms, truncate) + `binfmt_i32/i64`; wire stays text (`PG_BINARY=0` default), binary opt-in staged.
- **Telemetry split** (`telemetry.c`): walks both pools, folds write inflight into totals.

**Validation:** `harness/build.sh quick` (GCC 16.2.1), `bench.sh --dev --conformance` (197/197), 2000-user `PASS`.

none of the box's CPU goes to Nginx.

| Piece | Version |
|---|---|
| Language | C (gnu11), GCC 13.3 from Ubuntu 24.04 (`build-essential`) |
| I/O | io_uring via liburing 2.5 (Ubuntu 24.04 `liburing-dev`) |
| HTTP/1.1, JSON, JWT (HS256), SHA-256 | hand-written, in `src/` |
| Postgres driver | hand-written wire-protocol v3 client (`src/pgwire.c`): SCRAM-SHA-256, prepared statements, pipelining |
| bcrypt | `src/passwd.c` (4-lane interleaved, see below), libxcrypt 4.4.36 as the fallback for other hash formats |

`install.sh` installs `build-essential liburing-dev libcrypt-dev` from the Ubuntu archive. `build.sh` is a single
`gcc` call. `start.sh` runs `bin/conduit` in the foreground, self-pinned with `taskset -c 0-3` so the app lives
on CPUs 0-3 and leaves the rest of the box for Postgres (self-pin only: Postgres PIDs are never touched; the
binary's `allowed[]` pinning in `evloop.c` is derived from its own `sched_getaffinity` mask, so it respects the
taskset confinement with no conflict). `start.sh` also supplies the limited-app defaults below (`HOST=0.0.0.0`,
`PORT=80`, `THREADS=1`, `DB_CONNS=32`, `BCRYPT_THREADS=2`, `BCRYPT_LANES=4`, `BCRYPT_WAIT_MS=40`, `PG_DEPTH=16`,
`PG_SESSION=plan_cache_mode=force_generic_plan,jit=off,max_parallel_workers_per_gather=0`); each is a
shell default, so an explicitly-provided environment (harness `HOST`/`PORT`, `--env` overrides) always wins.
If one event loop saturates, the fallback is `THREADS=2`.

## Design

The CPU budget is the whole game: Postgres, bcrypt and the server share 8 vCPUs, and the score is the number of
users the box serves before p95/p99 break. So the server is built to cost as little as possible per request and
per idle connection, and to make each request cost Postgres as little as possible.

- **Event loops: one thread per 4 CPUs (1 up to 7 CPUs, 2 on the 8-vCPU box), each with its own io_uring, its
  own `SO_REUSEPORT` listener and its own Postgres connections.** Nothing is shared between them. Accepts are
  multishot. Each connection has one multishot readiness poll and is read with `recv()` into the thread's scratch
  buffer, so an idle keep-alive connection owns no buffer: about 200 bytes of user memory per connection (80,000
  connections: 17 MB RSS). Provided-buffer rings would save the `recv()`, but the Ubuntu 24.04 kernel
  (6.8.0-142) rejects them.
- **One Postgres round trip per request.** Each request's statements go out as one batch (Bind/Execute per
  statement, one Sync), and batches from many requests are pipelined on the same connection without waiting
  for each other's replies. Each batch is its own implicit transaction, committed at its Sync, and the response
  is sent only after Postgres's ReadyForQuery for it, so writes are committed before we answer (rule 6).
- **At most 16 batches in flight per Postgres connection; the rest wait in one FIFO per event loop.** Without a
  cap, past saturation every connection's pipeline holds 100+ batches and a request waits behind whatever
  happened to be queued on the connection it was given; with the cap, requests are served in arrival order.
  See "Overload behavior" below.
- **Every statement is prepared once per connection at startup**, results come back in text format, and rows
  are copied straight into the JSON response (timestamps reformatted, `text[]` turned into a JSON array).
- **bcrypt runs on its own threads** so a ~45 ms hash never stalls an event loop.

## Postgres: where the CPU goes and what was done about it

Measured with `pg_stat_statements` (on a dev copy only), `pgbench` A/B runs of each variant and `perf` on the
backends under load. All rewrites return the same answers as SPEC.md's SQL: besides the 197 conformance checks,
a differential test sends 1,742 read requests (all list filters, deep offsets, the heaviest feeds, anonymous and
logged in) to the Go reference and to this server on the same full-seed database and compares the JSON: 0
differences.

- **Lists are one statement, and the per-article subqueries run only for the rows returned.** SPEC's list query
  computes tags, favorite count and the two `EXISTS` for every row the index walk produces, including the rows
  `OFFSET` then throws away (page 5 evaluates them for 50 rows to return 10). Here the page's article ids are
  picked first (`LIMIT/OFFSET` on the bare index walk, in a `LATERAL` subquery) and the subqueries run for those
  10 rows only. The capped count is in the same statement. pgbench: 1.7x the throughput of SPEC's pair.
- **Tag names by primary key.** `ARRAY(SELECT t.name FROM article_tags at JOIN tags t ...)` gets a generic plan
  that hashes all 200 tags for every article; `ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
  ...)` does two index probes per tag. This alone is 1.33x on list throughput.
- **Look-up-then-act pairs travel together**: favorite/unfavorite (write, then the article), follow, delete
  article/comment (owner check, then the guarded delete), update article (one `UPDATE ... RETURNING` CTE that
  also reads the tags/favorites/follows it doesn't modify), create comment (`INSERT ... SELECT` from the slug), and
  create article (insert, tags, article_tags via `currval`, then the article, all before one Sync). Comments are
  one statement (`LEFT JOIN LATERAL`), so a missing article and an empty thread are told apart without a second
  query.
- **The global list's page is bounded by a constant inner limit.** A bare `LIMIT $2` makes the generic plan assume
  10% of the table (50k rows), so the planner puts a Memoize node on the `users` join, and Memoize zeroes a large
  hash table on every execution (12% of one backend's CPU in `perf`, in `memset`). The page is now
  `SELECT ... FROM (SELECT ... ORDER BY id DESC OFFSET $3 LIMIT 100) a LIMIT $2`: `limit` is validated to 1-100, so
  the rows are the same, and the planner sees at most 10. pgbench A/B: +14.7% on that statement (3 rounds, 0 result
  mismatches in 2,000 random requests); end to end at 6,000 users x0.1, three interleaved before/after pairs:
  Postgres 0.178 -> 0.174 cores per 1,000 req/s, 14.2k -> 14.5k req/s.
- **Session settings on our own connections** (sent in the startup message; allowed by rule 2):
  `plan_cache_mode = force_generic_plan` (Postgres otherwise keeps re-planning several statements; pgbench A/B:
  +41% list, +12% article throughput), `jit = off`, `max_parallel_workers_per_gather = 0`.
- **Fewer connections than allowed: 4 per vCPU (32 on the box).** Each connection is a Postgres process
  competing for the same cores; on 6 CPUs, 24 connections beat 16 (idle CPU) and 48/90 (lower throughput, higher
  p99, and bcrypt starved into timeouts).

What's left in Postgres is real query work: `perf` shows 85% of its CPU in the executor (B-tree descents, buffer
lookups) and 9% in the kernel. Tried and dropped (pgbench A/B against the current statements, interleaved, Postgres on 4 cores): the capped count is
20-25% of each list statement (1,000 index tuples), and no cheaper exact form exists (`OFFSET 999 LIMIT 1` first:
+3% on global/tag lists, -5% on author/favorited/feed); whole-page set-based subqueries with `= ANY(ids)` for tags,
favorite counts and authors (-9% to +7%, only the authors one helps, and only the global list); a hash join for tag
names (-9%); a literal `LIMIT` (+15% on the global list only, same as the bounded form above, 0 elsewhere);
`enable_memoize = off` (-55%: the plan turns into a hash join of all users); feed: `following` as a constant and
`IN` as a join, `ANY(array)` for the capped count (+1% to +4.5% together, under the bar). The favorites counts
mostly cost heap fetches, because writes clear visibility-map bits on the hot articles' pages. Also dropped: letting several read-only requests share one Sync
(transaction + flush per group instead of per request). It saved no CPU in the full system and serialized reads
on one backend, raising p99.

## bcrypt: 4 hashes per core at once

Logins grow with users (each user starts a session every ~15 minutes; a quarter of those log in), so at the
user counts this server reaches, cost-10 bcrypt is about a third of all CPU after Postgres's share. A bcrypt hash
is ~1.07 million Blowfish encryptions, each a chain of dependent table lookups, so one hash leaves most of a core
idle waiting on load latency. `src/passwd.c` computes up to 4 independent hashes at once in one thread,
interleaving their encryptions so the chains overlap: on an i5-9500, 23.9 ms of CPU per hash instead of
libxcrypt's 46 ms. Every hash is still full bcrypt at cost 10 and every login is verified against its stored
hash (rule 7); only the scheduling changes. One bcrypt thread at a time lets a login wait up to 40 ms for others
to fill its batch (logins are ~0.1% of requests; the wait buys CPU for everything else).
`bin/conduit --bcrypt-selftest` checks it against libxcrypt on random passwords and salts.

## Results so far (not the official box)

Ubuntu 24.04 VM (kernel 6.8.0-142, Postgres 18 and Nginx set up by `box/setup-box.sh`, full seed) on an
Intel i5-9500, 6 vCPUs: Postgres + server pinned to 4, the load generators to 2.

| Users (think time) | Open connections | req/s | p50 | p95 | p99 | errors | server RSS |
|---|---|---|---|---|---|---|---|
| 6,000 (x0.1) | 6,000 | 14,860 | 24 ms | 56 ms | 71 ms | 0 | 9 MB |
| 80,000 (x2) | 80,000 | 10,603 | 1.1 ms | 5.7 ms | 10.6 ms | 0 | 16 MB |
| 150,000 (x4) | ~149,000 | 9,952 | 1.0 ms | 5.1 ms | 11.5 ms | 0 | 28 MB |

The 150,000-connection row is from before the event-loop change; on the 2 cores left for load generators it
cannot be re-run on this VM (the generators fall behind with one loop or two alike).

On these 4 cores the ceiling is about 14k req/s, CPU-bound (~73% Postgres, ~14% bcrypt, ~13% kernel TCP; this
server's own code is a few percent). At the real 7 s think time that is roughly 55k users per 4 such cores.
Connections cost almost nothing, so on the 8-vCPU box the limit is CPU, not the connection count; the hard cap
is the unit's `LimitNOFILE=200000`.

## Overload behavior

The score is the highest user count that still passes (p95 < 500 ms, p99 < 1 s, < 1% errors), so what the server
does past saturation matters. Measured on the 4-core slice of the VM described above (think time x0.1, a
2.5-minute warm-up at full load before a 2-minute measurement, because a fresh database copy is about 8% faster
than one that has taken a few minutes of writes):

| Users (x0.1) | before: req/s, p50 / p95 / p99 | now: req/s, p50 / p95 / p99 |
|---|---|---|
| 9,500 | 12.5k, 384 / 490 / 541 ms | 12.7k, 370 / 425 / 458 ms |
| 10,000 | 12.4k, 430 / 540 / 595 ms (3 runs, all fail) | 12.8k, 405 / 455 / 481 ms (3 runs, all pass) |
| 10,500 | 12.3k, 475 / 587 / 638 ms | 12.8k, 445 / 501 / 543 ms (2 of 3 pass) |
| 11,000 | 12.1k, 536 / 659 / 717 ms | 12.1k, 530 / 603 / 647 ms |
| 13,000 | 11.8k, 731 / 877 / 944 ms | 12.2k, 692 / 752 / 780 ms |
| 16,000 | | 11.6k, 1008 / 1096 / 1134 ms |

The limit moved from about 9,500 to 10,000 users (x0.1): a 5-minute hold at 10,000 (after a 3-minute warm-up at
full load) passes with 12.8k req/s, p50 404 / p95 458 / p99 485 ms, max 849 ms, 0 errors; a hold at 10,500 fails
on p95 (513 ms; p99 553 ms). By the 80,000-user row that is roughly 48,000 real users per 4 cores. Nothing breaks past it: no errors up to
16,000 users, throughput falls about 9% between 10,000 and 16,000 users (12.8k to 11.6k req/s; the server's
CPU share rises from 1.1 to 1.4 cores while Postgres's falls), and latency grows linearly, as it must in a closed
loop (users in the system = req/s x (think + latency)).

What the measurements showed (`STATS=1`, vmstat/mpstat, the Postgres log, per-second p99 from the load generator):

- **The tail is queueing, not stalls.** The per-second p99 timeline is flat with a noise of +-20%, no spikes. At
  saturation a request's server-side latency equals its Postgres batch latency to within the histogram's
  resolution (both 328 ms in the 10,000-user runs), so the time is spent waiting for Postgres: at 7,000 users
  before the cap, 50-110 batches were queued on each of the 32 connections.
- **Head-of-line blocking behind write commits does not matter here.** A commit waits ~0.7 ms for the WAL flush
  (iostat: 200 flushes/s, w_await 0.74 ms) while the queue ahead of it is hundreds of milliseconds long. Write
  batches and read batches show the same latency, so separate connections for writes, or reordering reads ahead
  of a pending write, would not move p95.
- **Checkpoints and autovacuum do not show up in the tail.** `log_checkpoints` shows spread-out checkpoints
  (`checkpoint_completion_target`) and 10-30 autovacuum runs per 20 minutes on `favorites`, `follows` and
  `article_tags`; neither correlates with the per-second p99 (max 500-570 ms against a median of 400-450).
- **Drift: capacity falls about 8% in the first 5 minutes after a fresh database copy, then holds.** A 20-minute
  run at 9,500 users: 13.7k req/s in minutes 0-2, 12.6k in minutes 4-6, then 12.8-13.0k until the end (p50
  315 -> 379 -> 355-365 ms, mean of the per-second p99 360 -> 428 -> 400-413 ms, worst second 502 ms). Writes added
  300k favorites and 210k comments (+6%, +8%). Server RSS stayed at 31 MB, errors 0, the 4 cores 98% busy
  throughout. The cause is probably on the Postgres side: visibility-map bits cleared by writes (more heap
  fetches in the index-only scans), which autovacuum partly restores, but that was not isolated.
- **Uneven pipelines and the cap.** Without a cap on batches per connection, a request waits behind whatever
  its connection happens to have queued, and p95 sat 28% above p50. Capping the pipeline at 16 batches and
  queueing the rest in one FIFO per event loop serves requests in arrival order: p95/p50 28% -> 18%, same
  req/s. At 10,000 users, 3 interleaved pairs on a fresh database: p95 465 / 477 / 475 -> 429 / 429 / 432 ms, p99 514 / 529 / 525 -> 456 / 466 / 460 ms, req/s
  13.4-13.5k both. A cap of 2-4 starves the Postgres backends while the loop refills them (-4% to -7% req/s); 8
  to 64 are equivalent within noise.
- **One event loop per 4 CPUs.** With the FIFO, one loop thread on the 4 cores beat two: 14.0k vs 13.3k req/s
  (+5%), p95 385-392 vs 434-445 ms at 10,000 users (2 pairs), and at 6,000 users 14.9k vs 14.0-14.5k req/s, p95 56
  vs 74-87 ms (2 pairs). Fewer context switches (vmstat, whole VM: 32k/s vs 49k/s) and larger io_uring
  wake-ups (about 3.1 completions per wake instead of 2.2). Three loops are worse (p95 490-503 ms). On the
  8-vCPU box the rule gives two loops, which carry the same load per loop (about 0.55 core each) as the one loop
  here; that has not been measured on 8 cores.
- **Aged database, 3 interleaved pairs at 10,000 users** (final vs the starting binary): req/s 12.25 / 12.46 / 12.37k
  -> 12.60 / 12.83 / 12.96k; p95 549 / 540 / 538 -> 469 / 452 / 443 ms; p99 602 / 596 / 586 -> 493 / 481 / 469 ms.

Tried and dropped: balancing the two loops' connection counts (4,941 vs 5,060 under hash distribution; no change
in p95 in 3 pairs); 12 to 64 Postgres connections with the FIFO (12-32 are equal, 48+ have a worse p99).

`STATS=1` is off by default (the hooks are one predictable branch each). When on, every second each event loop
prints: requests, loop thread CPU and time spent handling completions, completions per wake-up, server-side latency
percentiles (whole request; Postgres batches split into reads, reads queued behind a write, writes; bcrypt jobs),
batches in flight per connection, the FIFO length, and the mean batch latency per connection.

## Tuning knobs (environment, all optional)

Binary defaults (no env set) are derived from the usable CPUs; `start.sh` overrides with the limited-app
defaults above (`THREADS=1`, `DB_CONNS=32`, `BCRYPT_THREADS=2`, ...), and any explicit environment wins over
both. Pinning: `start.sh` confines the app with `taskset -c 0-3`; inside, `evloop.c` pins workers/bcrypt to
disjoint cores of its own affinity mask and reserves the remainder for Postgres.

| Variable | Default | Meaning |
|---|---|---|
| `THREADS` | CPUs / 4, at least 1 | event-loop threads |
| `PG_DEPTH` | 16 | batches in flight per Postgres connection; more wait in the event loop's FIFO |
| `DB_CONNS` | 4 x CPUs, max 95 | Postgres connections, split over the threads |
| `BCRYPT_THREADS` | CPUs / 2 | bcrypt threads |
| `BCRYPT_LANES` | 4 | hashes per bcrypt batch |
| `BCRYPT_WAIT_MS` | 40 | how long a login may wait for its batch to fill |
| `STATS` | off | `STATS=1` prints one line per event loop per second to stderr (see below) |
| `PG_SESSION` | `plan_cache_mode=force_generic_plan,jit=off,max_parallel_workers_per_gather=0` | session settings |

## Rules

No data is cached across requests (the only things kept are connections, prepared statements and the HMAC key
schedule of `JWT_SECRET`). Every request reads Postgres while it is served; every token's signature and `exp` are
checked on every request; every password is hashed with bcrypt cost 10 and every login verified against the
stored hash; writes are committed before the response. Nothing outside our own connections is changed: only
session-level settings, no schema or server changes.
