# Findings and decisions

How this submission got its shape: what was measured, what was adopted, and what was rejected and why. The survey of
the other submissions that many of these ideas came from is in [RESEARCH.md](RESEARCH.md); the SQL rewrites, each
with its measured speed-up, are in the README's [SQL](README.md#sql) section.

The goal throughout: **idiomatic Typelevel Scala that is still competitive**. A change is adopted when it is measured
to help *and* it reads like ordinary Cats Effect / fs2 / skunk / http4s code. A hand-written Postgres wire client,
SIMD bcrypt or JSON built by Postgres are out of scope, even where the leaderboard's top entries use them.

## How it was measured

- **Postgres like the box's**: PostgreSQL 18 in Docker, configured exactly as `box/pg-conf.sh` configures it for
  16 GB and 8 cores (`shared_buffers` 4 GB, `work_mem` 9.7 MB, `max_connections` 100, …), with the **full seed**
  (2.3 GB, checked against the reference fingerprints) and a fresh copy plus `VACUUM ANALYZE` for every run.
- **The app and Postgres share 8 logical CPUs** (4 physical cores with their hyper-threads); the load generator
  (`bench/cmd/loadgen`) runs on the other 4 physical cores. Pinning to whole physical cores mattered: an earlier
  layout put the load generator on the app's hyper-thread siblings and inflated every number.
- **The JVM sees a 16 GB box** through a cgroup limit (`systemd-run --scope -p MemoryMax=16G`); JDK 27 removed
  `-XX:MaxRAM`, and the JVM sizes its heap from the cgroup.
- `-think-scale 0.2`: users think and browse 5× faster. Session length scales too, so the mix of requests, including
  the share of bcrypt logins per request, stays the workload's.
- 10 s / 2,000-user warm-up, then 20 s ramp + 40 s measured; app CPU from `/proc`, Postgres CPU from its cgroup.
  Results are judged like the benchmark: p95 < 500 ms, p99 < 1 s, errors < 1%.
- Absolute numbers are a laptop's (8 hyper-threads instead of 8 dedicated vCPUs): compare rows with each other.

## Where the CPU goes

Profiled with async-profiler under load: **bcrypt is about a third of the app's CPU** (cost 10 is mandatory; the
login share of the workload is what it is), the rest is spread over skunk's protocol (~15%), http4s and Ember (~9%),
circe (~5%) and the Cats Effect runtime, with no single hotspot. At the start the app used more CPU per request than
Postgres (521 vs 322 µs), the opposite of the leaderboard's top entries, so the app side got as much attention as
the SQL.

## Decisions

