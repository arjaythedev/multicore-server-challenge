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
`APP_THREADS` (`min(ceil(cores/4), 8)`), `DB_READ_CONNS` (read connections per worker, `3`), `BCRYPT_THREADS`
(`min(ceil(cores/4), 2)`: one main thread and a helper), `WRITE_BATCH_US` (group-commit wait when a single write is pending, `1000`; `0` = none),
`BCRYPT_BATCH_MS` (how long fewer than 6 queued logins wait for more to share a bcrypt run, `150`; `0` = none),
`READ_BATCH_MS` (how long the oldest queued read waits for more reads to join its batch, default `0` = none),
`READ_SHARE_PCT` (an article-by-slug batch uses the shared statement when its distinct slugs are at most
`pct`% of its jobs, `100`),
`SCHED_BATCH` (every thread runs under the `SCHED_BATCH` scheduling policy, `1`; `0` = the default policy),
`HTTP_GZIP` (`0` never, `1` always, unset = adaptive). Postgres connections total `APP_THREADS * (DB_READ_CONNS + 1)` and must be at most 95 (startup fails otherwise); on 8 cores that is 2 * 4 = 8. `GET /api/tags` returning 200 is the health check and answers within 60 s of `start.sh`.

## How it works

- **No runtime.** `_start` (`src/main.s`) reads the environment, parses `DATABASE_URL`, initialises the JWT
  HMAC context from `JWT_SECRET`, raises `RLIMIT_NOFILE`, ignores `SIGPIPE`, then spawns the bcrypt thread(s)
  and one worker thread per `APP_THREADS` and parks. Threads are raw `clone` (`rt.s`); memory comes from a
  per-worker size-classed allocator over `mmap` (`rt.s`), never libc `malloc`. Freed blocks up to 1 MB are kept
  for reuse, at most 64 per size class above 64 KB, so a list response's 128 KB+ buffer is not mapped and
  unmapped on every request. The clock is read through the vDSO.
- **One epoll loop per worker** (`src/server.s`). Each worker owns its listen socket (`SO_REUSEPORT`), its
  client connections, its read Postgres connections and one write connection. A request is parsed (`http.s`),
  turned into a job (`J_*`), and routed (`api.s`) to an endpoint. Endpoints that need the database hand the job
  to a Postgres connection with a continuation; the continuation renders the response (`render.s`) when the
  backend's `ReadyForQuery` arrives. Keep-alive requests are pipelined. As in Rust, `Expect: 100-continue` gets
  its interim response once the head is complete, and `HEAD` answers with the head only.
- **Postgres** (`pg.s`, `pgio.s`, `sql.s`): blocking connect with SCRAM-SHA-256 at startup, then non-blocking
  extended-query protocol. Statements are prepared once per connection.
- **Read batching** (`readb.s`, `readr.s`; a port of the Rust `read_batch.rs`): each read joins a per-family
  queue shared by all workers, as Rust's queues are shared by its tasks; whenever a read connection is idle it
  takes the oldest family's queued jobs (up to 512) and runs them as one statement whose parameters are arrays.
  The oldest family is left to gather until its first job has waited `READ_BATCH_MS` (or 512 jobs are queued);
  the worker's `epoll_wait` times out at that deadline. A lone job runs its own statement. Lists and articles by
  slug use Rust's shared ("packed") forms, comments do when each slug is asked at least twice on average, and
  they are rendered from the shared rows by `readr.s`; tags run once for every waiter. If a batch fails, each job is retried on its own. A batch can hold other workers' jobs: their
  reply bytes are copied once into a reference-counted block, and each job is handed back to its own worker on a
  lock-free stack (the way bcrypt results come back), which renders and sends it, so client sockets, gzip and
  allocations stay with their worker. A block freed on another worker goes back to the worker that allocated it.
  One spinlock guards the queues and is held only to link or unlink jobs.
- **Writes** use durable group commit on the worker's write connection (`writer.s`, a port of the Rust
  `writer.rs`): up to 128 queued writes run as one pipelined `BEGIN` … `COMMIT`, and each reply is released only
  after the `COMMIT` returns. If a statement fails, the group has rolled back, so every write in it is retried
  on its own; a failed `COMMIT` is never retried. Consecutive favorites, unfavorites, follows, unfollows or new
  comments in a group run as one statement over arrays of their parameters (new comment ids are drawn in request
  order), and its rows are split back per request. Each execution takes one `READ COMMITTED` snapshot; nothing is cached across requests.
