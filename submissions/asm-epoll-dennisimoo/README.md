# Assembly / epoll, batched reads with collection windows

Front: direct

A fork of nickita-khylkouski's `asm-epoll` entry (#82, MIT; its `LICENSE` is kept unchanged in this folder): the
same Conduit (RealWorld) server in x86-64 assembly, with its read scheduler, four of its batched SQL statements,
its bcrypt batching and its socket handling changed to make Postgres do less work per request. Everything not
listed under **What changed** is the parent's code, and the parent's README describes it; this one describes the
differences and what they measured.

GNU binutils 2.42 (Ubuntu 24.04's `binutils` package: `as` with `.intel_syntax noprefix`, `ld`, linked
statically), no libc, raw Linux syscalls only. PostgreSQL 18. No framework and no driver: the HTTP/1.1 server and
the Postgres wire protocol (SCRAM-SHA-256, extended query) are written in this folder.

## Build and run

```
./install.sh     # once, as root: installs binutils (as, ld)
./build.sh       # assembles src/*.s and links ./conduit (as a normal user)
./start.sh       # runs ./conduit in the foreground with the defaults below
```

Required environment: `DATABASE_URL`, `JWT_SECRET`. Optional: `HOST` (`127.0.0.1`), `PORT` (`3000`), and the
tuning knobs. `start.sh` sets the first four to the values measured for an 8-core box; the rest default inside
the binary:

| variable | shipped default | meaning |
|---|---|---|
| `APP_THREADS` | 4 | epoll workers (the parent ran 2 on 8 cores) |
| `DB_READ_CONNS` | 2 | read connections per worker; plus one write connection each, 4 × (2 + 1) = 12 in total (at most 95) |
| `READ_BATCH_US` | 50000 | read-collection window in µs; `0` = the parent's behaviour (take whatever has arrived) |
| `READ_BATCH_MAX` | 256 | the most reads in one batched statement (parent: 512); that many queued also ends a window early |
| `READ_BATCH_US_SMALL` | `READ_BATCH_US` / 4 | window of the cheap families: tags, profile, user by id, user by email, article by id |
| `BCRYPT_LANES_MIN` | 4 | a bcrypt batch with fewer same-kind jobs waits for company; `1` = never |
| `BCRYPT_WAIT_US` | 15000 | how long the oldest job of such a batch may wait; `0` = never |
| `BCRYPT_THREADS` | `ceil(cores/8)` | unchanged |
| `WRITE_BATCH_US` | 1000 | group-commit wait for a lone write, unchanged; `0` = none |
| `HTTP_GZIP` | adaptive | `0` never, `1` always, unchanged |
| `HTTP_QUICKACK` | 0 | `1` sets `TCP_QUICKACK=0` after each response (measured harmful, see below) |

`GET /api/tags` returning 200 is the health check and answers within 60 s of `start.sh`.

## Why Postgres CPU per request

On the official box the parent scored 130,000 users at 33,335 req/s with 23% of the CPU in the app and 69% in
Postgres: about 160 µs of Postgres CPU per request, and every entry near the top of the leaderboard sits at about
that figure. The app side is already cheap (no runtime, no libc), so the only lever left on an 8-core box is how
much Postgres work one request costs. The parent batches reads so that N requests of one family run as one
statement whose parameters are arrays; the changes below make those batches larger at the same load and make the
batched statements themselves cheaper.

How much a batch is worth was measured directly: CPU of one batched execution against N single executions of
the parent's single-request statement, same seed, N = 1 / 8 / 32 / 128 / 256 / 512 (lower is better; 0.5 means
the batch costs half as much Postgres CPU as the requests would cost one by one):

| family | N=1 | 8 | 32 | 128 | 256 | 512 |
|---|---|---|---|---|---|---|
| list_all (`GET /articles`) | 1.59 | 0.47 | 0.14 | 0.08 | 0.09 | 0.13 |
| by tag | 1.47 | 0.67 | 0.55 | 0.31 | 0.37 | 0.32 |
| by author | 2.70 | 0.97 | 0.73 | 0.58 | 0.70 | 0.59 |
| feed | 1.93 | 0.84 | 0.68 | 0.57 | 0.55 | 0.50 |
| article by slug (batch form) | 0.97 | 0.36 | 0.25 | 0.24 | 0.25 | 0.31 |
| comments (batch form) | 0.94 | 0.53 | 0.33 | 0.36 | 0.34 | 0.51 |

