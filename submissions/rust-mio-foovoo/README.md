# Rust: raw threads + mio (epoll) + hand-rolled pipelined Postgres

**Front: direct**

No framework and no async runtime: std threads, one mio event loop (epoll, edge-triggered) per thread, `httparse` for
requests, a hand-written JSON writer, and a small Postgres client on `postgres-protocol` that pipelines prepared
statements.

## Stack

| Piece | Version |
|---|---|
| Rust | 1.99.0 (`install.sh`), edition 2024 |
| mio | 1.2.4 (epoll), socket2 0.6.5 (SO_REUSEPORT, backlog 65535) |
| httparse | 1.10.1 |
| postgres-protocol | 0.6.12 (message framing, SCRAM-SHA-256); no driver on top |
| ring | 0.17.14 (HMAC-SHA256 for HS256) |
| bcrypt | 0.19.3, cost 10 |
| serde_json | 1.0.154 (request bodies only) |
| mimalloc | 0.1.52 (global allocator) |

Release profile: `lto = "fat"`, `codegen-units = 1`; `build.sh` adds `-C target-cpu=native` (built on the box).
Exact versions are pinned in `Cargo.lock` and built with `--locked`.

## How it uses the cores

- `LOOPS` event-loop threads, by default one per four CPUs (2 on the 8-vCPU box). Each binds its own `SO_REUSEPORT`
  listener on `HOST:PORT`, so the kernel spreads connections across loops, and owns its clients and its Postgres
  connections. Loops share nothing on the request path.
- Per loop: 3 read connections (`PG_HEAVY` 1 + `PG_READ` 2) and 1 write connection (`PG_WRITE`), all registered in
  the loop's epoll: about one Postgres backend per CPU (8 on the box). More backends than cores made every statement
  slower: with 16 backends on 4 cores each statement took twice as long and a request cost ~19% more CPU, and the
  ceiling dropped from 72k to 68k users in our tests. Writes have their own connection so a commit waiting on the WAL
  flush never holds up reads queued behind it. The server refuses to start above 95 connections.
- Reads (feed and list pages included) go to the read connection with the least estimated Postgres work queued: each
  statement has a fixed cost weight (a feed counts about six point reads). A dedicated connection for the heavy
  pages drained three times slower than the others at saturation and set the p95; one mixed pool keeps every
  connection's queue equally long.
- bcrypt (cost 10 for every hash and every login verify) runs on `BCRYPT_THREADS` (2) threads at `SCHED_BATCH` +
  nice 10, so it yields to the event loops and Postgres. Up to four hashes run interleaved in one pass of a bit-exact
  EksBlowfish (`bcrypt2.rs`): one hash is a serial chain of dependent S-box loads, and four independent chains in
  lockstep keep the core busy, about 3x the hashes per CPU-second of the `bcrypt` crate (measured on an M2;
  verified bit-exact against the crate on 32k cases). The first worker holds a job up to `BCRYPT_PAIR_WAIT_MS`
  (200 ms) for others to join; the second only takes full batches or jobs older than 500 ms. Bounded queue
  (`BCRYPT_QUEUE`, 256); when full, the request gets 503.
- At saturation Postgres uses about 70% of the CPU and our process about 25% (half of that bcrypt); Postgres is the
  real bottleneck.

## Optimizations and why

- **Front: direct.** Nginx cost about 11% of the box in the video and gzips almost every response here (most are over
  1 KB). Serving directly removes the extra hop, the gzip and the second set of sockets. Idle keep-alive connections
  cost about 100 bytes of user memory each: a request is read into one 16 KiB buffer per event loop and parsed in
  place; a connection only gets its own buffer while a request is incomplete, and loses it once it has been parsed.
- **One statement (one round trip) per request.** Each list page and its capped count run as one statement
  (`WITH c AS (count) SELECT c.n, p.* FROM c LEFT JOIN LATERAL (page) p`). Comments fold the slug lookup into the same
  statement. Follow/unfollow and favorite/unfavorite are one CTE statement that writes and returns the response row
  (the favorites count adds the statement's own insert/delete, since its snapshot can't see it). Ownership-checked
  deletes and updates are `... WHERE author_id = viewer RETURNING`, with a 403/404 probe only when nothing matched.
