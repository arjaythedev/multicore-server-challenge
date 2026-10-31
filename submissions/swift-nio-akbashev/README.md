# Swift: SwiftNIO + PostgresNIO, no web framework

**Front: direct.**

Implements [`SPEC.md`](../../SPEC.md). One process: one thread per core for SwiftNIO's event loops, which run the
sockets, the HTTP parsing, the routing and the JSON; Swift's cooperative pool for the Postgres read lanes and the
write handlers; one `PostgresClient` connection pool. No caching across requests: every request that needs a row
reads it from Postgres, every token's HS256 signature and `exp` are re-verified, every login re-runs bcrypt (cost 10).

The same server as `swift-hummingbird-akbashev` (#145, itself started from
[`swift-hummingbird-denizakya`](../swift-hummingbird-denizakya), #9, by deni zakya), with Hummingbird and NIO's
HTTP/1 codec replaced by a small HTTP/1.1 layer of its own: in a profile of that entry, about two thirds of the
server's CPU went to the HTTP codec and the framework's per-request handling. The read batching follows the ideas of
`rust-epoll-WorriedArrow` (#131), `rust-epoll-theCatWisel` (#105) and `zig-iouring-nick-potts` (#117), and the
connection handling the shape of `rust-epoll-WorriedArrow`'s: one request at a time per connection, results posted
back to the connection's own thread, one wakeup per thread for a whole batch.

| Piece | Version |
|---|---|
| Swift | 6.4.1 (official Ubuntu 24.04 x86_64 tarball, sha256-checked), Swift 6 language mode |
| HTTP | [swift-nio](https://github.com/apple/swift-nio) 2.104.0 (`ServerBootstrap`, one `ChannelInboundHandler` per connection); HTTP/1.1 parsing and routing hand-rolled |
| JSON | hand-rolled writer straight into the response `ByteBuffer` (byte-exact `null`s, RFC 3339 ms timestamps) |
| Postgres | [postgres-nio](https://github.com/vapor/postgres-nio) 1.33.1 (`PostgresClient` pool, prepared statements) |
| JWT | HS256 via [swift-crypto](https://github.com/apple/swift-crypto) 3.12.3 (`HMAC<SHA256>`), hand-rolled compact JWS |
| bcrypt | hand-rolled (`Bcrypt.swift`): OpenBSD's algorithm, several hashes in lockstep per thread; cost 10 |
| Lifecycle | [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) 2.13.0 (`ServiceGroup`) |

All dependencies are pinned exactly in `Package.swift` (plus `Package.resolved`).

## Design notes

- **Multicore model**: one process. SwiftNIO runs one event loop per core; each connection lives on one of them for
  its whole life, and its requests are parsed, routed, checked (token, query, path) and answered there. A hot read
  (lists, feed, article, comments, profile, current user, tags) is queued for the read batcher without a task of its
  own: each event loop gathers the reads of its current tick in an outbox and hands them over together when the
  tick's I/O is done, so the loops take the batcher's lock once per tick, not once per request (per request, that
  lock was 4% of the server's CPU in a Linux profile, the loops spinning on it). The lane that answers a batch hands
  the results to their connections with one task per event loop, and each response is put together on its
  connection's loop. Writes, sign-up and login run as child tasks of the HTTP server's task group (structured: the
  server waits for them on shutdown) on Swift's cooperative pool. `NIO_GLOBAL_EXECUTOR=1` makes the event loops
  Swift Concurrency's global executor instead, so a
  handler resumed by a Postgres reply carries on on the event loop that read it. It is off by default: measured on
  Linux it took about a third off throughput (and on macOS added 10-30% CPU per request), and it needs a dynamic
  Swift runtime, since NIO finds its hook with `dlsym`, which `--static-swift-stdlib` hides. The Postgres pool size is
  `DB_POOL_SIZE` (`start.sh`: `3 × cores`, capped at 95 for the box's `max_connections = 100`).
- **bcrypt** (`Bcrypt.swift`): OpenBSD's algorithm, written in Swift so that several hashes run in lockstep on one
  core. A single bcrypt is one long chain of dependent S-box loads, so a core running one mostly waits on its L1
  cache; hashes interleaved round by round give it independent chains to overlap (`rust-epoll-WorriedArrow` does the
  same). The lockstep core is generic over the number of lanes (`<let lanes: Int>`, so each width is its own
  specialized loop), keeps every lane's 4 KB Blowfish state in an `InlineArray` on the worker's stack, and only
  `borrowing`s it in the round loop. At startup it times widths 1 to 6 at cost 6 and keeps the fastest per hash (4 on
  an M-series Mac and on Linux arm64: 12 ms per cost-10 hash against 50 ms for OpenBSD's C, one at a time); every
  hash still runs all 2^10 rounds. Hashes and verifications wait in one queue; workers (`BCRYPT_THREADS`, half the
  cores) are child tasks that prefer a `TaskExecutor` over their own threads, so no hash runs on an event loop. One
  worker takes what is waiting once a set is full or the oldest has waited `BCRYPT_WINDOW_MS`; the others only take
  full sets, so a trickle of logins isn't split into half-empty runs. A burst of logins on 5 threads: 340 a second,
  against 87 with `HummingbirdBcrypt` (OpenBSD's C). Its output is byte for byte OpenBSD's (checked against the C on
  random passwords and salts at every width) and it verifies the seed's `$2a$` hashes; it writes `$2b$`. At most
  `BCRYPT_QUEUE` hashes run or wait at once; past that a login or sign-up is a 503 at once.
- **Swift 6**: language mode 6 (strict concurrency checking) plus the upcoming features
  `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, `ExistentialAny` and `MemberImportVisibility`.
  A `@main` app whose `ServiceGroup` runs the HTTP server, the write and read lanes, the Postgres pool and the bcrypt
  workers, and on SIGTERM or SIGINT stops them in that order. Connection state is confined to its event loop
  (`NIOLoopBound`), so nothing in the server is `@unchecked Sendable` but the JWT signer (see `JWT.swift`). `build.sh` adds `-enforce-exclusivity=unchecked` for every module and, on Linux,
  `--static-swift-stdlib`. `start.sh` preloads jemalloc (installed by `install.sh`) in place of glibc malloc: about 5%
  less server CPU per request on Linux, and steadier.
- **HTTP** (`HTTP.swift`, `Server.swift`, `Routes.swift`): HTTP/1.1 with keep-alive, served directly on `HOST:PORT`
  (`0.0.0.0:80` on the box), so the server holds every user's connection itself; listen backlog 65535 (the box's
  `net.core.somaxconn`), `TCP_NODELAY`. The request head is parsed in place from the bytes NIO read (a `Span` over
  the receive buffer, which NIO reuses for the next read when nothing holds on to it): request line, then only the
  headers the server acts on (`Authorization`, `Content-Length`, `Transfer-Encoding: chunked`, `Connection`,
  `Expect: 100-continue`). Requests on a connection are answered one at a time, in order (pipelined ones wait their
  turn); heads over 64 KB are a 431 and bodies over 1 MB a 413, and a request that can't be framed (malformed, or
  both `Content-Length` and chunked) is answered and the connection closed. Routing matches the path's non-empty
  segments as bytes; path parameters are percent-decoded, and one that can't match a row (invalid UTF-8, or NUL,
  which Postgres text can't hold) is a 404 without a query; a list filter holding NUL is an empty page the same way.
  Unknown routes return the RealWorld JSON error shape. A response is one buffer: the JSON writer leaves 128 bytes
  free in front of the body, and the status line, `Content-Type`, `Content-Length` (none on a 204) and, when
  closing, `Connection: close` are written into them. A connection is closed at the first check (every 75 s) that
  finds it idle since the check before, so after 75 to 150 s idle; a request costs a counter increment, not a timer.
- **Scheduling** (Linux): the process switches to `SCHED_BATCH` at startup (no privileges needed; threads inherit it),
  so its constant small wakeups don't preempt busy Postgres backends. `SCHED_BATCH=0` turns it off.
- **JSON out**: a `~Copyable` writer appends straight into the response's `ByteBuffer`; there are no intermediate
  Strings. Text columns are decoded as slices of the row's buffer and escaped from those bytes (a `Span`) into the
  response: a string's escaped length is counted first, then it is written in one go through an `OutputRawSpan`
  (`ByteBuffer.writeWithOutputRawSpan`), one plain store per byte, where one `ByteBuffer` write call per byte showed
  up in the profile. A batch writes the JSON of every article, comment thread and the tags list it shows once, into
  one buffer, with the viewer-dependent values (`favorited`, `following`) left open; each response copies its parts
  out of it (`borrowing`, so a copy costs no retain) and fills those values in for its viewer. That took response
  rendering on the event loops from 14% of the server's CPU to 2% (the same idea as `rust-epoll-WorriedArrow`'s).
  Timestamps are decoded as integer microseconds and formatted in an `InlineArray`, so the truncation to
  milliseconds is exact (going through `Date`'s `Double` put about 1 timestamp in 9,000 a millisecond early). Rows
  are read cell by cell straight from their bytes (`RowCursor`), not through postgres-nio's generic decoding: Time
  Profiler put `row.decode((A, B, ...).self)` at 38% of the list handler.
- **Read batching** (`Reads.swift`): reads from every endpoint wait in one queue, and a lane (`READ_LANES`, one per
  core, each answering one batch at a time) answers every read waiting with one statement per kind of read present,
  each over arrays of distinct keys (`unnest(...) WITH ORDINALITY`). A batch's statements run in two rounds, each
  statement on a pooled connection of its own in a child task: first what each read is about (every kind of page,
  articles by slug, comment threads, profiles, users, the tags table), then the details of every article shown and
  the viewer flags. So a batch takes about as long as its slowest statement per round, not all of them in turn: run
  in turn on one connection, a typical batch of 600 reads took 18 ms, nearly all of it one Postgres backend working
  through the statements, while the other cores waited for the next wave of requests. (The tags table is read in the
  first round; if an article in the details names a tag created since, it is read again.) Feeds are shared between
  the viewers of a batch: one statement reads their follows, each distinct followee's article count (capped at 1,000)
  and each followee's newest articles, as many as the most any of its viewers' pages needs, and each viewer's count
  and page are put together from those (the count is the followees' counts summed and capped at 1,000, the page a
  merge of their newest-first lists): exactly the reference SQL's results, with a popular author looked at once per
  batch instead of once per follower, and about a quarter less Postgres time per feed. A feed's articles are by
  authors its viewer follows, so their `following` needs no lookup. Identical reads share a row, every article in the
  batch is enriched once (columns, tag list, favorite count, author) however many reads show it, and the
  viewer-dependent flags are one lookup per (viewer, article or author) pair. A batch goes as soon as a typical batch
  is waiting (a moving average, at least `READ_BATCH_MIN`), or once the oldest read has waited `READ_WINDOW_MS`.
  Only reads already queued when a batch is taken share it, and nothing outlives the batch (rule 5). On a local
  database shaped like the seed this took Postgres CPU per request down by about 85%. `READ_BATCHING=0` runs every
  read as its own statement instead (below).
- **Postgres**: the hot reads are prepared statements (article pages, single articles, tags, the current user,
  profiles, comments). A list's page and its count are one statement (the count LEFT JOINed to the page), so a list
  request takes one pooled connection and one round trip (with `READ_BATCHING=0`). Our
  connections set `jit = off`, `max_parallel_workers_per_gather = 0` and `plan_cache_mode = force_generic_plan` as
  startup parameters (session settings, nothing server-wide): the box's Postgres has JIT and parallel query on, and
  both cost more than they save on sub-millisecond statements, and the batches' array parameters would otherwise be
  re-planned on every execution.
- **Writes** (`Writes.swift`) are committed in groups: they wait in one queue, and each write lane (`WRITE_LANES`,
  4) takes every write waiting, runs them as one transaction on a connection of its own, and answers them all once
  `COMMIT` has returned, so a group pays for one commit instead of one per write. The write lanes' connections are a
  pool of their own (out of `DB_POOL_SIZE`), so a write never waits for a connection behind the read batches'
  statements. All of a group's favorites, unfavorites, follows, unfollows and new comments (8 of the workload's 9.7
  points of writes) run as one statement per kind, over arrays of their parameters, however they were interleaved:
  writes of different users commute, a user's own requests on one connection come one after another, and a group is
  cut where the same user would toggle the same favorite or follow twice (new comment ids are drawn in arrival
  order). So a group is about five statements however many writes it holds. With one statement per write in turn on
  one lane, as before, a lane tops out at a few hundred writes a second once a round trip costs a millisecond or two:
  with 1 ms added to every Postgres reply, that took writes to p90 1.7 s on a mixed load, against 43 ms now. If any
  statement fails (a sign-up whose username is taken), the group is rolled back and each write runs again in a
  transaction of its own, so one bad write fails alone; a lost connection fails its group without a retry, since its
  `COMMIT`'s outcome is unknown. Writes that answer with an article (favorite, create, update) read it after the
  commit through the read batcher, like any `GET` of it.
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
`BCRYPT_THREADS`), `BCRYPT_LANES` (measured at startup), `BCRYPT_WINDOW_MS` (200), `WRITE_GROUPING` (`0`: a
transaction per write; on), `WRITE_LANES` (4), `WRITE_GROUP_MAX` (256), `NIO_GLOBAL_EXECUTOR` (`1` to run Swift tasks on NIO's event loops; off), `SCHED_BATCH` (`0` to
keep the default scheduling policy; on), `READ_BATCHING` (`0`: no batching; on), `READ_LANES` (cores),
`READ_WINDOW_MS` (5), `READ_BATCH_MIN` (32), `READ_BATCH_MAX` (1024). Batches lease their statements' connections
from the same `DB_POOL_SIZE` pool as everything else.
