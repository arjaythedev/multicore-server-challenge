# Assembly / epoll

Front: direct

A Conduit (RealWorld) API server written entirely in x86-64 assembly: GNU `as` with `.intel_syntax noprefix`,
linked statically with `ld`, no libc, raw Linux syscalls only. It mirrors the behaviour, SQL and response bytes
of the author's earlier Rust entry (`rust-tokio-nickita-khylkouski`, the first two commits of PR #82, called
"Rust" below) on its default-config path (its `start.sh` defaults, including its adaptive gzip).

GNU binutils 2.42 (Ubuntu 24.04's `binutils` package: `as`, `ld`), PostgreSQL 18. No framework and no driver: the
HTTP/1.1 server and the Postgres wire protocol (SCRAM-SHA-256, extended query) are written in this folder.

## Build and run

```
./install.sh     # once, as root: installs binutils (as, ld)
./build.sh       # assembles src/*.s and links ./conduit (as a normal user)
./start.sh       # runs ./conduit in the foreground
```

Required environment: `DATABASE_URL`, `JWT_SECRET`. Optional: `HOST` (default `127.0.0.1`), `PORT` (`3000`),
`APP_THREADS` (`min(ceil(3*cores/8), 8)`), `DB_READ_CONNS` (read connections per worker, `2`), `BCRYPT_THREADS`
(`ceil(cores/8)`), `WRITE_BATCH_US` (group-commit wait when a single write is pending, `1000`; `0` = none),
`HTTP_GZIP` (`0` never, `1` always, unset = adaptive). Postgres connections total `APP_THREADS * (DB_READ_CONNS + 1)` and must be at most 95 (startup fails otherwise); on 8 cores that is 3 * 3 = 9. `GET /api/tags` returning 200 is the health check and answers within 60 s of `start.sh`.

## How it works

- **No runtime.** `_start` (`src/main.s`) reads the environment, parses `DATABASE_URL`, initialises the JWT
  HMAC context from `JWT_SECRET`, raises `RLIMIT_NOFILE`, ignores `SIGPIPE`, then spawns the bcrypt thread(s)
  and one worker thread per `APP_THREADS` and parks. Threads are raw `clone` (`rt.s`); memory comes from a
  per-worker size-classed allocator over `mmap` (`rt.s`), never libc `malloc`.
- **One epoll loop per worker** (`src/server.s`). Each worker owns its listen socket (`SO_REUSEPORT`), its
  client connections, its read Postgres connections and one write connection. A request is parsed (`http.s`),
  turned into a job (`J_*`), and routed (`api.s`) to an endpoint. Endpoints that need the database hand the job
  to a Postgres connection with a continuation; the continuation renders the response (`render.s`) when the
  backend's `ReadyForQuery` arrives. Keep-alive requests are pipelined. As in Rust, `Expect: 100-continue` gets
  its interim response once the head is complete, and `HEAD` answers with the head only.
- **Postgres** (`pg.s`, `pgio.s`, `sql.s`): blocking connect with SCRAM-SHA-256 at startup, then non-blocking
  extended-query protocol. Statements are prepared once per connection.
- **Read batching** (`readb.s`, `readr.s`; a port of the Rust `read_batch.rs`): each read joins a per-family
  queue; whenever a read connection is idle it takes the oldest family's queued jobs (up to 512) and runs them as
  one statement whose parameters are arrays, the same SQL text as Rust. A lone job runs its own statement. Lists,
  and article / comment reads with repeated slugs, use Rust's shared ("packed") forms and are rendered from the
  shared rows by `readr.s`; tags run once for every waiter. If a batch fails, each job is retried on its own.
- **Writes** use durable group commit on the worker's write connection (`writer.s`, a port of the Rust
  `writer.rs`): up to 128 queued writes run as one pipelined `BEGIN` … `COMMIT`, and each reply is released only
  after the `COMMIT` returns. If a statement fails, the group has rolled back, so every write in it is retried
  on its own; a failed `COMMIT` is never retried. Each execution takes one `READ COMMITTED` snapshot; nothing is cached across requests.