| Area | Decision | Evidence |
|---|---|---|
| Driver | **skunk 2.0.0-RC3** (the newest; RC3 cut the protocol round trips per execute) | the brief; README "Postgres access" |
| Session pool | a fixed set of sessions lent from a Cats Effect `Queue`, not `Session.pooled` | `Session.pooled` runs `UNLISTEN *` + `RESET ALL` on every return: two extra statements per request (skunk issue #877) |
| Session settings | `plan_cache_mode=force_generic_plan`, `jit=off`, `max_parallel_workers_per_gather=0`, sent at connect (rule 2 allows session settings) | other entries measured 17-30% less Postgres CPU |
| Telemetry | otel4s no-op providers, query capture and pool/protocol spans off | skunk instruments every statement otherwise |
| SQL | one statement per request, page-first lists, cheaper capped counts, CTE writes | README "SQL": up to 4× on deep pages, 1.1-1.6× on writes; two rewrites rejected for being slower |
| Batching | **concurrent article, comment and feed lookups merged into one statement each** (`Batcher.scala`, fs2) | below |
| bcrypt | Bouncy Castle `OpenBSDBCrypt` on a pool of half the cores | 5.8% faster than at.favre (6 rounds); 2 threads made logins queue (p95 824 ms) |
| Cats Effect | **compute threads = half the cores** | below |
| Sessions | **32 read + 8 write** (40 of Postgres's 100) | below |
| JVM | **OpenJDK 27**, **Parallel GC**, **heap 45% of RAM**, pre-touched | below |
| Front | direct (Ember on :80) | Nginx would take ~11% of the box; 7 GB of heap holds 100,000+ Ember connections at ~35 KB each |

### Runtime sweep (6,000 users, one change at a time from G1 / 8 compute threads / 16+4 sessions)

| Configuration | Result | p95 / p99 ms | app µs/req | Postgres µs/req |
|---|---|---|---|---|
| G1, fixed 4 GB (the doobie version's setting) | fail | 278 / 1225 | 621 | 424 |
| G1, 45% of RAM | fail | 202 / 1610 | 617 | 415 |
| Parallel, 45% | fail | 114 / 1382 | 587 | 431 |
| ZGC (generational), 45% | fail | 276 / 1289 | 667 | 431 |
| Shenandoah (generational), 45% | pass | 355 / 594 | 702 | 433 |
| G1, **4 compute threads** | pass | 106 / 623 | **568** | 410 |
| G1, 6 compute threads | fail | 116 / 1159 | 594 | 416 |
| G1, 8 + 4 sessions | pass | 213 / 320 | 620 | 408 |
| G1, **32 + 8 sessions** | pass | 106 / **180** | 597 | 442 |
| G1, 2 bcrypt threads | fail | 824 / 1860 | 627 | 439 |
| **Parallel, 4 compute threads, 32 + 8 sessions** | **pass** | **165 / 284** | **562** | 456 |
| G1, 4 compute threads, 32 + 8 sessions | pass | 206 / 351 | 578 | 457 |

- **Fewer Cats Effect threads**: Postgres runs on the same cores, and every core the app's worker threads don't
  spin on is one a Postgres backend can use.
- **More sessions**: skunk runs one exchange at a time per session (no pipelining), so at saturation more sessions
  mean less queueing for Postgres; 32 + 8 is still well under `max_connections`.
- **GC**: the concurrent collectors (ZGC, Shenandoah) cost the most CPU per request; Parallel had the cheapest app
  path. The same held, more sharply, on the 1-vCPU challenge.
- **Heap 45% of RAM** (~7 GB of 16 GB), fixed and pre-touched: Postgres needs `shared_buffers` (4 GB), 40 backends
  and page cache for the 2.3 GB of data; there is no swap, and a heap that doesn't grow after start can't push the box
  into the OOM killer mid-run.

### Would a bigger heap help, especially the concurrent collectors?

The question: with more headroom, ZGC and Shenandoah run fewer cycles, so would they catch up, and is the JVM
wasting memory the box has? Postgres's own memory can't be taken (its config, `shared_buffers` 4 GB included, is fixed
by `box/pg-conf.sh`, and rule 2 forbids server-wide changes); what a bigger heap takes is the OS's page cache and
free memory. 75% (12 GB, pre-touched) plus `shared_buffers` in use, 40 backends, JVM non-heap and the OS adds up to
the whole 16 GB, with no swap: an OOM kill risk. So the test was 45% vs 60%, interleaved, at 7,500 users:

| GC | heap | app µs/req (two runs) | p95 ms | p99 ms |
|---|---|---|---|---|
| **Parallel** | **45%** | **486 / 501** | 202 / 323 | 318 / 517 |
| Parallel | 60% | 495 / 487 | 227 / 223 | 352 / 336 |
| ZGC | 45% | 559 / 555 | 475 / 444 | 750 / 700 |
| ZGC | 60% | 542 / 556 | 398 / 437 | 628 / 684 |
| Shenandoah (generational) | 60% | 573 | 489 | 791 |

ZGC gains a little from the extra headroom (fewer cycles), but it stays ~12% more CPU per request than Parallel with
twice the tail: its per-reference load barriers cost the same at any heap size, and the GC itself was only ~3% of the
app's CPU with Parallel. Parallel doesn't change between 45% and 60%. So the heap stays at 45%: the memory above that
buys nothing measurable and moves the box toward the OOM killer.

G1, the JVM's default, measured the same way (two interleaved rounds at 7,500 users, current code):

| GC | heap | req/s | p95 ms | p99 ms | app µs/req |
|---|---|---|---|---|---|
| **Parallel** | **45%** | **9,078 / 9,038** | **210 / 219** | **331 / 335** | **484 / 487** |
| G1 | 45% | 8,845 / 8,734 | 273 / 301 | 427 / 464 | 502 / 518 |
| G1 | 60% | 8,710 / 8,779 | 322 / 284 | 493 / 440 | 519 / 511 |

G1 costs 4-7% more CPU per request with a ~30% worse tail, and more heap doesn't help it either: its write barriers
and concurrent marking threads compete with Postgres for the same cores, while Parallel's short stop-the-world young
collections don't.

**At what heap size would G1, ZGC or Shenandoah win? None, on this workload.** Profiling with the CPU split by thread
(7,500 users) separates what more heap can shrink (the collector's own threads: fewer cycles) from what it can't (the
barriers each collector adds to the application's own code, on every reference store for G1 or load for ZGC and
Shenandoah):

| GC | app CPU µs/req | of which application threads | of which GC threads |
|---|---|---|---|
| **Parallel** (45%) | **479** | 464 | 12 |
| G1 (45%) | 515 | 491 | 22 |
| ZGC (60%) | 542 | 496 | 44 |
| Shenandoah, generational (60%) | 589 | ~513 | ~73 |

Even with an infinite heap, so no GC-thread time at all, their application threads alone cost more than Parallel's
total: G1 by 12 µs (within run-to-run noise, so a tie at best), ZGC by 17, Shenandoah by 34. They would win on a
different axis, the **live set**: Parallel's full collection is stop-the-world over everything long-lived, which here
is mostly Ember's ~35 KB per open connection. At around 100,000+ open connections (several GB live) a full GC would
take seconds and break p99, and a concurrent collector would win on latency despite the CPU. This server runs out of
CPU long before that (its GC threads use 2.6% of the CPU, and the tail shows no long pauses).

### Batching (the DataLoader pattern, with fs2)

The two top entries merge concurrent same-kind reads into one statement. Here that is `Batcher`: a request puts its
key and a `Deferred` in a `Queue`; one fs2 stream takes whatever is queued as a chunk (`Stream.fromQueueUnterminated`,
up to 64), runs it as one `unnest(viewers, slugs) WITH ORDINALITY` statement on up to 8 sessions in parallel
(`parEvalMapUnordered`), and completes each request's `Deferred` with its own row. There is no timer: idle, a batch
is one request and nothing waits; under load, the requests that arrive while batches run form the next batch.
Nothing is cached or shared: each request gets its own row, for its own viewer, from a statement that started after
it asked (rule 5).

Applied first to the article page's two lookups (article by slug, comments by slug), the most common page, then to
"your feed" (each feed depends only on its viewer):

| 6,000 users, 2 runs each | req/s | p95 / p99 ms | app µs/req | Postgres µs/req |
|---|---|---|---|---|
| one statement per request | 6,881-6,959 | 463-465 / 854 | 563-570 | 469-486 |
| article lookup batched | 7,037-7,268 | 340-365 / 725-733 | 541-548 | 443-451 |
| **article and comments batched** | **7,276-7,767** | **50-337 / 113-688** | **532-536** | **420-432** |

| 7,500 users | req/s | p95 / p99 ms | app µs/req | Postgres µs/req |
|---|---|---|---|---|
| article and comments batched | 8,892 | 282 / 458 | 491 | 386 |
| **and the feed** | **9,111** | **212 / 333** | **482** | **368** |

The global article list is **deliberately not batched**: requests for the same page would get one shared result,
which is caching between requests (rule 5). The same goes for `GET /api/tags`.

Fewer statements save on both sides: Postgres starts fewer statements and snapshots, and the app does fewer skunk
exchanges. Batches also grow with load, so CPU per request *falls* as load rises, the right direction near the limit.

## Where it ended up

The most users passing on the laptop setup, at each stage:

| Stage | Passes | Fails |
|---|---|---|
| skunk port + SQL rewrites, G1 4 GB, 8 compute threads, 16 + 4 sessions | below 6,000 | 6,000 (p99 1.2 s) |
| + runtime from the sweep (Parallel GC, 45% heap, 4 compute threads, 32 + 8 sessions) | 6,000 | 7,000 |
| + article and comment lookups batched | 7,500 | 8,500 |
| + feeds batched | **8,000** (9,054 req/s, p95 387 ms, p99 606 ms) | 8,500 (p95 596 ms) |

## Lessons from the challenge owner's videos

The six videos behind both challenges are summarised at the end of [RESEARCH.md](RESEARCH.md). For this submission
they confirmed choices rather than changed code:

- **vCPUs are hyper-threads** ("one physical core can expose two hardware threads … your cloud provider will typically
  schedule your virtual CPU onto those logical CPUs"), and per-core speed varied by up to 20% between his machines. That
  is why the local runs share 4 hyper-threaded cores between the app and Postgres, and why only relative numbers count.
- **Postgres takes about half of the 8-core box** in his reference stacks (apps 27-30%, Nginx 11-12%), and the leaderboard
  entries put it at 70-80%. Our starting point was the reverse (the app cost more than Postgres per request), which is
  why the app side got as much work as the SQL: half the cores for Cats Effect, batching, fewer round trips.
- **Durability**: he flags SQLite's `synchronous=NORMAL` as a trade-off he wouldn't take in production, and notes the
  server databases fsync every commit and share the flush through group commit. Postgres does that here by default
  (`synchronous_commit = on`, which rule 6 also requires): every write the API acknowledges is on disk.
- **bcrypt off the request threads** (his Rust example used a separate blocking pool): we use a bounded pool.
- **Unbounded comment threads** grew expensive during his own runs, hence the spec's newest-100 cap, which we keep.
- **Maintainability**: he wouldn't approve most of the fastest entries as production PRs (single-file servers, unsafe
  code, coupling to database internals), which is the line this submission holds.

## Considered and not adopted

| Idea | Why not |
|---|---|
| Pipelining many requests on one connection (top entries, Vert.x) | skunk has no pipelining (one exchange per session); more sessions and batching stand in for it |
| Binary result format | skunk is text-only |
| A hand-written Postgres client, SIMD / interleaved bcrypt | replaces the stack; interleaved bcrypt's wait windows also cost p99 in the entry that tried it |
| Tag names by primary key in list queries | measured 0.75-0.81× (slower) on Postgres 18 |
| Batching the global list, tag, author and favorited lists | the global list would share results between requests (rule 5); the others are a smaller share of traffic. Feeds are batched |
| Group commit for writes | writes are 5% of requests; with 8 write sessions Postgres already groups concurrent commits |
| JSON built by Postgres | moves CPU into the busiest process |
| One `GET /api/tags` result for all waiting requests | sharing a result between requests is caching (rule 5) |
| Nginx in front | ~11% of the box; direct is affordable with a 7 GB heap |
| Oracle GraalVM (Graal JIT) | the brief is the newest stable OpenJDK |

## Robustness

Fixes from an independent review. Each was tested on a live server; conformance stays 197/197.

| Problem | Fix |
|---|---|
| One failing batched lookup failed every request in its chunk (up to 64 → 500), e.g. a NUL in a slug (Postgres 22021) | `Batcher` reruns each key of a failed batch on its own: only the bad request fails (tested: 80 concurrent lookups plus two NUL slugs → 80 × 200, 2 × 500) |
| Feed `LIMIT lim + off` overflowed int4 for an offset near `Int.MaxValue` | computed as `int8` (offset 2147483647 → 200) |
| If the batch stream ever ended, later callers waited forever | the stream restarts (and logs the error); callers wait in a queue that outlives it |
| `SessionPool` retried reconnecting forever inside the uncancelable release: during a Postgres outage releases hung | a dead session leaves an empty slot (close bounded to 5 s); whoever takes an empty slot reopens it while acquiring (cancelable, errors fail only that request). Startup opens every session but leaks nothing and still starts if some fail. Tested by killing the database's backends and blocking connections: requests failed in 3–37 ms, then all succeeded once connections were allowed again |
| `token.split('.')` dropped trailing empty parts, so `h.p.s.` was accepted | `split("\\.", -1)`, exactly three parts |
| An empty `Authorization:` header was treated as anonymous | a present header must hold a valid token, empty or not (401) |
| Request bodies were read without a limit | at most 1 MiB is read; a larger body is a 422 |
| `start.sh` failed with "JAVA_HOME: unbound variable" without /opt/jdk-27 | a clear message |

Not changed: passwords over 72 UTF-8 bytes stay a 422 on register and update. SPEC says any non-empty string, but the
conformance suite requires the 422 (`users.register.password-over-72-bytes`), and the suite wins. Logins don't check
the length; Bouncy Castle uses the first 72 bytes the same way when hashing and verifying.
