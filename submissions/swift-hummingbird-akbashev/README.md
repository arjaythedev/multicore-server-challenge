# Swift: Hummingbird 2 + PostgresNIO

**Front: direct.**

Implements [`SPEC.md`](../../SPEC.md). One process: one thread per core for SwiftNIO's event loops, Swift's
cooperative pool for the handlers, one `PostgresClient` connection pool. No caching across requests: every request
hits Postgres, every token's HS256 signature and `exp` are re-verified, every login re-runs bcrypt (cost 10).

Started from [`swift-hummingbird-denizakya`](../swift-hummingbird-denizakya) (#9) by deni zakya, and rebuilt
around batched reads; the read batching follows the ideas of `rust-epoll-WorriedArrow` (#131),
`rust-epoll-theCatWisel` (#105) and `zig-iouring-nick-potts` (#117): reads of every endpoint answered together over
arrays of distinct keys, each article enriched once per batch, the tags table read once per batch.

| Piece | Version |
|---|---|
| Swift | 6.4.1 (official Ubuntu 24.04 x86_64 tarball, sha256-checked), Swift 6 language mode |
| HTTP | [Hummingbird](https://github.com/hummingbird-project/hummingbird) 2.28.0 (`HTTP1Channel`, trie router) |
| JSON | hand-rolled writer straight into the response `ByteBuffer` (byte-exact `null`s, RFC 3339 ms timestamps) |
| Postgres | [postgres-nio](https://github.com/vapor/postgres-nio) 1.33.1 (`PostgresClient` pool, prepared statements) |
| JWT | HS256 via [swift-crypto](https://github.com/apple/swift-crypto) 3.12.3 (`HMAC<SHA256>`), hand-rolled compact JWS |
| bcrypt | `HummingbirdBcrypt` from [hummingbird-auth](https://github.com/hummingbird-project/hummingbird-auth) 2.5.0 (OpenBSD bcrypt; cost 10) |
| Lifecycle | [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) 2.13.0 (`ServiceGroup`) |

All dependencies are pinned exactly in `Package.swift` (plus `Package.resolved`).

## Design notes

- **Multicore model**: one process. SwiftNIO runs one event loop per core for the sockets, and handlers run on Swift's
  cooperative pool. `NIO_GLOBAL_EXECUTOR=1` makes the event loops Swift Concurrency's global executor instead, so a
  handler resumed by a Postgres reply carries on on the event loop that read it. It is off by default: measured on
  Linux it took about a third off throughput (and on macOS added 10-30% CPU per request), and it needs a dynamic
  Swift runtime, since NIO finds its hook with `dlsym`, which `--static-swift-stdlib` hides. bcrypt has its own `TaskExecutor`
  on a fixed-size thread pool (`BCRYPT_THREADS`, default half the cores): the request's task moves there for the
  ~50 ms hash (`withTaskExecutorPreference` and a `@concurrent` function) and then comes back, so an event loop never
  blocks and a burst of logins can't take every core. At most `BCRYPT_QUEUE` hashes (default 40 per bcrypt thread,
  about 2 s of work) run or wait at once; past that a login or sign-up gets a 503 at once instead of a wait no client
  would sit through. The Postgres pool size is `DB_POOL_SIZE` (`start.sh`:
  `3 × cores`, capped at 95 for the box's `max_connections = 100`).
- **Swift 6**: language mode 6 (strict concurrency checking) plus the upcoming features
  `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, `ExistentialAny` and `MemberImportVisibility`.
  A `@main` app whose `ServiceGroup` runs the HTTP server, the Postgres pool and the bcrypt threads, and on SIGTERM or
  SIGINT stops them in that order. `build.sh` adds `-enforce-exclusivity=unchecked` for every module and, on Linux,
  `--static-swift-stdlib`. `start.sh` preloads jemalloc (installed by `install.sh`) in place of glibc malloc: about 5%
  less server CPU per request on Linux, and steadier.
- **HTTP**: HTTP/1.1 with keep-alive, served directly on `HOST:PORT` (`0.0.0.0:80` on the box), so the server holds
  every user's connection itself; listen backlog 65535 (the box's `net.core.somaxconn`) instead of Hummingbird's 256,
  `idleTimeout = 75 s`. Unknown routes return the RealWorld JSON error shape instead of plain text.
- **Scheduling** (Linux): the process switches to `SCHED_BATCH` at startup (no privileges needed; threads inherit it),
  so its constant small wakeups don't preempt busy Postgres backends. `SCHED_BATCH=0` turns it off.
- **JSON out**: a `~Copyable` writer appends straight into the response's `ByteBuffer`; there are no intermediate
  Strings. Text columns are decoded as slices of the row's buffer and escaped from those bytes (a `Span`) into the
  response. Timestamps are decoded as integer microseconds and formatted in an `InlineArray`, so the truncation to
  milliseconds is exact (going through `Date`'s `Double` put about 1 timestamp in 9,000 a millisecond early). Rows
  are read cell by cell straight from their bytes (`RowCursor`), not through postgres-nio's generic decoding: Time
  Profiler put `row.decode((A, B, ...).self)` at 38% of the list handler.
- **Read batching** (`Reads.swift`): reads from every endpoint wait in one queue, and a lane (one Postgres
  connection; `READ_LANES`, one per core) answers every read waiting with one statement per kind of read present,
  each over arrays of distinct keys (`unnest(...) WITH ORDINALITY`). Identical reads share a row, every article in the
  batch is enriched once (columns, tag list, favorite count, author) however many reads show it, and the
  viewer-dependent flags are one lookup per (viewer, article or author) pair. A batch goes as soon as a typical batch
  is waiting (a moving average, at least `READ_BATCH_MIN`), or once the oldest read has waited `READ_WINDOW_MS`.
  Only reads already queued when a batch is taken share it, and nothing outlives the batch (rule 5). On a local
  database shaped like the seed this took Postgres CPU per request down by about 85%. `READ_BATCHING=0` runs every
  read as its own statement instead (below).
- **Postgres**: the hot reads are prepared statements (article pages, single articles, tags, the current user,
  profiles, comments). A list's page and its count are one statement (the count LEFT JOINed to the page), so a list
  request takes one pooled connection and one round trip. Comments are read together with their article lookup in
  one round trip; favorite, follow and a new comment do their lookup and their write in one statement. Our
  connections set `jit = off`, `max_parallel_workers_per_gather = 0` and `plan_cache_mode = force_generic_plan` as
  startup parameters (session settings, nothing server-wide): the box's Postgres has JIT and parallel query on, and
  both cost more than they save on sub-millisecond statements, and the batches' array parameters would otherwise be
  re-planned on every execution.
- **Auth**: `Authorization: Token <jwt>`; the signature is checked (constant-time, with an HMAC keyed once at startup)
  on every request. Tokens shaped like the ones this server issues are parsed in place; anything else goes through
  `JSONSerialization`. Present-but-invalid is 401 even on auth-optional endpoints; absent means anonymous
  (`viewer = 0`).
- **Bodies** are parsed with `JSONSerialization` into dictionaries, so key matching is case-sensitive, unknown
  fields are ignored, and `null` vs absent is distinguished exactly as in the spec.

## Build and run

```bash
bash build.sh    # swift build -c release (+ flags above) -> ./.build/release/Conduit
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_dev JWT_SECRET=conduit-dev-secret \
  DB_POOL_SIZE=10 PORT=3104 bash start.sh
```

Environment: `DATABASE_URL`, `JWT_SECRET` (required); `HOST` (127.0.0.1), `PORT` (3000),
`DB_POOL_SIZE` (`start.sh`: min(3 × cores, 95)), `BCRYPT_THREADS` (half the cores), `BCRYPT_QUEUE` (40 ×
`BCRYPT_THREADS`), `NIO_GLOBAL_EXECUTOR` (`1` to run Swift tasks on NIO's event loops; off), `SCHED_BATCH` (`0` to
keep the default scheduling policy; on), `READ_BATCHING` (`0`: no batching; on), `READ_LANES` (cores),
`READ_WINDOW_MS` (5), `READ_BATCH_MIN` (32), `READ_BATCH_MAX` (1024). The read lanes hold `READ_LANES` of the
`DB_POOL_SIZE` connections.
