# Swift: event loops and a Postgres client of its own, no frameworks

**Front: direct.**

Implements [`SPEC.md`](../../SPEC.md). One process: one thread per core, each running an event loop of its own
(epoll; kqueue on macOS, for development) that owns its share of the connections, both HTTP and Postgres, and is the
executor of the tasks pinned to it. HTTP, routing, JSON and the Postgres wire protocol are written here; the only
dependency is swift-crypto (HMAC-SHA256 for JWTs and SCRAM). No caching across requests: every request that needs a
row reads it from Postgres, every token's HS256 signature and `exp` are re-verified, every login re-runs bcrypt
(cost 10).

The same server as [`swift-nio-akbashev`](../swift-nio-akbashev) (#147) with SwiftNIO, postgres-nio, swift-log and
swift-service-lifecycle replaced by code of its own. That one is `swift-hummingbird-akbashev` (#145, itself started from
[`swift-hummingbird-denizakya`](../swift-hummingbird-denizakya), #9, by deni zakya) with Hummingbird and NIO's HTTP/1
codec replaced by a small HTTP/1.1 layer. The read batching follows the ideas of `rust-epoll-WorriedArrow` (#131),
`rust-epoll-theCatWisel` (#105) and `zig-iouring-nick-potts` (#117), and the connection handling the shape of
`rust-epoll-WorriedArrow`'s: one request at a time per connection, results posted back to the connection's own
thread, one wakeup per thread for a whole batch.

| Piece | Version |
|---|---|
| Swift | 6.4.1 (official Ubuntu 24.04 x86_64 tarball, sha256-checked), Swift 6 language mode |
| Event loops | hand-rolled (`Loop.swift`, `Sockets.swift`): epoll + eventfd on Linux (through a small C target, `CEventLoop`), kqueue on macOS |
| HTTP | hand-rolled HTTP/1.1 parsing and routing (`HTTP.swift`, `Server.swift`, `Routes.swift`) |
| JSON | hand-rolled writer into memory it owns (byte-exact `null`s, RFC 3339 ms timestamps); bodies in with `JSONSerialization` |
| Postgres | hand-rolled (`Postgres.swift`): protocol 3.0, SCRAM-SHA-256 / MD5 / cleartext auth, extended protocol with binary parameters and results, prepared statements, pipelining |
| JWT | HS256 via [swift-crypto](https://github.com/apple/swift-crypto) 3.12.3 (`HMAC<SHA256>`), hand-rolled compact JWS |
| bcrypt | hand-rolled (`Bcrypt.swift`): OpenBSD's algorithm, several hashes in lockstep per thread; cost 10 |
| Lifecycle, logging | hand-rolled (`Lifecycle.swift`, `Log.swift`) |

All dependencies are pinned exactly in `Package.swift` (plus `Package.resolved`).

## Design notes

- **Multicore model**: one process, one event loop per core (`Loop.swift`). A loop is a thread with its own epoll
  instance; each turn it runs the work queued for it, then calls back the descriptors that are ready, then its
  timers, then waits. Everything a loop owns is touched only on its thread. Other threads reach it through
  `execute`, which takes a lock and wakes the loop (an eventfd write) only if it is asleep; work queued from the
  loop's own thread takes no lock. Each loop is also a `TaskExecutor`: a task pinned to it runs its jobs there, and
  a task the loop resumes is queued on it without a lock. On Linux each loop listens on the port with a socket of its
  own (`SO_REUSEPORT`, so the kernel spreads new connections over the loops), and a connection stays on its loop for
  life: its bytes are read, its requests parsed, routed, checked (token, query, path) and answered there. A hot read
  (lists, feed, article, comments, profile, current user, tags) is a task pinned to its connection's loop: it queues
  the read, awaits the result and writes the response without leaving the loop. Each loop gathers the reads of its
  current turn in an outbox and hands them to the batcher together, so the loops take the batcher's lock once per
  turn, not once per request. The read and write lanes are tasks pinned to loops too, each with its Postgres
  connections on that loop, so a Postgres reply resumes the lane on the thread that read it; a lane hands a batch's
  results to each connection loop as one job, which resumes that loop's tasks there. `READ_TASKS=0` hands a read's
  result to its connection as a callback instead of resuming a task. Writes, sign-up and login run as child tasks of
  the HTTP server's task group on Swift's cooperative pool. `DB_POOL_SIZE` is every Postgres connection the server
  opens (`start.sh`: `3 × cores`, capped at 95 for the box's `max_connections = 100`). The core count is the CPUs the
  process may run on, capped by its cgroup's CPU limit.
- **Ownership**: bytes have one owner at a time. `Bytes` (`Bytes.swift`) is a `~Copyable` buffer over raw memory,
  grown by `realloc` and not allocated until written: a Postgres request, a connection's received bytes, a batch's
  rows. It moves (`swap`, `consume`) where its owner changes, so it is never shared or copied by accident and a write
  is a capacity check and a store, with no copy-on-write check. The JSON writer is a `~Copyable` owner of its memory
  too; `finish()` is `consuming` and hands that memory to a `JSONBytes` with `discard self`, without a copy. Code reads
  bytes through `Span`s, `borrowing` the buffer: the HTTP head is parsed and the query read in place, rows are read
  cell by cell where Postgres put them, and text is escaped from there into the response.
- **HTTP** (`HTTP.swift`, `Server.swift`, `Routes.swift`): HTTP/1.1 with keep-alive, served directly on `HOST:PORT`
  (`0.0.0.0:80` on the box), so the server holds every user's connection itself; listen backlog 65535 (the box's
  `net.core.somaxconn`), `TCP_NODELAY`. A connection with nothing pending reads into its loop's receive buffer, and a
  request that arrived whole is parsed there in place; only leftovers (the start of a request, or requests pipelined
  behind the one in flight) are copied to the connection's own bytes, which hold no memory the rest of the time. The
  request line is parsed, then only the headers the server acts on (`Authorization`, `Content-Length`,
  `Transfer-Encoding: chunked`, `Connection`, `Expect: 100-continue`). Requests on a connection are answered one at a
  time, in order; heads over 64 KB are a 431 and bodies over 1 MB a 413, and a request that can't be framed
  (malformed, or both `Content-Length` and chunked) is answered and the connection closed. Routing matches the path's
  non-empty segments as bytes; path parameters are percent-decoded, and one that can't match a row (invalid UTF-8, or
  NUL, which Postgres text can't hold) is a 404 without a query; a list filter holding NUL is an empty page the same
  way. Unknown routes return the RealWorld JSON error shape. A response is one piece of memory: the JSON writer leaves
  128 bytes free in front of the body, the status line and headers are written into them, and the socket write takes
  the bytes from there. Each loop checks its connections every 75 s and closes those idle since the check before, so
  after 75 to 150 s idle; a request costs a counter increment, not a timer.
- **JSON out**: the writer appends with an inline capacity check and a store or `memcpy`, no intermediate Strings;
  text with nothing to escape is one `memcpy`, otherwise its exact escaped length is counted first and each byte is
  stored. A batch writes the JSON of every article, comment thread, profile, user and the tags list it shows once,
  with the viewer-dependent values (`favorited`, `following`) left open; each response copies its parts out and fills
  those values in for its viewer. Timestamps are integer microseconds formatted in an `InlineArray`, so the truncation
  to milliseconds is exact.
- **Read batching** (`Reads.swift`): reads from every endpoint wait in one queue, and a lane (`READ_LANES`, one per
  core, each answering one batch at a time) takes everything waiting once the oldest read has waited
  `READ_WINDOW_MS` (30), or the queue holds `READ_BATCH_MAX`, so a batch grows with the load (about 450 reads at 30k
  requests a second). It answers them with one statement per kind of read present, each over arrays of distinct keys
  (`unnest`). The statements run in two rounds: first what each read is about (every kind of page and feed,
  articles by slug, comment threads, profiles, users, the tags table), then the details of every article shown, the
  comments' authors and the viewer flags. A round's statements are spread over the lane's connections
  (`READ_CONNECTIONS`), and a large one (many threads, articles or flags) is split over several, each connection's
  share pipelined in one write and all of them sent before any answer is awaited, so the backends work at once;
  their rows are written straight into the batch's buffer (moved into a sink for the round and back out after it).
  Identical reads share a row, every article in the batch is enriched once however many reads show it, and each
  table is read once for the whole set (`= ANY` over the ids: articles, tag ids, one grouped favorites count, each
  author once), so recent articles shown together share index pages. A comment thread comes with its authors' ids,
  and the batch's distinct comment authors are read once. A feed's count stops at the 1,000th article over all of
  its viewer's followees, and its page is merged in Postgres from the followees' newest articles, so only the page
  comes back. The viewer-dependent flags are one lookup per (viewer, article or author) pair. The batch's integer
  lookups (ids, tag ids, viewer pairs) are an open-addressing table with a multiplicative hash (`Tables.swift`), not
  `Set`/`Dictionary` and their SipHash. Only reads already queued when a batch is taken share it, and nothing
  outlives the batch (rule 5). A login's user (with its stored hash) is read in a batch too. (The tags table is read
  in the first round; if an article in the details names a tag created since, it is read again.)
- **Postgres** (`Postgres.swift`): a connection is a non-blocking socket its loop watches; a request is several
  statements in one write, each a Bind and Execute of a statement prepared on that connection (Parse goes with its
  first use) and its own Sync, so each runs as if alone and one failing doesn't stop the rest; all of a request's
  statements answer in one round trip. Parameters and results are binary; rows are kept as the bytes Postgres sent and
  read in place by offset (`PGCursor`): no object per row or per cell. A statement whose Parse Postgres skipped (inside
  a transaction that had already failed) is parsed again the next time it is used. A connection that closes
  fails every request still waiting on it, and a lane replaces it before its next batch. Our connections set
  `jit = off`, `max_parallel_workers_per_gather = 0` and `plan_cache_mode = force_generic_plan` as startup parameters
  (session settings, nothing server-wide): the box's Postgres has JIT and parallel query on, and both cost more than
  they save on sub-millisecond statements, and the batches' array parameters would otherwise be re-planned on every
  execution.
- **Writes** (`Writes.swift`) are committed in groups: they wait in one queue, and each write lane (`WRITE_LANES`,
  4) takes every write waiting, runs them as one transaction on a connection of its own, and answers them all once
  `COMMIT` has returned. A group is one request (`BEGIN`, its statements, `COMMIT`), so one round trip, and a group
  pays for one commit instead of one per write. All of a group's favorites, unfavorites, follows, unfollows and new
  comments run as one statement per kind, over arrays of their parameters, however they were interleaved: writes of
  different users commute, a user's own requests on one connection come one after another, and a group is cut where
  the same user would toggle the same favorite or follow twice (new comment ids are drawn in arrival order). So a
  group is about six statements however many writes it holds. If any statement fails (a sign-up whose username is
  taken), the group is rolled back and each write runs again in a transaction of its own, so one bad write fails
  alone; a lost connection fails its group without a retry, since its `COMMIT`'s outcome is unknown. A favorite or a
  new article is answered with the article as the same transaction reads it after the group's writes (one statement
  for all of a group's favorites, one per new article), so it doesn't wait for a read batch after the commit; an
  updated article, whose slug may have changed, is read through the read batcher after the commit.
- **bcrypt** (`Bcrypt.swift`): OpenBSD's algorithm, written in Swift so that several hashes run in lockstep on one
  core. A single bcrypt is one long chain of dependent S-box loads, so a core running one mostly waits on its L1
  cache; hashes interleaved round by round give it independent chains to overlap (`rust-epoll-WorriedArrow` does the
  same). The lockstep core is generic over the number of lanes (`<let lanes: Int>`, so each width is its own
  specialized loop), keeps every lane's 4 KB Blowfish state in an `InlineArray` on the worker's stack, and only
  `borrowing`s it in the round loop. At startup it times widths 1 to 6 at cost 6 and keeps the fastest per hash;
  every hash still runs all 2^10 rounds. Hashes and verifications wait in one queue; workers (`BCRYPT_THREADS`, half
  the cores) are child tasks that prefer a `TaskExecutor` over threads of their own, so no hash runs on a loop. One
  worker takes what is waiting once a set is full or the oldest has waited `BCRYPT_WINDOW_MS`; the others only take
  full sets. Its output is byte for byte OpenBSD's and it verifies the seed's `$2a$` hashes; it writes `$2b$`. At most
  `BCRYPT_QUEUE` hashes run or wait at once; past that a login or sign-up is a 503 at once.
- **Swift 6**: language mode 6 (strict concurrency checking) plus the upcoming features
  `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, `ExistentialAny` and `MemberImportVisibility`. A
  `@main` app runs the HTTP server, the write and read lanes and the bcrypt workers as services (`Lifecycle.swift`):
  on SIGTERM or SIGINT (a handler writes to a pipe a thread reads) they are told to stop in reverse order, each once
  the ones after it have finished, so in-flight requests finish first. The `@unchecked Sendable` types are those
  that keep their own synchronization or confinement: a loop (a lock for other threads' work), a value bound to a
  loop and used only there, a JSON body or a request's rows once handed over (immutable from then on), the bcrypt
  thread pool (a mutex), and the JWT signer. Release builds use `-Ounchecked`, which doesn't evaluate preconditions,
  so nothing with a side effect goes inside one. `build.sh` adds `-enforce-exclusivity=unchecked` for every module
  and, on Linux, `--static-swift-stdlib`. `start.sh` preloads jemalloc (installed by `install.sh`) in place of glibc
  malloc.
- **Scheduling** (Linux): the process switches to `SCHED_BATCH` at startup (no privileges needed; threads inherit it),
  so its constant small wakeups don't preempt busy Postgres backends. `SCHED_BATCH=0` turns it off.
- **Auth**: `Authorization: Token <jwt>`; the signature is checked (constant-time, with an HMAC keyed once at startup)
  on every request. Tokens shaped like the ones this server issues are parsed in place; anything else goes through
  `JSONSerialization`. Present-but-invalid is 401 even on auth-optional endpoints; absent means anonymous
  (`viewer = 0`).
- **Bodies** are parsed with `JSONSerialization` into dictionaries, so key matching is case-sensitive, unknown
  fields are ignored, and `null` vs absent is distinguished exactly as in the spec. A string holding NUL is a 422:
  Postgres text can't hold it, and as a parameter it would fail the whole group or batch it went in.

## Measured

Server CPU per request on a mixed load (reads with 5% writes), each server in Docker with 1 ms added to every Postgres
reply, all on one arm64 Mac (so absolute numbers are not the box's):

| Build | Server CPU per request |
|---|--:|
| `swift-nio-akbashev` (#147: SwiftNIO, postgres-nio) | about 46-52 µs |
| with this Postgres client | 25-26 µs |
| and these event loops | 22 µs |
| and the batch tables, the owned JSON writer, rows copied once | 19-20 µs |

Postgres CPU per request is 10-25% below #147's on the same load.

Postgres work per request with the benchmark's own load generator (`bench/loadgen`, 12,000 users at a tenth of
the think time, about 28,000 requests a second) on the full seed (`seed/make-seed.sh`), as buffer pages touched
(pg_stat_statements; unlike CPU time on a shared machine, it doesn't move with the load around it): 66 at the
start (batches every 5 ms), 41 now, against 39-42 for `rust-epoll-theCatWisel` (#154) on the same setup. The feed
count, the set-based article details, the shared comment authors and 30 ms batches each took a part.

## Build and run

```bash
bash build.sh    # swift build -c release (+ flags above) -> ./.build/release/Conduit
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_dev JWT_SECRET=conduit-dev-secret \
  DB_POOL_SIZE=10 PORT=3104 bash start.sh
```

Environment: `DATABASE_URL`, `JWT_SECRET` (required); `HOST` (127.0.0.1), `PORT` (3000),
`DB_POOL_SIZE` (`start.sh`: min(3 × cores, 95)), `BCRYPT_THREADS` (half the cores), `BCRYPT_QUEUE` (40 ×
`BCRYPT_THREADS`), `BCRYPT_LANES` (measured at startup), `BCRYPT_WINDOW_MS` (200), `WRITE_LANES` (4),
`WRITE_GROUP_MAX` (256), `READ_LANES` (cores), `READ_CONNECTIONS` (per read lane: what `DB_POOL_SIZE` leaves after
the write lanes, split between the read lanes, at least 1), `READ_WINDOW_MS` (30), `READ_BATCH_MAX` (1024), `READ_TASKS` (`0`: a read's result goes to its connection as a callback; on), `SCHED_BATCH`
(`0` to keep the default scheduling policy; on). `PG_SELFTEST=1` runs the Postgres client's self-test against
`DATABASE_URL` and exits.
