# Swift: raw epoll, a Postgres client of its own, one actor per thread

**Front: direct.**

A Swift 6 server written the way Swift and its runtime are meant to be used today, so the numbers measure Swift
itself: every thread is an actor, isolated by the compiler, and the whole server is one structured task group. It
has no dependencies: its own HTTP/1.1 server, Postgres wire client, SHA-256/HMAC, JWT and bcrypt.

| Piece | Version |
|---|---|
| Swift | 6.4.2 (official Ubuntu 24.04 x86_64 tarball, sha256-checked), Swift 6 language mode, nonisolated by default |
| Dependencies | none: the standard library, Synchronization, Glibc |
| HTTP | hand-rolled HTTP/1.1 on epoll, one `SO_REUSEPORT` listener per reactor |
| Postgres | hand-rolled protocol 3.0 client: SCRAM-SHA-256, extended protocol, binary rows, pipelines |
| JWT | HS256 with the secret's HMAC midstates precomputed (portable SHA-256) |
| bcrypt | cost 10, several hashes in lockstep per thread, width calibrated at start-up; generated Swift kernels |
| Allocator | jemalloc (`libjemalloc2`, installed by `install.sh`, preloaded by `start.sh`); glibc malloc without it |
| Build | release, `-Ounchecked` and `-enforce-exclusivity=unchecked` (see Correctness), for the box's own CPU |

## Design

