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
| Batching | **concurrent article and comment lookups merged into one statement each** (`Batcher.scala`, fs2) | below |
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

### Batching (the DataLoader pattern, with fs2)

The two top entries merge concurrent same-kind reads into one statement. Here that is `Batcher`: a request puts its
key and a `Deferred` in a `Queue`; one fs2 stream takes whatever is queued as a chunk (`Stream.fromQueueUnterminated`,
up to 64), runs it as one `unnest(viewers, slugs) WITH ORDINALITY` statement on up to 8 sessions in parallel
(`parEvalMapUnordered`), and completes each request's `Deferred` with its own row. There is no timer: idle, a batch
is one request and nothing waits; under load, the requests that arrive while batches run form the next batch.
Nothing is cached or shared: each request gets its own row, for its own viewer, from a statement that started after
it asked (rule 5).

Applied to the article page's two lookups (article by slug, comments by slug), the most common page:

| 6,000 users, 2 runs each | req/s | p95 / p99 ms | app µs/req | Postgres µs/req |
|---|---|---|---|---|
| one statement per request | 6,881-6,959 | 463-465 / 854 | 563-570 | 469-486 |
| article lookup batched | 7,037-7,268 | 340-365 / 725-733 | 541-548 | 443-451 |
| **article and comments batched** | **7,276-7,767** | **50-337 / 113-688** | **532-536** | **420-432** |

Fewer statements save on both sides: Postgres starts fewer statements and snapshots, and the app does fewer skunk
exchanges.

## Considered and not adopted

| Idea | Why not |
|---|---|
| Pipelining many requests on one connection (top entries, Vert.x) | skunk has no pipelining (one exchange per session); more sessions and batching stand in for it |
| Binary result format | skunk is text-only |
| A hand-written Postgres client, SIMD / interleaved bcrypt | replaces the stack; interleaved bcrypt's wait windows also cost p99 in the entry that tried it |
| Tag names by primary key in list queries | measured 0.75-0.81× (slower) on Postgres 18 |
| Batching the list endpoints, group commit for writes | lists are cheaper per request already and vary in shape; writes are 5% of requests. The article page was the clear first target |
| JSON built by Postgres | moves CPU into the busiest process |
| One `GET /api/tags` result for all waiting requests | sharing a result between requests is caching (rule 5) |
| Nginx in front | ~11% of the box; direct is affordable with a 7 GB heap |
| Oracle GraalVM (Graal JIT) | the brief is the newest stable OpenJDK |
