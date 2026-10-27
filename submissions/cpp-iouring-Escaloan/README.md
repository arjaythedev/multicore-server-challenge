# C++20 io_uring Conduit server

Front: direct

| | |
|---|---|
| Language | C++20, g++ 13.3 (Ubuntu 24.04 archive) |
| Libraries | liburing 2.5, OpenSSL 3.0.13 (SHA-256, HMAC, PBKDF2), libxcrypt 4.4.36 (bcrypt reference for the startup self-test only); all from the Ubuntu 24.04 archive, installed by `install.sh` |
| Framework | none: own event loop, HTTP/1.1 parser and JSON reader/writer |
| Postgres driver | own wire-protocol client (extended protocol, binary parameters and results, SCRAM-SHA-256) |
| Postgres connections | 5 per event loop (4 read, 1 write): 10 on the 8-vCPU box |
| Configuration | environment only (`DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT`); tunables are constants in `src/config.hpp` |

## How it works

```
                 SO_REUSEPORT                    one thread per 4 CPUs (2 on the box)
  clients ──► accept (multishot) ─► event loop ─────────────────────────────────────────────┐
                                     │ multishot poll + recv → HTTP parse → route → validate │
                                     │ JWT verify (HMAC key schedule precomputed)            │
                                     │ per-statement FIFO queues ──► dispatch once per tick  │
                                     │   reads: batched statements on 4 read connections     │
                                     │   writes: group commit on 1 write connection          │
                                     │ binary rows ──► JSON written straight into the reply  │
                                     │ reply (headers + body) ──► one io_uring send          │
                                     └───────────────────────────────────────────────────────┘
  bcrypt worker thread: 4 hashes interleaved ◄─► loops (job queue in, eventfd + inbox out)
  reconnect thread: blocking Postgres (re)connects, hands ready sockets back to the loops
```

- **Shared-nothing event loops.** Each loop owns an io_uring (`SINGLE_ISSUER | DEFER_TASKRUN | COOP_TASKRUN`),
  an `SO_REUSEPORT` listener, its client connections, its Postgres connections, its queues and its memory. A
  request never changes thread and no lock is taken on the request path.
- **Receive path.** Multishot poll per connection, then `recv()` into a per-loop 64 KiB scratch buffer. An idle
  connection owns no buffer: its whole state is a 56-byte struct. Partial and pipelined requests wait in a small
  per-connection carry buffer. One request is in flight per connection, so responses stay in order.
- **Send path.** The JSON body is written after 128 reserved bytes; the HTTP header block is written backwards
  into that reserve once the body length is known, so header and body go out in one `send`.
- **Scheduling.** One FIFO per statement. Once per loop tick, after all completions are drained, each free read
  connection takes the statement kind whose oldest request is oldest, and sends up to that kind's cap of waiting
  requests as one statement. There are no timers: at low load a "batch" is one request; under load, batches grow
  by themselves because requests pile up while connections are busy.
- **Group commit.** Writes that queue while the write connection is busy are sent together as one sync group:
  one transaction, one WAL flush. Each response is released only after that transaction's ReadyForQuery. If the
  shared transaction fails, every request in it is retried alone. Register, settings and article creation always
  run alone (unique violations are expected there).
- **Resilience.** Lost Postgres connections are re-established by a separate thread. Reads that were in flight
  are re-queued (also when Postgres aborts them during a shutdown); writes whose commit status is unknown get 500.

## Memory design

Request-path memory comes from per-loop pools. The one exception is the tag list of a new article (a rare request), which uses `malloc`.

- **Arena allocator.** Each event loop owns an arena with seven size classes, 1 KiB to 4 MiB in x4 steps (no
  locking). Each class keeps its free buffers on a LIFO queue: the most recently released buffer, still in cache, is
  handed out next. Memory is carved from 2 MiB
  chunks advised for transparent huge pages. Each class has a cap: at the cap an allocation fails cleanly (that request
  gets 503/500) instead of memory growing without bound. Separately, a loop stops reading new requests while it
  holds more than 65,536 live ones and resumes below half of that.
- **Request buffer.** A complete request (headers + body) is copied once into a buffer of the smallest class that
  fits. Parsing never allocates: path segments, query values and JSON strings are decoded in place inside that
  buffer and referenced as views.
- **Response buffer.** Taken when the first result row arrives, sized per endpoint (for example from the page size
  for lists). If a response outgrows it, it moves up one class with a single copy (0.45% of responses in a load
  run). The first 128 bytes are reserved so the HTTP headers can be written in front of the body afterwards and
  both leave in one `send`.
- **Rows become JSON directly.** Binary rows are parsed in place in the Postgres receive buffer and serialised
  straight into the response buffer; no intermediate objects. JSON escaping assumes text needs no escaping (SSE2
  scan) and only re-checks space when it actually writes an escape.