- **bcrypt** (`bcrypt.s`, `bcq.s`): password hashing/verification runs on dedicated thread(s) at cost 10. Each
  batch takes up to 6 queued jobs of the oldest job's kind and runs them as one interleaved 6-lane call (Rust
  batches up to 5). With fewer than 6 queued, the thread waits until the oldest has waited `BCRYPT_BATCH_MS`
  (150 ms) for more to arrive. When 6 or more jobs are still queued behind the batch it is about to run, the
  main bcrypt thread hands the oldest 6 to an idle helper thread. A job that waits more than 8 s before starting
  is shed with a 503, matching the Rust reference.
- **gzip** (`gzip.s`, `egress.s`): as in Rust, a response body of at least 1024 bytes is gzipped when the client
  accepts gzip and the adaptive controller (a port of Rust's `egress`) says so, i.e. only while the box is sending
  over 100 MB/s with TCP retransmits, and kept only if smaller. Each worker has its own compressor state.
- **JWT** (`crypto.s`): HS256, verified on every authenticated request.
- **Failures** (`server.s`, `pgio.s`): if `accept4` fails for any reason other than `EAGAIN`, for example
  `EMFILE` at the open-file limit, the worker stops watching its listen socket for 10 ms, as Rust's accept loop
  sleeps 10 ms. Otherwise the level-triggered listen socket would wake the loop again at once and spin. A
  Postgres connection that fails or is closed by the server, including an idle one, is marked down, and the
  requests waiting on it fail. New reads go to the other read connections. The loop reconnects it,
  with its prepared statements and session settings, trying at most every 500 ms.

## Optimizations and why

About two thirds of the server-side CPU (app plus Postgres) goes to Postgres, so the plan was: send Postgres
exactly the work the Rust entry sends it, and spend less CPU on everything else.

- **Same SQL, same batching (as first submitted).** The batched reads, group commit and gzip controller are ports
  of the Rust entry's, with the same SQL text. Both servers pass the same 197 conformance checks, and the read responses were diffed
  against Rust's (2,033 distinct reads, 0 differences). Postgres does the same work per request for both, so the
  difference comes down to how cheap the app side is.
- **No runtime.** No libc, no async runtime, no allocator library: one epoll loop per worker thread, a size-class
  allocator per worker, and raw syscalls. From 32k users up (think scale 0.2) the server used 0.89-0.93x the Rust
  entry's app CPU at the same request rate. On a box where the CPU is the limit, that CPU goes to Postgres instead.
- **Shared read queues, nothing else shared.** Each worker owns its listen socket (`SO_REUSEPORT`), its client
  connections, its Postgres connections and its allocator; the read queues and the bcrypt queue are the only
  structures the workers share. With a read queue per worker, each worker ran its own batch of every family on
  its own two read connections, so it paid each statement's fixed cost once per worker: at 200,000 users all six
  read connections were busy and a read waited for one about three times as long as in Rust, whose queues are
  shared. With one set of queues over all six connections, the 200,000-user p95 went from 133 to 70 ms (table
  below), and at saturation on the same box the two were within 1% (one pair, 51.5k against 52.1k req/s).
- **6-lane bcrypt.** Login is the one CPU-heavy endpoint: every hash is cost 10. The bcrypt thread runs up to 6
  queued jobs as one interleaved call. Six independent Blowfish states hide each other's table-lookup latency,
  so a batch of 6 costs 12.4 ms per hash against 13.7 ms with 5 lanes and 15.8 ms with 4. A round takes the
  four S-box indexes out of one copy of the lane (one high-byte read, two shifts, two zero-extends): 12
  instructions per lane and round instead of 14, which made a hash 5% cheaper on an idle core and 10-12% cheaper
  while the other hyperthread of the core runs a memory-bound loop. That is the usual case under load: the hash
  costs about 2.5x its idle time next to a busy sibling.
- **Waiting to fill the lanes.** At 150,000 users logins arrive at about 40/s. Run as they come, the faster
  hash only shortened the queue: the thread stayed 97-98% busy on 1- to 5-lane runs. Waiting up to 150 ms for 6
  jobs brought it to 89% (the rest of the core goes to the workers and Postgres), at a login p50 of 246 ms.
  Once logins queue 6 deep on their own the wait never starts, and the faster hash is the whole gain.
- **A helper bcrypt thread for backlogs only.** A second bcrypt thread that took jobs as they came raised the
  overall p95 from 14 to 48 ms: it split the queue into smaller, costlier batches and took a core from the
  workers and Postgres all the time. But one thread caps logins: on a 5-core box at 165,000 users logins waited
  3.6-4.9 s at p95. Now the helper sleeps until a full 6-job batch is waiting behind the running one, and then
  runs that batch. On the same box and load, login p95 went from 3.4-5.1 s to 0.41 s (two runs each) with no
  login errors either way. The 8 s shed rule for queued logins is the Rust entry's.
- **Feed SQL.** The feed statement is #124's, with the window below read lazily. For the followees that two or
  more viewers in a feed batch share (up to 20), the batch reads once the newest `take` article ids of each, where
  `take` is the largest offset + limit among the viewers who follow them. A viewer's cutoff is the highest of its
  shared followees' (offset + limit)-th newest ids: that author alone has that many articles at or above it, so
  the page can't hold an older article, and the viewer's walk over its followees' articles stops there. The capped
  count is 1000 when one of those followees has 1000 or more articles and otherwise one `LIMIT 1000` scan, and
  `enable_memoize` is off for the session.
- **Recent feeds from one window.** When a viewer's cutoff from those shared followees falls among the newest
  32 × (batch size) article ids (at most 2,048, and only in batches of 32 or more), the batch reads the newest
  articles once and takes the viewer's page from them; other viewers keep the walk over their followees. #124
  reads the whole window; this reads it only down to the lowest cutoff that uses it. Replayed on real captured
  batches, with identical rows, the feed statement took 3% less time than #124's and 4-7% less than ours before it.
- **Shared reads where keys repeat.** Article-by-slug batches always use the shared statement, which reads each
  slug once (14% less Postgres time for that family, measured with a 20 ms wait). Comments keep Rust's rule
  (shared only when each slug is asked at least twice on average): a thread has about 1.5 comments, and the shared
  form cost 15% more when slugs did not repeat. Its shared form looks up the viewer's follows only among each
  article's own commenters. The per-request form checks each commenter with one `EXISTS` probe on `follows`
  rather than building the viewer's whole followee array (identical rows on replayed batches),
  and the shared article-by-slug form aggregates the tag names of the batch's articles in one pass.
- **Fewer lookups in the author and favorited lists.** An author list has one author, so whether the viewer follows
  them is one `follows` probe per request instead of one per row. Both lists find the viewer's favorites on the page
  with one `favorites` probe (`user_id` = the viewer and `article_id = ANY(page)`), and the favorited list checks
  the follows of the page's distinct authors with one probe, as #124's author list does. Comment rows carry
  `updated_at` only when it differs from `created_at`. On replayed batches, with identical rows, that is 3.9% less
  time for the author list, 1.6% for the favorited list and 3-8% for comments. At 150,000 users on 5 vCPUs (120 s
  holds in two interleaved before/after/after/before blocks), p95 went from 63 to 55 ms and from 50 to 45 ms, with
  0.6-0.7% less Postgres time.
- **Where it counts.** These SQL changes matter most once the box is out of CPU. With the target held to 5 vCPUs
  at 165,000 users (aged database, 120 s holds, two runs each, interleaved), the previous build failed on p95
  (617 and 566 ms, p99 751 and 690) at 40.0-40.5k req/s, and this one passed (p95 353 and 359, p99 479 and 462) at
  41.9k req/s; the feed's p95 went from 723-786 ms to 492-514. On a second box of the same type, also held to
  5 vCPUs, a build with them passed a scored-length hold (60 s ramp, 300 s measured, warm cache) at 170,000 users:
  43,860 req/s, p95 252 ms, p99 377 ms, no errors.
- **`SCHED_BATCH`.** At startup, before any thread starts, the process puts itself under the `SCHED_BATCH`
  scheduling policy, which every thread inherits. It needs no privileges, it is set in-process, and
  `SCHED_BATCH=0` turns it off. A worker woken by epoll or a futex then no longer preempts a running Postgres
  backend: it runs when that backend blocks or its time slice ends, and finds more work waiting. On the same
  code with and without it (150,000 users, 5 vCPUs, four 120 s holds each, interleaved), the workers used 15%
  less CPU, Postgres time was 5% lower, and p95 went from 89 to 63 ms (p99 128 to 94). The bcrypt threads used
  about 10% more CPU, and logins were slightly faster (p95 322-341 ms against 339-366).
- **Both, in scored-length holds.** The list changes and `SCHED_BATCH` together, against the build before them,
  on another box held to 5 vCPUs (60 s ramp, 300 s measured, warm cache, builds interleaved; every hold passed
  with no errors). At 170,000 users p95 went from 152 and 141 ms to 116 and 138 (p99 250 and 237 to 188 and 230)
  with 4% less Postgres time, and at 180,000 users from 233 and 230 ms to 227 and 204 (p99 346 and 355 to 339 and
  311) with 2% less. At 190,000 users this build served 48.6k req/s at p95 303 ms and p99 432 (one hold), the
  build before them 47.8k and 47.4k at p95 399 and 432, p99 539 and 566.
- **Waiting to fill read batches: off by default.** `READ_BATCH_MS` lets the oldest family's queue gather until
  its first job is that old, so batches are bigger and share more. While the box has CPU to spare it saves a lot:
  at 150,000 users on 8 vCPUs, total Postgres execution time per hold went from 950 s to 816 s at 20 ms and box
  idle from 3% to 10%, for a p95 of 80 ms instead of 45. But once the box is over capacity the queues fill on
  their own while every read still waits the extra time: on the 5-vCPU setup above, p95 was 350 ms with no wait,
  362 ms at 20 ms and 435 ms at 40 ms, for only 4-5% less Postgres time. The score is decided in that regime, so
  the wait is off.

## Measurements

These are not official scores, and they are for the builds in PR #82; the changes since were
measured on the 5-vCPU setup in the sections above. Closest to the official run: an AWS c7i.2xlarge target (8 vCPUs, Xeon 8488C,
15.7 GB) set up with the repo's `box/setup-box.sh`, the full seed, and the repo's `conduit-loadgen` on a separate
c7i.4xlarge over the target's four addresses, at its default think time. Each run starts from a fresh database
that is first aged by 128,000 users for 300 s (the official search reaches high loads on a database its earlier
steps have written to), then holds 200,000 users: a 60 s ramp and 300 s measured. 200,000 is as high as the
harness goes (the service's `LimitNOFILE` is 200000), so what is left to compare is the margin under the limits.
Rust is the same entry as below, on the same boxes in the same session.

| build, 200,000 users | req/s | p50 (ms) | p95 (ms) | p99 (ms) | errors | app / Postgres CPU (cores) | box CPU busy |
|---|---|---|---|---|---|---|---|
| this server (2 workers, 3 read connections each) | 52,595 | 16 | 61 | 104 | 0.03% | 1.67 / 5.75 | 93.8% |
| this server, 3 workers with 2 read connections each | 52,575 | 18 | 71 | 133 | 0.03% | 1.72 / 5.76 | 94.5% |
| 3 workers, a read queue per worker | 52,162 | 46 | 133 | 192 | 0.03% | 1.70 / 5.61 | 92.7% |
| Rust | 52,438 | 25 | 89 | 158 | 0.03% | 1.94 / 5.58 | 94.9% |

All four pass. The first two rows were each run twice; the repeats were within 1.2 ms on p95 and 5.2 ms on
p99. Both use six read connections and the same Postgres CPU; with two workers every read endpoint's p50 and p95
were 5-13% lower. About 90% of the errors are logins: about 28% of them (22% for Rust)
wait 8 s for the bcrypt thread (one, in that build) and are shed with a 503, but logins are about 0.1% of the requests. The rest
are about 450 reads per run that hit the load generator's 10 s timeout, about the same for Rust. The process's
memory stayed flat (135-138 MB with two workers) through the measured window.

The repo's own search (`score/chain.sh`, the official scoring script) on the same boxes: score 200,000, every
probe passing; its 5-minute hold at 200,000 users ran 52,542 req/s, p50 18 ms, p95 67 ms, p99 111 ms, 0.03%
errors (with three workers: 52,524 req/s, p95 80 ms, p99 156 ms).

The tables below were measured on an earlier build, before the read queues were shared and before the fixes
under **Failures**. They are same-box numbers: an AWS c7i.2xlarge, 8 vCPUs, Xeon 8488C (Ubuntu 24.04,
PostgreSQL 18, the 2% dev seed), the repo's loadgen niced on the same box with `-think-scale 0.2` or `0.05`,
10 s ramp, 30 s measured, a fresh database per run, two runs per point, against that Rust entry on the same box.

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
- The optional read gather wait follows #103 (gichamba, 20 ms) and #117 (nick-potts, a 20 ms drain gap).
- The feed statement and the lists' `= ANY` favorite and follow probes are #124's (dennisimoo), which credits the
  feed cutoff from the most-shared followees to #102 and the per-viewer `= ANY` probes to #53, #47 and #95.
- Merging same-type writes into one statement and giving logins more than one bcrypt thread follow #105
  (theCatWisel).
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

Validation: the repo's 197 conformance checks pass on this build, also with `SCHED_BATCH=0`. The first submitted
build also passed them with AVX-512, AVX2, BMI2 and SHA-NI each switched off (the server picks code paths with
CPUID at startup), and its responses were diffed byte for byte against Rust's (logins, reads, concurrent reads, writes, reads after writes: 0 differences). Each module was also
tested on its own against reference implementations (Python's hashlib/hmac for SHA-256/HMAC/JWT, the Rust
`bcrypt` crate, zlib for gzip output); those harnesses are not part of this folder.
