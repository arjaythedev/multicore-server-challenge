# Swift: raw epoll, a Postgres client of its own, one actor per thread

**Front: direct.**

A port of [`rust-epoll-theCatWisel`](../rust-epoll-theCatWisel) (#143, by @theCatWisel) to Swift 6: the same
threads, the same batching of reads into two pipelined Postgres round trips, the same group commit, the same SQL
(generated from its `queries.rs`) and the same lockstep bcrypt. What changes is how the threads talk: every thread is
an actor, isolated by the compiler, and the whole server is one structured task group.

| Piece | Version |
|---|---|
| Swift | 6.4.1 (official Ubuntu 24.04 x86_64 tarball, sha256-checked), Swift 6 language mode, nonisolated by default |
| Dependencies | none: the standard library, Synchronization, Glibc (as the Rust uses only `std`) |
| HTTP | hand-rolled HTTP/1.1 on epoll, one `SO_REUSEPORT` listener per reactor |
| Postgres | hand-rolled protocol 3.0 client: SCRAM-SHA-256, extended protocol, binary rows, pipelines |
| JWT | HS256 with the secret's HMAC midstates precomputed (portable SHA-256) |
| bcrypt | cost 10, several hashes in lockstep per thread, width calibrated at start-up |
| Allocator | jemalloc (`libjemalloc2`, installed by `install.sh`, preloaded by `start.sh`); glibc malloc without it |

## Design

**One actor per thread, the Rust's thread layout.** `cores / 2` reactors, `cores` read lanes, one write lane and
`cores` bcrypt workers, as `main.rs` starts them, plus one `Scheduler` actor for the queues. Each actor's executor is
an `EventLoop` (`EventLoop.swift`): a thread of its own, an epoll instance and an eventfd, conforming to both
`SerialExecutor` and `TaskExecutor`. The runtime hands it the actor's jobs through `enqueue` (a `Mutex`-guarded list,
the one place two threads meet; the eventfd is written only when the loop is about to sleep, as NIO's event loop does)
and the thread runs them in order. `main` starts every actor as a child task of one `withDiscardingTaskGroup`,
each with `executorPreference:` its own loop, so it starts there rather than on the global pool.

Inside an actor, state is plain: a reactor's connection table, a lane's Postgres connection and arenas, the
scheduler's queues and batching policy. Nothing is `@unchecked Sendable`; what crosses between actors is a value
(`ReadTask`, `WriteTask`, `CryptoTask`, replies whose bodies are `[UInt8]`), and messages are per epoll tick or per
batch, never per request:

- **Reactor** (`Reactor.swift`, the Rust's `reactor.rs`): blocks in `epoll_wait` on its own loop with its sockets and
  the loop's eventfd in the set (one call per tick, as the Rust). It parses, verifies the token and routes
  (`Router.swift`, `router.rs`), answers what needs no Postgres, and sends the tick's work to the scheduler in one
  message. A lane's replies arrive as one `deliver` message per batch; when one is queued the reactor yields
  (`Task.yield()` re-enqueues on the actor's own executor) and the message runs on the same thread.
  `unshare(CLONE_FILES)` gives each reactor thread its own descriptor table, as in the Rust.
- **Scheduler** (`Scheduler.swift`, the Rust's `WorkQueue`, `take_aged`, the batch lock and the `EWMA_*`/`BUSY_*`
  atomics): one lane gathers at a time, taking its batch once it has `want` requests or the oldest has waited
  `max_age`, both computed from the running averages exactly as `engine.rs` does; the deadline is a timeout on the
  scheduler's own loop. Clients that hung up while queued are dropped here (the Rust's per-slot epochs become a
  cancellation message from the reactor).
- **Read lane** (`ReadLane.swift`, `ReadWorker`): phase A resolves what each request is about over the batch's
  distinct keys, phase B enriches the union of the articles found, once each, and the viewers' flags; each article's
  JSON is written once per batch with its viewer-dependent booleans left open, and identical responses are built once
  and shared. Postgres I/O blocks the lane's own thread, as in the Rust.
- **Write lane** (`WriteLane.swift`, `WriteWorker`): group commit in one implicit pipeline transaction, favorites,
  follows and new comments merged into `unnest` statements, one-by-one retry if the group fails.
- **bcrypt workers** (`CryptoWorker.swift`, `Auth.swift`): lockstep sets of up to `lanes` hashes; verified logins
  answer the reactors directly, hashed passwords go back to the scheduler as writes, ahead of the queue.

## Swift 6.4 features, and where

- `~Copyable`: `ByteBuffer` (the Rust's `Vec<u8>`: one owner, never copied, so appending never copies its array),
  `UniqueArray` (the reactor's connection slots, each owning its buffers), `PgConn` (owns its socket, closes it in
  `deinit`), `PipelineBuf`, `TxBuf`, and the `Dispatch`/`ParseOutcome` results that carry an owned body.
- `Span`, `MutableSpan`, `OutputSpan`: every byte reader takes a `Span`; socket reads fill a buffer through an
  `OutputSpan`; base64 decodes into a `MutableSpan` of a stack `InlineArray`.
- `~Escapable` with `@_lifetime`: `HttpReq` borrows the reactor's read buffer (the Rust's `HttpReq<'a>`), the JSON
  parser borrows the body, and the pipeline buffer lends its cells as `Span`s.
- `InlineArray` and value generics: the SHA-256 state and schedule, bcrypt's Blowfish states (`bcryptLanes<let n>`,
  the Rust's `bcrypt_lanes<const N>`), bcrypt's base64 decode (`<let count: Int>`), HTTP header and number buffers.
- `UTF8Span(validating:)` for UTF-8 checks, typed throws (`throws(PgError)`), `sending`/region isolation,
  `Mutex` and `Atomic` from Synchronization.
- `@_extern(c)`: the Linux calls Glibc's module leaves out (epoll, eventfd, accept4, unshare, getrandom,
  sched_setscheduler, prctl, mallopt), declared in Swift (`Sys.swift`), as the Rust declares them in its `mod sys`.

## Where it differs from the Rust

- One more thread (the scheduler) and one more hop on a read's way to a lane: the Rust's lanes take their batch from
  a shared queue themselves.
- The Rust's x86 intrinsics (SSE2 byte search and JSON escaping, SHA-NI) have no Swift counterpart: byte search is
  glibc's `memchr`, escaping uses portable `SIMD16`, SHA-256 is the Rust's portable compression function.
- A write group that fails during its one-by-one retry answers 500 to the writes it didn't get to (the Rust leaves
  them unanswered), and queued writes run even if their client hung up.

## Settings

As the Rust reads them: `IO_THREADS` (cores / 2), `READ_LANES` (cores), `WRITE_LANES` (1), `BCRYPT_THREADS`
(cores), `BCRYPT_LANES` (calibrated). Cores are the process's affinity mask, as Rust's `available_parallelism`.
Postgres connections: `READ_LANES + WRITE_LANES`.

## Correctness

`test/run.sh`: 197/197 on the dev seed and on the full seed.

## Credits

Everything about what the server does, and the SQL, is @theCatWisel's (`rust-epoll-theCatWisel`, which credits the
entries it learned from).