- **Atomic article creation in one round trip.** The insert, the tag inserts and the response SELECT go as one
  pipelined group with a single Sync, which Postgres runs as one implicit transaction (`currval` ties them together
  on the one connection). Tags are inserted sorted so concurrent creates can't deadlock; a deadlock or serialization
  failure is retried once.
- **Pipelining.** Requests on a loop share its connections; all groups queued during one epoll iteration go out in
  one write. Statements are prepared once per connection; parameters and results use the binary format.
- **Shared Syncs.** Read requests queued on a connection in one iteration share one Sync (up to `READ_BATCH`, 8), so
  Postgres pays one transaction start/end and one ReadyForQuery send for all of them; each request's rows are
  released as soon as its own statements complete. A write connection keeps one Sync in flight and sends the writes
  that arrived meanwhile together (up to `WRITE_BATCH`, 32): one commit, one WAL flush, for all of them (group
  commit; `synchronous_commit` stays on and every response waits for that commit's ReadyForQuery). With a single
  write connection per loop, commits would otherwise be capped at 1 / fsync latency, e.g. 500/s on a 2 ms cloud
  disk. No explicit BEGIN is used: an error inside one would leave the session aborted for everything pipelined
  behind it. An error in a shared Sync is attributed to the request whose statement failed, which gets it; the
  others were rolled back or never ran and are sent again on their own. Sign-ups, user updates and article creates
  with tags never share a Sync (unique violations are an expected answer there, and tag inserts from different
  requests could lock in opposite orders); a deadlock or serialization failure is retried once.
- **Session settings** on our own connections: `jit = off` and `max_parallel_workers_per_gather = 0` (pgtune's 4
  workers only add latency to small OLTP statements), `statement_timeout = 9s`, `lock_timeout = 5s`.
  `plan_cache_mode = force_generic_plan`: planning cost 0.1-0.4 ms per statement, more than executing most of them,
  and in `auto` mode Postgres never switched these statements to generic plans. Generic plans need `jit = off`
  (their LIMIT $n cost estimate is above `jit_above_cost`).
- **Plan-level SQL rewrites** (verified to return byte-identical results over 177 parameter sets): tag names are
  looked up per tag through `tags_pkey` (the reference join hash-joins a seq scan of all 200 tags for every article
  row), and every list page selects its ids first so the per-row subqueries run only for returned rows, not for the
  rows OFFSET skips. Global list with offset 40: 1.68 ms to 0.36 ms; tag list 0.65 to 0.36 ms. The capped
  `articlesCount` of the global and tag lists checks for a 1000th row (`OFFSET 999 LIMIT 1`) instead of counting
  1000 index entries, and only counts exactly below the cap.
  Feed rows use `true` for `following`: membership already proves the author is followed in the same statement
  snapshot, avoiding a redundant lookup (2-4% less feed CPU in SQL-only tests; identical on 1,988 cases against the
  previous statement and the reference SQL). Empty pages retain NULL page columns through the outer join.
- **Cheap per-request work.** HS256 is verified with ring (key schedule computed once); a token whose header is the
  standard `{"alg":"HS256","typ":"JWT"}` skips the header JSON parse, any other header is decoded and must say HS256,
  and a flat claims object is scanned without a JSON parser. Responses are written by hand into one reused buffer,
  with JSON string escaping scanned 8 bytes at a time; timestamps are formatted from Postgres's binary microseconds.
- **Tried and dropped: batching concurrent point reads** into one `unnest` statement. Measured under saturation it
  gave the same capacity, the batched statements cost more Postgres time per element than single ones, and a batch
  serializes many requests on one backend.

## Where the CPU goes (measured, arm64 test VM, server + Postgres on 4 cores at their limit)

At 76-80k users (about 19.5k requests/s): Postgres about 70% of the four cores, our process about 22% (bcrypt about
9%: logins and sign-ups are ~0.1% of requests but ~65 ms each; the rest mostly kernel TCP and epoll work), kernel
softirq about 6%, idle about 6%. Our own user-space request handling is about 1%. The feed statement alone is ~40% of
Postgres time; it is already ~27% cheaper than the reference SQL. Shared Syncs averaged 2.6 requests each.

Measured ceilings on that slice (users passing p95 < 500 ms, p99 < 1 s): 68k with 16 backends, 72k with 4 backends,
80k (the top of the test ladder, p95 454 ms) with one read pool, least-work routing and shared Syncs. Most of that came
from the single pool: with routing by queue count and no shared Syncs it still held 76k (p95 361 ms vs 352 ms).

## Rules

- Every request reads Postgres while it is served; nothing is cached between requests (statement plans aside).
- Writes are committed before the response: a group's response is sent only after its ReadyForQuery.
- Every token's signature, `alg`, `exp` (and `nbf` if present) are checked on every request; bcrypt cost 10 on every
  register, login and password change.
- No DDL, no server-wide settings.

## Robustness

- A lost Postgres connection fails only its in-flight requests (503) and is reconnected in the background; other
  connections keep serving. Startup retries the connection for up to 50 s.
- A panic in a handler answers 500 for that request only.
- Limits: 16 KiB of request headers (431), 256 KiB bodies (413), 4096 queued groups per Postgres connection (503).
  `Transfer-Encoding` request bodies get 501 (neither client sends them).

## Configuration

`DATABASE_URL`, `JWT_SECRET` (required, non-empty), `HOST`, `PORT`; tunables `LOOPS`, `PG_HEAVY`, `PG_READ`,
`PG_WRITE`, `PG_ROUTE` (`work` or `count`), `READ_BATCH`, `WRITE_BATCH` (1 = one Sync per request),
`BCRYPT_THREADS`, `BCRYPT_QUEUE`, `BCRYPT_PAIR_WAIT_MS`, `BCRYPT_NICE`, `PG_PLAN_CACHE_MODE`, `STATS` (seconds
between per-loop stats lines).

## Known gaps

- The local M1 Pro measurements below use an arm64 VM and short probes; they establish neither a five-minute
  score nor performance on the challenge's eight-core x86_64 server.
- No idle or slow-request timeouts: a client that never finishes its headers keeps its socket (bounded by the
  header cap and `LimitNOFILE`).

## Validation

Existing local validation, with no new test run for PR preparation:

- Local macOS arm64: `cargo test --locked` and `cargo test --release --locked`, 22 passed in each profile
  (one SQL-dump helper ignored and separately run successfully).
- Ubuntu 24.04 arm64 VM on the M1 Pro: `test/run.sh submissions/rust-mio-foovoo`, 197/197 checks passed against
  each of `conduit_dev` and full `conduit_seed`, with defaults after the final FEED-only rewrite.
- Before that rewrite, concurrency and Postgres fault-injection checks passed, as did both-seed conformance
  with `PG_ROUTE=count READ_BATCH=1 WRITE_BATCH=1`.

## Local M1 Pro measurements

Host: MacBook Pro M1 Pro (10 cores, 32 GB). Lima VM: Ubuntu 24.04 arm64, 10 vCPUs, 16 GB, PostgreSQL 18 and
the full seed (500k articles, 100k users). The local harness restricted server plus Postgres to vCPUs 0-3 and
four load-generator processes to vCPUs 4-9, using separate loopback addresses. This CPU split belongs only to
the local experiment; the submission performs no CPU pinning.

Each probe used 60 s ramp + 60 s measured + 15 s tail:

| Revision / run | Users | req/s | p50 / p95 / p99 (ms) | Errors | Result |
|---|---:|---:|---:|---:|---|
| v4 before FEED w1 (r14, top of ladder) | 80,000 | 19,645.6 | 311.0 / 453.9 / 505.9 | 0% | PASS |
| Final FEED w1 (r16-w1, short regression probe) | 76,000 | 20,140.5 | 1.8 / 9.4 / 22.6 | 0% | PASS |

Both reported `lg_limited: no` and `behind=false`. The 76k run tested the submitted source; the 80k run predates
the FEED-only rewrite. These were separate runs under different host conditions, so their latency difference
is not evidence of a gain from w1. Neither included a five-minute hold or established a failing upper bound.