Two things follow. A batched statement with one request in it costs more than the single statement (a lone job
still runs its own statement, as in the parent), and the gain flattens or turns around between 128 and 256, so
the cap went from 512 to 256. And the gain between N = 8 and N = 128 is large: the parent takes a family's queue
whenever a read connection is idle, so under moderate load, where a connection is usually idle, its batches hold a
handful of jobs and the lists run near the N = 8 column.

## What changed

1. **A collection window per family** (`readb.s`, `server.s`, `rt.s`, `app.inc`). Each family's queue records
   when it last went from empty to non-empty. When a read connection is idle and the oldest family is younger
   than its window (`READ_BATCH_US`, or `READ_BATCH_US_SMALL` for the five cheap families that are one index
   probe per request) and holds fewer than `READ_BATCH_MAX` jobs, the worker does not take it: it arms a
   per-worker `timerfd` (`rb_arm`, one timer per worker, never re-armed earlier than needed because the oldest
   head only gets older) and returns. When the timer fires (`rb_timer`) or the queue reaches the cap, the whole
   queue is taken as before. `READ_BATCH_US=0` restores the parent's scheduling exactly. The rest of the batching
   (shared queues over all workers, demux to the owning worker, retry one by one on failure) is the parent's.
2. **Four batched statements rewritten** (`readb.s`, the `qb_*` text). Same columns and rows as the parent's
   statements: the result sets were compared with `EXCEPT ALL` in both directions at N = 1 / 32 / 256 on two
   seeds, and the 197 conformance checks pass. Postgres CPU of the batched statement:
   - **list_all** (`qb_f00_shared`): −31% at N = 256. The generic plan joined per-viewer favorites/follows CTEs to
     the requests by a nested loop, O(N·M); now each request probes `favorites` and `follows` with `= ANY` of its
     own page's ids.
   - **by author** (`f02`): −10%. Tags and favorite counts are grouped once over the batch's article ids instead
     of being correlated subqueries per article, and the viewer's flags are per-request `= ANY` probes.
   - **feed** (`f04`): −14% at N ≥ 128. The 20 followees most shared across the batch (`count(*) >= 2`) give each
     viewer a cutoff: the id of their (limit + offset)th newest article from those followees alone. In a batch of
     32 or more, the newest `LEAST(2048, 32·N)` articles are read once by one backward primary-key scan; a viewer
     whose cutoff lies inside that window takes its page from it by one hash join instead of ~18 LATERAL index
     descents (one per followee). The others keep the parent's per-followee LATERAL, now stopping at the cutoff.
     The count is 1000 when a shared followee has 1000+ articles (the parent's rule from #61), otherwise one
     scan capped at 1000 rows. Page articles are fetched by one `= ANY` primary-key scan and each distinct author
     is looked up once.
   - **comments, shared form** (`f10_shared`): −59% at N = 256. The followed-authors subquery joined the `au`
     CTE inside the `ARRAY(...)`, which planned as a Join Filter; `= ANY((SELECT au FROM au)::bigint[])` makes it
     an Index Cond.

   GUCs tried on the batched statements and rejected as noise: `enable_memoize=off`, `work_mem=32MB`,
   `hash_mem_multiplier`, `enable_bitmapscan=off`; `enable_hashjoin=off` was catastrophic. The per-connection
   session setup (`q_session`) is unchanged.
3. **Four workers instead of two** (`start.sh`): 4 × 2 read connections + 4 write connections = 12. With Postgres
   cheaper, two workers became the latency limit at 150,000 users and up: rendering a 256-job batch blocks that
   worker's loop, and with two loops the other one has to carry all the accepts and sends meanwhile.
4. **bcrypt lane filling** (`bcq.s`, `main.s`). The parent runs up to 6 queued logins as one interleaved 6-lane
   call, but under load `perf` showed about 24 ms of CPU per hash because most batches held one or two lanes
   (full occupancy costs 13.3 ms per hash). Now a batch with fewer than `BCRYPT_LANES_MIN` same-kind jobs waits
   on the queue's futex, with a timeout, until the oldest job has waited `BCRYPT_WAIT_US`; a push wakes it at
   once. Job ages are kept in microseconds for this (`rt_mono_us`). The 8 s shed rule is unchanged. Measured at
   15 ms: 6-13% less bcrypt CPU per login, login p95 unchanged.
5. **`TCP_QUICKACK` off after each response: tried, shipped off** (`server.s`, `defs.inc`, `HTTP_QUICKACK=1`
   enables it). Setting it to 0 puts the socket in pingpong mode so the ACK of the next request rides on its
   response (the idea is from nick-potts' zig entry, where it cut the server's pure ACKs by 27%). With a read
   window the response often comes after the delayed-ACK timer, and in 5-minute holds at 160-200k users the
   build with it on degraded from the first minute (p95 1.2-2.3 s, ~1% timeouts, box 60-70% busy, Postgres and
   workers idle) while the same build with it off held 180k at p95 175 ms. So it is off by default.

## Measurements

These are not official scores and the rig is not the official box. Two 8 vCPU / 16 GB Ubuntu 24.04 VMs on an
AMD Ryzen 9 9950X host (single-queue virtio NIC with RPS enabled), set up with the repo's `box/setup-box.sh`
and the full seed, PostgreSQL 18. Load from two separate VMs (16 and 8 vCPUs) with the repo's loadgen, users split
2 : 1 between them, default think time, 60 s ramp and 150 s measured, a fresh database per run. Parent and fork
were run head to head on the identical rig on the same day. "SQL only" is this build with `READ_BATCH_US=0`.

| users | build | req/s | p50 (ms) | p95 (ms) | p99 (ms) | errors | app CPU (cores) | Postgres CPU (cores) | box busy |
|---|---|---|---|---|---|---|---|---|---|
| 100,000 | parent (nickita) | 26,262 | 17.6 | 127 | 349 | 0 | 1.51 | 4.42 | 76% |
| 100,000 | this, SQL only (window 0) | 26,217 | 23.5 | 150 | 362 | 0 | 1.35 | 3.56 | 64% |
| 100,000 | this, SQL + 50 ms window | 25,996 | 57.3 | 230 | 486 | 0 | 1.08 | 1.70 | 38% |
| 150,000 | parent | 38,917 | 33.9 | 351 | 711 | 0 | 1.95 | 4.20 | 80% |
| 150,000 | this (SQL + window, 4 workers) | 39,218 | 27.9 | 202 | 464 | 0 | 2.12 | 3.63 | 75% |
| 200,000 | parent | 51,258 | 86.5 | 401 | 711 | 0 | 2.42 | 3.66 | 81% |
| 200,000 | this (shipped defaults) | 51,630 | 67.7 | 319 | 573 | 0.01% | 2.50 | 3.13 | 74% |

Five-minute holds (60 s ramp + 300 s measured, the official hold length), same rig, same day:

| users | build | req/s | p50 (ms) | p95 (ms) | p99 (ms) | errors | app CPU (cores) | Postgres CPU (cores) | box busy | verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| 180,000 | parent | 46,533 | 27.3 | 381 | 1,053 | 0.02% | 2.11 | 4.26 | 83% | fails (p99) |
| 180,000 | this | 46,906 | 42.8 | 175 | 450 | 0 | 2.14 | 2.84 | 65% | passes |
| 200,000 | parent | 41,432 | 239 | 2,562 | 7,414 | 4.05% | 2.20 | 4.14 | 90% | fails |
| 200,000 | this | 49,510 | 81.8 | 496 | 852 | 0.37% | 2.56 | 3.80 | 85% | fails (p95 by 0, p99) |

The holds on this rented rig are noisier than the 150 s runs: the host underneath the VMs is shared, and in the
later holds identical statements with identical batch sizes ran 2-3x slower in Postgres while the kernel logged
the hypervisor's free-page reporting hogging CPUs; repeats of the same configuration swung between passing and
failing for both builds. The table keeps the paired runs that were taken minutes apart under the same conditions.

Derived from the rows above, Postgres CPU per request at 100,000 users: parent 168 µs, SQL only 136 µs, SQL
plus window 65 µs; at 200,000 users this build 58 µs. The window takes latency in return (p50 57 ms against 18 at
100,000 users), which is the trade this entry makes: the limits are p95 under 500 ms and p99 under 1 s, and the
box's CPU is what runs out first.

Two caveats. The parent fails at 150,000 users on this rig when the load comes from a single 8-vCPU VM (p95
3.4 s) and passes with two load VMs; only the two-VM numbers are reported, for both builds. And this host's cores
are faster than the official box's: the parent holds 150,000 users here against 130,000 officially, so the
absolute numbers do not transfer; the relative CPU per request should.

## Limitations

- Latency is traded for CPU. With the 50 ms window the p50 at 200,000 users is about 60-70 ms, where the parent's
  was 16-18 ms on its box. The window only pays while the box is CPU-bound; on a box with CPU to spare,
  `READ_BATCH_US=0` gives the parent's latency with the cheaper SQL.
- The official harness stops at 200,000 users (`box/challenge.service` sets `LimitNOFILE=200000`), so a build that
  passes there has no further score to gain; what is left to compare is the margin under the limits.
- Batches share work only inside one statement, during the requests they serve. Nothing survives a batch: no row,
  plan result or flag is kept across requests (rule 5), and each execution takes one `READ COMMITTED` snapshot as
  in the parent.
- Two things we built and then turned off: the per-response `TCP_QUICKACK` (above), and a first version of the
  window that checked only the single oldest family and deferred every take when that one was young (it turned
  dispatch into a 50 ms duty cycle under load; the shipped scheduler takes the oldest *ready* family).

## Credits

- The server is nickita-khylkouski's `asm-epoll-nickita-khylkouski` (#82, MIT; `LICENSE` kept). Its own credits
  chain, repeated here because this entry inherits all of it: the read batching, group commit, adaptive gzip and
  bcrypt batching/shedding are ports of nickita's Rust entry, which builds on Scooter1337's rust-tokio (#7) and
  cknutson12's rust-hyper (#1), both MIT; the per-family read queue comes from jh-d's #22 (its batch cap from #52),
  the shared list/article SQL from tbsvttr's #32, and the feed's cap for authors with 1000+ articles from #61.
  bcrypt follows OpenBSD/Openwall crypt_blowfish; `gzip.s` follows libdeflate (MIT) and Chromium zlib's CRC32
  (BSD-3-Clause), notices in `src/gzip.s`.
- nick-potts (#79, #117): the evidence that a collection window and the drain gap between batches are where the
  Postgres CPU goes (and the `TCP_QUICKACK` idea, which did not survive our holds).
- Scooter1337 (#102): the feed cutoff from the most-shared followees.
- y2kbugger (#53), WorriedArrow (#47), Bparsons0904 (#95): per-viewer `= ANY` flag probes and the measurements
  showing that two-phase sharing beats grouped CTEs joined back to the requests.

## Layout

```
src/
  main.s    entry, env, thread spawn             http.s    HTTP/1.1 parser, percent-decode, head writer
  rt.s      allocator, threads, memcpy, time     json.s    JSON reader + writer
  cpu.s     CPU feature detection                server.s  epoll loop, connections, send path, QUICKACK
  crypto.s  SHA-256, HMAC, base64url, JWT        pgio.s    Postgres op queue, DataRow scan
  bcrypt.s  bcrypt hash/verify                   api.s     routing + the endpoints
  pg.s      Postgres protocol                    render.s  JSON response bodies
  bcq.s     bcrypt work queue, lane filling      sql.s     prepared statement text
  writer.s  group commit                         readb.s   read batching (queues, windows, batched SQL, demux)
  readr.s   packed-row renderers                 gzip.s    deflate + gzip framing
  egress.s  adaptive gzip controller
  defs.inc  cross-module constants               app.inc   app struct layouts + macros
```

Changed against the parent: `src/readb.s` (windows, timer, the four `qb_*` statements), `src/bcq.s`,
`src/main.s` (new env vars), `src/server.s` (timer dispatch, `TCP_QUICKACK`), `src/rt.s` (`rt_mono_us`),
`src/app.inc`, `src/defs.inc`, `start.sh`. `build.sh`, `install.sh` and the other modules are the parent's.

## Validation

The repo's 197 conformance checks pass on the full seed with the shipped defaults (`READ_BATCH_US=50000`,
`READ_BATCH_MAX=256`, four workers) and with `READ_BATCH_US=0`. The four rewritten statements return the same
rows as the parent's: `EXCEPT ALL` in both directions is empty at N = 1 / 32 / 256 on two seeds. The parent's
per-module tests (SHA-256/HMAC/JWT against Python's hashlib, bcrypt against the Rust `bcrypt` crate, gzip against
zlib) cover code this fork did not touch; they are not part of this folder.
