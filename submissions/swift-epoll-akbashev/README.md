# Swift: raw epoll, a Postgres client of its own, one actor per thread

**Front: direct.**

A port of [`rust-epoll-theCatWisel`](../rust-epoll-theCatWisel) (#154, by @theCatWisel) to Swift 6: the same
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
| bcrypt | cost 10, several hashes in lockstep per thread, width calibrated at start-up; generated Swift kernels |
| Allocator | jemalloc (`libjemalloc2`, installed by `install.sh`, preloaded by `start.sh`); glibc malloc without it |
| Build | release, `-Ounchecked` and `-enforce-exclusivity=unchecked` (see Correctness), for the box's own CPU |

## Design

**One actor per thread, the Rust's thread layout.** `cores / 2` reactors, `cores` read lanes, one write lane and
`cores / 2` (at least 3) bcrypt workers, as `main.rs` starts them, plus one `Scheduler` actor for the queues. Each actor's executor is
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
  distinct keys, in two parts sent in one flush: A1 (tags, the current user, logins) has its own Sync, so those
  replies go out, and logins reach the bcrypt workers, while Postgres still runs A2's lookups and lists. Lookups and
  lists bring the articles' metadata with them; phase B enriches the union of the articles found, once each (tags,
  counts, authors, and metadata for the feed's index-only finds), and the viewers' flags, and anonymous profiles are
  answered while it runs. Each article's JSON is written once per batch with its viewer-dependent booleans left open,
  and identical responses are built once and shared. Postgres I/O blocks the lane's own thread, as in the Rust.
- **Write lane** (`WriteLane.swift`, `WriteWorker`): group commit in one implicit pipeline transaction, favorites,
  follows and new comments merged into `unnest` statements unless the group also changes what they read, one-by-one
  retry if the group fails. A new article is answered from its insert in one round trip; a favorite's read-back
  carries the flag it set.
- **bcrypt workers** (`CryptoWorker.swift`, `Auth.swift`): lockstep sets of up to `lanes` hashes; verified logins
  answer the reactors directly, hashed passwords go back to the scheduler as writes, ahead of the queue. The cost
  loop's key-only expansions, nearly all of bcrypt's time, run kernels written out per lane count
  (`BcryptKernels.swift`, generated by `scripts/generate-bcrypt-kernels.swift`, the Swift counterpart of the Rust's
  `build.rs`): every lane's halves in scalar locals and all 16 rounds of every lane spelled out, interleaved
  half-round by half-round, so the compiler only has registers left to choose. Two families, as the Rust has
  several: constant shifts (the compiler's choice of instructions, BMI1's `bextr` on AMD), and `shrx`, whose shifts
  by 24 and 16 take their count from a register (an atomic's value, which the optimizer can't fold), BMI2's
  three-operand `shrx`, so no copy before each shift: the Rust's kernel for Intel. The shrx family is compiled on
  x86-64 only (arm64's `ubfx` extracts a constant field in one instruction, so there it would only add one).
  Calibration times the families at every width and keeps the fastest. `build.sh` compiles for the box's CPU, as the Rust's `target-cpu=native`.

## Swift 6.4 features, and where

- `~Copyable`: `ByteBuffer` (the Rust's `Vec<u8>`: one owner, never copied, so appending never copies its array),
  `UniqueArray` (the reactor's connection slots, each owning its buffers), `PgConn` (owns its socket, closes it in
  `deinit`), `PipelineBuf`, `TxBuf`, and the `Dispatch`/`ParseOutcome` results that carry an owned body.
- `Span`, `RawSpan`, `MutableSpan`, `OutputSpan`: every byte reader takes a `Span`; integers are loaded from a
  `RawSpan` (`load(fromByteOffset:as:_:)`, big-endian for Postgres frames and cells and SHA-256 blocks, native for
  epoll events), as are the JSON writer's 16-byte SIMD and 8-byte word checks; socket reads fill a buffer through an
  `OutputSpan`; base64 decodes into a `MutableSpan` of a stack `InlineArray`.
- `~Escapable` with `@_lifetime`: `HttpReq` borrows the reactor's read buffer (the Rust's `HttpReq<'a>`), the JSON
  parser borrows the body, and the pipeline buffer lends its cells as `Span`s.
- `InlineArray` and value generics: the SHA-256 state and schedule, bcrypt's Blowfish states (`bcryptLanes<let n>`,
  the Rust's `bcrypt_lanes<const N>`), bcrypt's base64 decode (`<let count: Int>`), HTTP header and number buffers.
- `UTF8Span(validating:)` for UTF-8 checks, typed throws (`throws(PgError)`), `Mutex` and `Atomic` from
  Synchronization.
- `@_extern(c)`: the Linux calls Glibc's module leaves out (epoll, eventfd, accept4, unshare, getrandom,
  sched_setscheduler, prctl, mallopt), declared in Swift (`Sys.swift`), as the Rust declares them in its `mod sys`.

## Where it differs from the Rust

- One more thread (the scheduler) and one more hop on a read's way to a lane: the Rust's lanes take their batch from
  a shared queue themselves.
- The Rust's x86 intrinsics (SSE2 byte search and JSON escaping, SHA-NI) have no Swift counterpart: byte search is
  glibc's `memchr`, escaping uses portable `SIMD16`, SHA-256 is the Rust's portable compression function.
- The Rust's bcrypt kernels are x86-64 assembly (generated by its `build.rs`: `ah`, `bextr` and `shrx` variants,
  picked at start-up); Swift has no inline assembly and this port links no C or assembly, so its kernels are
  generated Swift with the same shape, and the instruction choice is LLVM's for the CPU it was built on. Read in the
  compiler's x86-64 output, they come within about 10-20% of the assembly's instructions per round, on AMD's and,
  with the `shrx` family, on Intel's cost models (11.4-13.3 a half-round against its 11-12), and spill a little from
  4-5 lanes.
- A write group that fails during its one-by-one retry answers 500 to the writes it didn't get to (the Rust leaves
  them unanswered), and queued writes run even if their client hung up.

## Settings

As the Rust reads them: `IO_THREADS` (cores / 2), `READ_LANES` (cores), `WRITE_LANES` (1), `BCRYPT_THREADS`
(cores / 2, at least 3), `BCRYPT_LANES` (calibrated), and `BCRYPT_KERNEL` (`constant`, or `shrx` on x86-64; calibrated). Cores are the process's affinity mask, as Rust's `available_parallelism`.
Postgres connections: `READ_LANES + WRITE_LANES`.

## Correctness

`test/run.sh`: 197/197 on the dev seed and on the full seed.

The release build is `-Ounchecked`, so the shipped binary has no bounds, overflow or exclusivity checks: the
`Span`/`RawSpan` bounds checks hold in debug builds and tests, and in release the parsers rely on the length checks
they make themselves. Built with plain `-O` instead (checks on), it also passes 197/197 and survived the load test
without a trap, at about 2-3% less throughput locally, within run-to-run noise.

## Credits

Everything about what the server does, and the SQL, is @theCatWisel's (`rust-epoll-theCatWisel`, which credits the
entries it learned from).