- **bcrypt** (`bcrypt.s`, `bcq.s`): password hashing/verification runs on dedicated thread(s) at cost 10. Each
  batch takes up to 6 queued jobs of the oldest job's kind and runs them as one interleaved 6-lane call (Rust
  batches up to 5). A job that waits more than 8 s before starting is shed with a 503, matching the Rust reference.
- **gzip** (`gzip.s`, `egress.s`): as in Rust, a response body of at least 1024 bytes is gzipped when the client
  accepts gzip and the adaptive controller (a port of Rust's `egress`) says so, i.e. only while the box is sending
  over 100 MB/s with TCP retransmits, and kept only if smaller. Each worker has its own compressor state.
- **JWT** (`crypto.s`): HS256, verified on every authenticated request.

## Optimizations and why

About two thirds of the server-side CPU (app plus Postgres) goes to Postgres, so the plan was: send Postgres
exactly the work the Rust entry sends it, and spend less CPU on everything else.

- **Same SQL, same batching.** The batched reads, group commit and gzip controller are ports of the Rust entry's,
  with the same SQL text. Both servers pass the same 197 conformance checks, and the read responses were diffed
  against Rust's (2,033 distinct reads, 0 differences). Postgres does the same work per request for both, so the
  difference comes down to how cheap the app side is.
- **No runtime.** No libc, no async runtime, no allocator library: one epoll loop per worker thread, a size-class
  allocator per worker, and raw syscalls. From 32k users up (think scale 0.2) the server used 0.89-0.93x the Rust
  entry's app CPU at the same request rate. On a box where the CPU is the limit, that CPU goes to Postgres instead.
- **Nothing shared between workers.** Each worker owns its listen socket (`SO_REUSEPORT`), its connections, its
  Postgres connections and its allocator; the bcrypt queue is the only structure the workers share. We tried one
  read queue shared by all workers: it cut the wait for a free read connection (our p50 at 32k users is 3.3 ms
  against Rust's 2.1 ms), but it cost about 4% of capacity at saturation (72k against 75k req/s). We kept
  per-worker.
- **6-lane bcrypt.** Login is the one CPU-heavy endpoint: every hash is cost 10. The bcrypt thread runs up to 6
  queued jobs as one interleaved call. Six independent Blowfish states hide each other's table-lookup latency,
  so a batch of 6 costs 13.3 ms per hash against 14.6 ms with 5 lanes. At 8k users the login p50 was 62 ms against
  Rust's 185 ms, and with only login traffic it served 74.6 logins/s against Rust's 70.5.
- **One bcrypt thread.** A second bcrypt thread raised the overall p95 from 14 to 48 ms, because it takes a core
  from the workers and Postgres. The 8 s shed rule for queued logins is the Rust entry's.

## Measurements

These are not official scores. The official run puts the load generator on separate machines; these numbers are
same-box: an AWS c7i.2xlarge, 8 vCPUs, Xeon 8488C (Ubuntu 24.04, PostgreSQL 18, the 2% dev seed), the repo's
loadgen niced on the same box with `-think-scale 0.2` or `0.05`, 10 s ramp, 30 s measured, a fresh database per
run, two runs per point, against that Rust entry on the same box.

| users, think scale | this server req/s | Rust req/s | p95 (ms) this / Rust | app CPU (cores) this / Rust |
|---|---|---|---|---|
| 8,000, 0.2 | 10,589 | 10,578 | 1.8 / 1.9 | 0.78 / 0.82 |
| 32,000, 0.2 | 42,113 | 42,178 | 12.9 / 11.7 | 1.65 / 1.86 |
| 44,000, 0.2 | 52,946 | 52,439 | 105 / 159 | 1.77 / 1.95 |
| 32,000, 0.05 (saturated) | **75,115** | 66,157 | 329 / 370 | 2.16 / 2.16 |
| 32,000, 0.2, `HTTP_GZIP=1` | 41,587 | 41,289 | 36.0 / 48.9 | 2.16 / 2.49 |

At saturation it serves 13.5% more requests than the Rust entry. At think scale 0.2 the highest load both pass
(p95 under 500 ms, p99 under 1 s, under 1% errors) is 44,000 users, and both fail at 48,000.

Longer runs near the limit, same method except: the same c7i.2xlarge box with the load generator on it (the
official run puts it on separate machines), think scale 0.2, a 10 s ramp and 10 s warm-up before a 120 s scored
window, two runs per point (the table shows their mean), and a point passes only if every run passes:

| users | this server req/s | Rust req/s | p50 (ms) this / Rust | p95 (ms) this / Rust | p99 (ms) this / Rust | both pass |
|---|---|---|---|---|---|---|
| 48,000 | 60,316 | 59,045 | 19 / 32 | 89 / 118 | 138 / 160 | yes |
| 52,000 | 63,751 | 60,769 | 35 / 79 | 128 / 176 | 196 / 240 | yes |
| 56,000 | 65,782 | 60,749 | 67 / 132 | 189 / 274 | 320 / 616 | yes |
| 60,000 | 65,194 | 61,983 | 110 / 187 | 292 / 324 | 683 / 420 | yes |

Both servers pass 60,000 users, the highest point tested, so where either one fails is not measured. From 52,000
up this server serves 5-8% more requests at 45-59% of Rust's median latency, but at 60,000 its p99 is higher
(683 ms against 420), so it is closer to the 1 s limit there. One run at 56,000 (Rust) and one at 60,000 (this
server) were flagged as the load generator falling behind. These pass at 48,000 where the 30 s runs above fail:
in those, most of the scored p99 tail is one stall of the load generator at the end of its ramp, the same with
both servers, which the warm-up keeps out of the scored window.

## Credits

- The read batching, group commit, adaptive gzip controller and bcrypt batching/shedding are ports of the
  author's earlier Rust entry (see the top of this README), which builds on Scooter1337's rust-tokio submission
  (#7) and cknutson12's rust-hyper submission (#1), both MIT-licensed. As that entry's README credits them, the
  per-family read queue comes from #22 (its batch cap from #52), the shared list/article SQL from #32, and the
  feed's cap for authors with 1000+ articles from #61.
- bcrypt follows OpenBSD/Openwall crypt_blowfish.
- gzip.s: deflate design and parameters follow libdeflate (Copyright 2016 Eric Biggers, 2024 Google LLC; MIT
  license). The PCLMULQDQ CRC32 is translated from Chromium zlib's crc32_sse42_simd_ (Copyright 2017 The Chromium
  Authors; BSD-3-Clause). Full notices are in src/gzip.s.

## Layout

```
src/
  main.s    entry, env, thread spawn             http.s    HTTP/1.1 parser, percent-decode, head writer
  rt.s      allocator, threads, memcpy, time     json.s    JSON reader + writer
  cpu.s     CPU feature detection                server.s  epoll loop, connections, send path
  crypto.s  SHA-256, HMAC, base64url, JWT        pgio.s    Postgres op queue, DataRow scan
  bcrypt.s  bcrypt hash/verify                   api.s     routing + the endpoints
  pg.s      Postgres protocol                    render.s  JSON response bodies
  bcq.s     bcrypt work queue                    sql.s     prepared statement text
  writer.s  group commit                         readb.s   read batching (queues, batched SQL, demux)
  readr.s   packed-row renderers               gzip.s    deflate + gzip framing
  egress.s  adaptive gzip controller
  defs.inc  cross-module constants               app.inc   app struct layouts + macros
```

Validation: the repo's 197 conformance checks pass on this build and on builds with AVX-512, AVX2, BMI2 and SHA-NI
each switched off (the server picks code paths with CPUID at startup), and responses were diffed byte for byte
against Rust's (logins, reads, concurrent reads, writes, reads after writes: 0 differences). Each module was also
tested on its own against reference implementations (Python's hashlib/hmac for SHA-256/HMAC/JWT, the Rust
`bcrypt` crate, zlib for gzip output); those harnesses are not part of this folder.