- **Idle connections own no buffer.** A connection's state is a 56-byte struct; a small carry buffer is attached
  only while a request is split across reads or pipelined.
- **Postgres buffers.** Each Postgres connection has a linear send buffer (Binds appended, the kernel consumes from
  the front) and a receive buffer compacted after each batch of complete messages.
- **Requests and sync groups** are pooled objects reused LIFO after warm-up.

Measured under load (3,000 users, full seed, counted with an `LD_PRELOAD` allocation counter): **0.0043 heap allocations per
request** (one per ~230 requests, nearly all of them the tag list of a newly created article). The same server with
its buffers switched to `malloc`/`free` (`kHeapBuffers`) makes **1.85 per request**, about 430 times as many.
Why it matters: in interleaved A/B runs the arena saved 1.3–2.7 µs of server CPU per request, roughly 0.7–1.5 µs per
avoided allocation once cache effects are included (derived from those runs, not timed per call). The server shares
the box's cores with Postgres, which sets the score, so every microsecond the server does not spend is CPU Postgres
can use.

## Standard techniques vs what is distinctive here

Based on reading the other entries' source in this repository. "Others" lists who uses the same idea.

### Standard among the top entries

| Technique | Others | Notes |
|---|---|---|
| Serve direct (no Nginx) | most top entries | saves the ~11% of the box Nginx used |
| 4-way interleaved bcrypt | C++ asio, C io_uring, Rust tokio, C# sockets | ours: 2.8–3.3x less CPU per hash than libxcrypt |
| Group commit with retry alone on failure | Rust tokio, C++ asio, C# sockets | |
| Read/write connections split, few connections | all top entries | 10 connections total on the box |
| `plan_cache_mode = force_generic_plan`, `jit = off`, no parallel workers | C++, C, C#, Rust | session-level `SET` via the startup options |
| SQL shapes: page ids first, tag names by primary key, capped counts in the same statement, global count from the oldest end of the primary key | Rust tokio (source of our SQL, see Credits), C io_uring, C++ asio | |
| Batched reads: array parameters + `LATERAL`, request ordinal per row | Rust tokio, C# sockets | +52% throughput here vs one statement per request |
| Queued `GET /api/tags` share one execution | Rust tokio | |
| Shared list enrichment within one execution | Rust tokio | each distinct article enriched once per batch |
| Feed `following` is the constant `true` | C# sockets | same snapshot, so identical to the reference |
| Compile in O3 or other Optims | | |

### Used by only a few entries

| Technique | Others | What differs here |
|---|---|---|
| io_uring | C io_uring only (others use epoll via Tokio, asio, .NET, Go) | `DEFER_TASKRUN` rings; Postgres sockets on the same ring as clients |
| Own Postgres wire-protocol client | C io_uring, C# sockets | binary results decoded straight into the response JSON; batched Binds built in place |
| Preallocated request memory | C io_uring (per-request scratch arena), Go epoll (fixed buffer arrays) | size-classed arena allocator, below |

### Distinctive (not found in the other entries)