**One actor per thread.** `cores / 2` reactors, `cores` read lanes, `cores / 2` (2 to 4) write lanes and `cores / 2`
(at least 3) bcrypt workers, plus one `Scheduler` actor for the queues (this thread layout is rust-epoll-theCatWisel's).
Reactors run at nice 5 and bcrypt workers after the first at nice 10, so under full CPU Postgres and the lanes go
first. Each
actor's executor is an `EventLoop` (`EventLoop.swift`): a thread of its own, an epoll instance and an eventfd,
conforming to both `SerialExecutor` and `TaskExecutor`. The runtime hands it the actor's jobs through `enqueue` (a
`Mutex`-guarded list, the one place two threads meet; the eventfd is written only when the loop is about to sleep, as
NIO's event loop does) and the thread runs them in order. `main` starts every actor as a child task of one
`withDiscardingTaskGroup`, each with `executorPreference:` its own loop, so it starts there rather than on the global
pool.

Inside an actor, state is plain: a reactor's connection table, a lane's Postgres connection and arenas, the
scheduler's queues and batching policy. Nothing is `@unchecked Sendable`; what crosses between actors is a value
(`ReadTask`, `WriteTask`, `CryptoTask`, replies whose bodies are `[UInt8]`), and messages are per epoll tick or per
batch, never per request:

- **Reactor** (`Reactor.swift`): blocks in `epoll_wait` on its own loop with its sockets and the loop's eventfd in
  the set, one call per tick. It parses, verifies the token and routes (`Router.swift`), answers what needs no
  Postgres, and sends the tick's work to the scheduler in one awaited message. A lane's replies arrive as one
  `deliver` message per batch; when one is queued the reactor yields (`Task.yield()` re-enqueues on the actor's own
  executor) and the message runs on the same thread. A pass lasts at least 2 ms: with fewer events than its buffer
  holds, the reactor waits out the rest on its loop, so work and replies travel in fewer, larger messages.
  `unshare(CLONE_FILES)` gives each reactor thread its own descriptor table.
- **Scheduler** (`Scheduler.swift`): reads wait in three queues: fast (tags, users, logins, profiles, articles and
  lists), comments, and feeds. An idle read lane picks a queue and gathers its next batch, one lane per queue at a
  time, at most `max(lanes - 1, 3)` gathering or running at once, each queue with a share of them (3/8, 1/4 and 1/4
  of the lanes, one more for the queue holding the oldest request). With nothing else going on it gathers briefly;
  otherwise a queue is drained at most every 74 ms (feeds 76), a batch gathers for at least 5 ms, and no request waits
  longer than the two together. Write lanes gather one at a time, up to 64 writes for 3-5 ms (150 µs when writes come
  one by one); bcrypt workers too, for a full set of lanes, up to 1.5-2 bcrypt runs (35-45 ms at most). Deadlines are
  timeouts on the scheduler's own loop. Clients that hung up while queued are dropped here, on a cancellation message
  from the reactor.
- **Read lane** (`ReadLane.swift`): phase A resolves what each request is about over the batch's distinct keys, in
  two parts sent in one flush: A1 (tags, the current user, profiles with whether their reader follows them, logins)
  has its own Sync, so those replies go out, and logins reach the bcrypt workers, while Postgres still runs A2's
  lookups, lists and comment threads. A thread comes back in one statement with its authors and its readers' follows
  among them, and is answered before phase B. Lookups and lists bring the articles' metadata with them; phase B
  enriches the union of the articles found, once each and in id order (tags, counts, authors, and metadata for the
  feed's index-only finds), and the viewers' flags, which rendering finds through bit filters before a sorted search.
  Each article's JSON is written once per batch with its viewer-dependent booleans left open, and identical responses
  are built once and shared. A request's slug, username, email or tag is held inline (`SmallBytes`), so routing a
  read allocates nothing for it. Postgres I/O blocks the lane's own thread; the sockets have `TCP_NODELAY` and
  `TCP_QUICKACK`. The two-round-trip plan and its SQL are rust-epoll-theCatWisel's.
- **Write lane** (`WriteLane.swift`): group commit in one implicit pipeline transaction, favorites, follows and new
  comments merged into `unnest` statements (in article order) unless the group also changes what they read,
  one-by-one retry if the group fails. A new article and its tags are one statement, answered from its insert; a
  favorite's read-back carries the flag it set and goes to the front of the fast queue. A write group that fails during its retry answers 500 to the writes it didn't get to, and queued writes run
  even if their client hung up.
- **bcrypt workers** (`CryptoWorker.swift`, `Auth.swift`): lockstep sets of up to `lanes` hashes (the lockstep idea
  is rust-epoll-theCatWisel's); verified logins answer the reactors directly, hashed passwords go back to the
  scheduler as writes, ahead of the queue. The cost loop's key-only expansions, nearly all of bcrypt's time, run
  kernels written out per lane count (`BcryptKernels.swift`, generated by `scripts/generate-bcrypt-kernels.swift`):
  every lane's halves in scalar locals and all 16 rounds of every lane spelled out, interleaved half-round by
  half-round, so the compiler only has registers left to choose. Swift has no inline assembly and the server links no
  C or assembly, so the instruction choice is LLVM's for the CPU it was built on. Two families: constant shifts (the
  compiler's choice of instructions, BMI1's `bextr` on AMD), and `shrx`, whose shifts by 24 and 16 take their count
  from a register (an atomic's value, which the optimizer can't fold), BMI2's three-operand `shrx`, so no copy before
  each shift, for Intel. The shrx family is compiled on x86-64 only (arm64's `ubfx` extracts a constant field in one
  instruction, so there it would only add one). In the compiler's x86-64 output a half-round takes 11.4-13.3
  instructions, and the kernels spill a little from 4-5 lanes. Calibration times the families at every width and
  keeps the fastest. `build.sh` compiles for the box's CPU.

## Swift 6.4 features, and where

- `~Copyable`: `ByteBuffer` (one owner, never copied, so appending never copies its array), `UniqueArray` (the
  reactor's connection slots, each owning its buffers), `PgConn` (owns its socket, closes it in `deinit`),
  `PipelineBuf`, `TxBuf`, and the `Router.Dispatch`/`HTTP.ParseOutcome` results, each used once.
- `Span`, `RawSpan`, `MutableSpan`, `OutputSpan`: every byte reader takes a `Span`; integers are loaded from a
  `RawSpan` (`load(fromByteOffset:as:_:)`, big-endian for Postgres frames and cells and SHA-256 blocks, native for
  epoll events), as are the JSON writer's 16-byte SIMD and 8-byte word checks; socket reads fill a buffer through an
  `OutputSpan`; base64 decodes, and response heads are written, into a `MutableSpan` of a stack `InlineArray`.
- `~Escapable` with `@_lifetime`: `HTTP.Request` borrows the reactor's read buffer, the JSON reader borrows the body
  (a validating pass that builds nothing and keeps only the members the caller names, as places in the body in an
  `InlineArray`; strings are read in place, copied only into the value that goes to a lane), and the pipeline buffer
  lends its cells as `Span`s. Errors are `StaticString`s whose bodies the reactor writes, so no error answer
  allocates.
- `InlineArray` and value generics: the SHA-256 state and schedule, bcrypt's Blowfish states
  (`Bcrypt.hashLanes<let n>`), bcrypt's base64 decode (`<let count: Int>`), HTTP header and number buffers.
- `UTF8Span(validating:)` for UTF-8 checks, typed throws (`throws(PgError)`), `Mutex` and `Atomic` from
  Synchronization.
- `@_extern(c)`: the Linux calls Glibc's module leaves out (epoll, eventfd, accept4, unshare, getrandom,
  sched_setscheduler, prctl, mallopt), declared in Swift in a module of their own (`Sources/Syscalls`). Each is the C
  function itself, so a call to one is a direct call.
- Byte search is glibc's `memchr`, JSON escaping uses portable `SIMD16`, and SHA-256 is a portable compression
  function: Swift has no counterpart to C's x86 intrinsics.

## Settings

`IO_THREADS` (cores / 2), `READ_LANES` (cores), `WRITE_LANES` (cores / 2, 2 to 4), `BCRYPT_THREADS` (cores / 2, at
least 3), `BCRYPT_LANES` (calibrated), `BCRYPT_KERNEL` (`constant`, or `shrx` on x86-64; calibrated), `PASS_US`
(a reactor pass's least length, 2000), `LOOP_NICE` (5) and `BCRYPT_NICE` (10). Cores are the process's affinity
mask. Postgres connections: `READ_LANES + WRITE_LANES`.

## Correctness

`test/run.sh`: 197/197 on the dev seed and on the full seed.

The release build is `-Ounchecked`, so the shipped binary has no bounds, overflow or exclusivity checks: the
`Span`/`RawSpan` bounds checks hold in debug builds and tests, and in release the parsers rely on the length checks
they make themselves. Built with plain `-O` instead (checks on), it also passes 197/197 and survived the load test
without a trap, at about 2-3% less throughput locally, within run-to-run noise.

## Credits

The thread layout, the read plan and its SQL, group commit and lockstep bcrypt are @theCatWisel's ideas
([`rust-epoll-theCatWisel`](../rust-epoll-theCatWisel), #154, which credits the entries it learned from).