| Technique | Measured effect |
|---|---|
| **Size-classed arena allocator** (see Memory design): per-loop, LIFO reuse, huge-page chunks, capped classes, one-copy growth. 0.0043 heap allocations per request vs 1.85 without it. | A/B against `malloc`/`free` with identical size classes (`kHeapBuffers`), 3 interleaved rounds: app CPU 43.4–43.8 vs 44.9–46.4 µs per request (3–6% less), p95 lower in every round (38–53 ms vs 49–75 ms), throughput +0.3% to +1.9%. About 1% of total CPU per request, because Postgres dominates. |
| **bcrypt tables generated, not embedded.** The 1,042 Blowfish words in `src/bf_tables.hpp` were computed as hexadecimal digits of π (Machin's formula in exact integers) and checked against known values, rather than copied from another implementation. | Correctness only. |

## How changes are tested (A/B process)

Every change must first stay correct, then win a measured comparison; otherwise it is reverted.

1. **Correctness gates (before any timing):**
   - `test/run.sh`: conformance 197/197, on the dev seed and on the full seed. The normalized transcript is
     byte-identical to `bench/cmd/conformance/golden-dev.jsonl`.
   - A differential test: the same randomized reads go to this server and to the reference Go server
     (`examples/go`, SPEC.md's SQL) on the same database copy; status and parsed JSON must match exactly. It runs
     sequentially and at concurrency 32–128 so real batches form; `MODE=lists` uses the load generator's page
     pattern so the shared-enrichment paths run too. Only reads, so concurrent responses cannot legitimately differ.
   - Unit tests (HTTP split at every byte, JSON, timestamps, JWT, base64) and a bcrypt comparison (bit for bit
     against libxcrypt on 102,064 random cases), both under AddressSanitizer and UBSan; the whole server also passes
     conformance as an ASan/UBSan build, libFuzzer runs on every parser, and a hostile-client test (slow partial
     requests, oversize headers and bodies, garbage, resets, pipelining).
2. **Load measurement:**
   - A fresh copy of the full seed per run (`CREATE DATABASE … TEMPLATE`).
   - Load from the challenge's own `loadgen` with think time scaled to 0.1, so a few thousand users saturate the
     server; 20 s ramp, 40 s measured.
   - On the development VM only, Postgres and the server are pinned to 3 CPUs and the load generator to the 4th,
     and a run counts only if the load generator stays under 0.75 cores (the scoring rule's limit). Nothing is
     pinned in the submission itself.
   - The main metric is **CPU microseconds per request**, separately for the server and for Postgres (all backends,
     including exited ones), read from `/proc` over the measured window. It transfers between machines better than
     raw user counts.
3. **Comparison discipline:**
   - Variants are separate builds that differ only in `src/config.hpp` constants.
   - Runs are interleaved (A, B, A, B, …) in at least two rounds, with nothing else running.
   - A change is kept only if every round agrees in direction and the gain exceeds the run-to-run noise (about 3%
     on the development VM).
   - Choices between SQL forms will be timed directly in Postgres with `pgbench` (statement cost alone), with one
     load run to confirm.

Examples of decisions made this way:

| Comparison (6,000 users, think 0.1) | Result | Kept |
|---|---|---|
| Batched reads vs one statement per request | 14.8k/15.0k vs 9.8k/9.9k req/s; Postgres 136–139 vs 197 µs/request | batched |
| Arena allocator vs `malloc` | 3–6% less app CPU, lower p95 in all 3 rounds | arena allocator |
| Rust leader on the same VM, interleaved | 13.7k/14.1k req/s, Postgres 137–140 µs/request | — |

## Local results (development VM: relative numbers only)

Four-vCPU cloud VM (Intel Xeon 5th gen, no SMT), Postgres 18.6 tuned by `box/pg-conf.sh`, full seed, 3 CPUs for
Postgres + server. These are not benchmark-box numbers; they compare entries run the same way on the same VM.

| Entry | Max req/s | p95 at 6,000 users | Postgres µs/req | Server µs/req |
|---|--:|--:|--:|--:|
| This server | 14,800–15,300 | 39–64 ms | 130–139 | 43–45 |
| rust-tokio-Scooter1337 | 13,100–14,100 | 90–145 ms | 137–148 | 53–60 |
| c-iouring-tigokraft (one run) | 10,400 | 246 ms | 219 | 57 |

Other measurements:
- 15,000 idle keep-alive connections cost 56 bytes each (840 KB); the VM's descriptor limit prevents more.
- Postgres restarted in the middle of a load run: 2 errors in 155,338 requests (both writes in flight at that
  moment), all connections re-established.
- bcrypt: 102,064 random cases identical to libxcrypt (costs 4/5/10, `$2a$`/`$2b$`/`$2y$`).

On an 8-vCPU / 16 GB Ubuntu Server 24.04 VM (Intel i7-11700K host), set up with `box/setup-box.sh` and run with the
maintainer's `loadgen search` at real think time, both entries on the same machine:

| 110,000 users, 5-minute probe | p95 | p99 |
|---|--:|--:|
| This server | 455 ms | 519 ms |
| rust-tokio-Scooter1337 | 839 ms | 1,013 ms |

The CPU split for my solution on that machine was 15% server, 77% Postgres.

## Tunables (`src/config.hpp`, rebuild to change)

| Constant | Default | Meaning |
|---|---|---|
| `kCpusPerEventLoop` | 4 | event loops = usable CPUs / 4 (2 on the box) |
| `kReadConnsPerLoop` / `kWriteConnsPerLoop` | 4 / 1 | Postgres connections per loop |
| `kReadDepth` | 1 | sync groups in flight per read connection |
| `kBatchMaxPoint` / `Comments` / `List` / `Feed` | 64 / 32 / 16 / 8 | batch caps per statement kind |
| `kFeedMaxInflight` | 2 | read connections per loop that may run feed batches at once |
| `kWriteBatchMax` | 128 | writes per group commit |
| `kBcryptThreads` / `kBcryptBatchWaitMs` | 1 / 100 | bcrypt workers; wait to fill a 4-hash batch |

## Build, run, test

```bash
sudo bash install.sh          # toolchain and libraries from the Ubuntu archive
bash build.sh                 # bin/conduit (one g++ invocation, -O3 -march=native -flto)
DATABASE_URL=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
bash test/run.sh submissions/cpp-iouring-Escaloan     # conformance (from the repository root)
```
