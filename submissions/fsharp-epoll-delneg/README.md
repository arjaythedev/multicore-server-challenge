# F# on epoll, with batched Postgres reads (delneg)

Front: direct

| | |
|---|---|
| Language | F# 11 on .NET 11 RC3 (official SDK tarball, SHA-512 checked in `install.sh`), ReadyToRun, tiered PGO |
| HTTP | our own HTTP/1.1 server on epoll (P/Invoke to libc), no ASP.NET; io_uring as an option (`IO_MODE=uring`) |
| Postgres driver | our own v3 wire client: SCRAM-SHA-256, binary parameters and rows, named prepared statements, pipelining |
| bcrypt | our own multi-lane EksBlowfish in C (`native/bcrypt.c`), compiled by `build.sh` with gcc |
| JWT | HS256 with .NET's HMAC-SHA256 (one reusable context per thread); signature, `alg` and `exp` checked on every request |
| Dependencies | FSharp.Core only, pinned in `src/packages.lock.json` |

```sh
sudo bash install.sh && bash build.sh
DATABASE_URL=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

No caches across requests, no schema or Postgres configuration changes, nothing tuned outside the process.

## How a request flows

```
 4 I/O threads (epoll, SO_REUSEPORT)      read lane, 5-150 ms clock      5 connections: rd + tags,
 parse in place, JWT, route  ─────────►   lists, tags               ───► one pipelined round trip per batch
                             ─────────►   side lane, same clock     ───► 3 connections: rd, comments, profiles,
                                          articles, comments,            users, logins
                                          profiles, users, logins
                         ◄── per-thread reply inbox, one eventfd write per batch of replies ◄──
                             ─────────►   write lane, 5 ms clock    ───► 4 connections: one implicit
                                                                          transaction per batch, answered
                                                                          only after it commits
                                          bcrypt: 2 threads, 6 lanes
```

- **I/O.** Each I/O thread has its own epoll set and listener, and uses `recv`/`send`, which skip the VFS layer that
  `read`/`write` go through. A request that arrives in one read is parsed straight from the read buffer. The handler either answers at once (validation, auth errors) or queues a job. Replies come
  back through the thread's inbox, and the thread is woken once per batch of replies, not once per reply.
- **One fd table per I/O thread.** `RLIMIT_NOFILE` is counted per fd table, and each I/O thread calls
  `unshare(CLONE_FILES)` at startup to get its own, as each worker of a multi-process server has. With the box's limit
  of 200,000 the four threads hold ~800,000 connections. A server with one table has to close idle connections above
  200,000 users, and those users dial again on their next request. The kernel also skips the table's shared-state work
  for a table with one user, and connection fds can't starve the runtime of the fds it needs, for example to load an
  assembly. Near a thread's own limit, its connection that has been idle longest is closed (`FD_TABLES=shared` turns
  all of this off).
- **Lanes.** All I/O threads feed the same three queues. One idle connection thread per lane at a time sleeps out
  the clock (`usleep`) and then takes everything queued; the others block. We started with a timed `Monitor.Wait`,
  which spins before it blocks: on the write threads that spinning took more CPU than the writes. Reads are split in
  two lanes so that the comments statement runs in a second backend while `rd` runs, not after it. Single-article
  reads go with comments, in the side lane.
- **The read clock follows the load:** 3 µs of clock per job/s across both read lanes, from 5 ms up to 150 ms
  (reached at about 200,000 users). Part of a batch's cost doesn't depend on its size. Deep links are skewed to a few
  articles, whose favorites keep growing through a run (18,455 on the top one after a 50-minute search on our box) and
  which every batch counts again. On an aged database like that at 180,000 users, a fixed 100 ms clock used 14% less
  CPU than a fixed 20 ms one, for ~80 ms more p95. Nothing is carried over between batches; the batches just get bigger.
- **Overload.** Nothing is answered 503. A connection has one request in flight at a time (the next waits unparsed
  until it is answered), so the queues can't outgrow the open connections. A read whose client has disconnected
  (a load generator gives up after 10 s) is dropped from its batch, since nobody is left to answer it; writes always
  run. At the fd limit with no idle connection to close, a spare descriptor is given up to accept and close the
  newcomer, so the listener can't keep the loop spinning. An error on one connection closes that connection only, and
  a Postgres connection that fails is replaced, retrying until Postgres takes it.
- **One statement for list and article reads.** Every global, tag, author, favorited and feed list and every
  single-article read in a batch is one execution of one prepared statement (`rd` in `src/Sql.fs`), with the
  requests passed as arrays. Requests for pages near the top of the same list share one fetch, an article that many
  requests need is read once, and the authors, favorite counts and tags of the batch's articles come from three
  lookups in id order. The tag list is read in the same round trip, and its ids put the tag names on the articles.
- **Feeds.** Followees that several feed viewers in the batch share are probed once. One with 1,000 or more articles
  proves the capped count for all its followers. Its n-th newest article bounds every other followee scan for those
  followers (n is the batch's deepest feed page). Both shortcuts are exact.
- **Comments.** One statement per batch for every thread requested. Each comment author is read once, and each
  viewer's followees come from one grouped scan of `follows` over the batch's sorted viewers.
- **Writes.** A batch's favorites, follows and comment changes go in one implicit transaction (one Sync), one request
  per user and kind per batch; the rest wait for the next batch. After the commit, comments are answered from their
  `RETURNING` rows, and favorites and follows go to the read lane to be answered with the article or profile.
  Sign-ups, settings and article changes each get their own transaction.
- **I/O: epoll or io_uring.** `IO_MODE=uring` runs each I/O thread on its own ring (`native/uring.c`, raw syscalls,
  no liburing): one multishot accept, one multishot recv per connection into a pool of provided buffers, sends from
  the pinned reply, an eventfd read for replies posted from other threads, and one `io_uring_enter` per loop turn that
  submits and waits. The parsing, dispatch and connection state are the same code as with epoll. Epoll is the default.
  At 80,000 users io_uring was no cheaper (about 0.8 µs per request worse across both test lanes, inside the noise), and
  in one 5-minute hold each at 220,000 users it cost the same (109.6 vs 110.0 µs per request) with a lower p95 (118 vs
  127 ms). That's too small to outweigh what isn't tested: io_uring has run on the scorer's kernel only under QEMU with an
  echo loop, never under load, and it holds ~80 MB more.
- **Kernel 6.8.** Some of Ubuntu 24.04's 6.8.0 builds have the check on a buffer ring's reserved bytes inverted, so a
  correct registration fails with EINVAL. #60 exited at startup on the scorer because of it and traced it on
  `6.8.0-149-generic`. On EINVAL the ring is registered again with `resv[0] = 1`; if that fails too, the buffers are handed
  over with `IORING_OP_PROVIDE_BUFFERS` instead, which every 6.8 build has (`URING_BUFS=classic` forces this path, so
  it can be tested on a kernel without the bug). Setup flags are tried from SINGLE_ISSUER + DEFER_TASKRUN down,
  multishot accept and recv fall back to one-shot when refused, and a thread whose ring can't be opened at all
  (a container that blocks io_uring, say) runs epoll. Nothing newer than 6.8 is used. `experiments/kernel68` boots
  Ubuntu kernel packages in QEMU and runs `native/uring.c` under an echo loop: `6.8.0-1069-aws` and `6.8.0-1064-aws` need
  the `resv[0]` retry, `6.8.0-71-generic` doesn't, and all three pass on both buffer paths.
- **bcrypt.** Six hashes run in lockstep with their rounds interleaved, so a pass of 6 costs little more than a pass
  of 1: 41 ms for a single hash, 10.6 ms per hash with 6 lanes (cost 10, one CPU whose SMT sibling is busy). Logins
  are about 0.1% of requests, so a login waits up to 250 ms for the lanes to fill. The lane state lives on the stack:
  as a `__thread` array in the shared object it went through `__tls_get_addr` inside the rounds, a fifth of the time.
- **Scheduling.** Our threads run under SCHED_BATCH, so waking one doesn't preempt a Postgres backend mid-query.
  The bcrypt threads also run at nice 5.

## Measured (our box, not the official one)

All numbers are from our own test box: AMD Ryzen 9 7900X3D under WSL2, with Postgres 18 and the server sharing CPUs
0-7, the real `bench/cmd/loadgen` on other CPUs, the full seed, and the scorer's search (3-minute warm-up, doubling
2-minute probes, a 5-minute hold). The harness is `experiments/h.sh`, and every experiment is in
`experiments/worklog.md`.

The last check on this code, solo, on a copy of a database aged by earlier searches (1,013,541 articles against the
seed's 500,000), so it starts where a long search ends. It's a 5-minute hold at 220,000 users after the warm-up, with no
search before it:

| | p95 | p99 | errors |
|---|---|---|---|
| all requests (54,825 req/s) | 317 ms | 353 ms | 0% |
| logins (17,727) | 485 ms | 547 ms | 0% |
| sign-ups (370) | 277 ms | 338 ms | 0% |

CPU was 132.2 µs per request (server 49.4, Postgres 82.8), the server used 2.71 cores and Postgres 4.54, and the server
peaked at 1,205 MB. The load generator was never behind.

On a fresh seed, one 5-minute hold at 220,000 users on the build before the load-following clock: p95 127 ms, p99 159 ms,
110.0 µs per request (48.2 + 61.8), logins p95 244 ms, sign-ups p95 225 ms, no errors, exactly 220,000 connections.

The last full search ran on the next build, also before that clock, at a fixed 20 ms: probes passed at 200,000 and 250,000 and
failed at 260,000, 280,000, 300,000 and 400,000 (no crash at 400,000, 0.1% errors). Holds failed at 250,000, 240,000 and
230,000 (p95 850 ms at 230,000) and passed at 220,000 (p95 423 ms, p99 535 ms, 142.1 µs per request) on the same
process. This code hasn't had a full search or an overload probe. Our box isn't the scorer's, and WSL2 runs a 6.18
kernel, so these numbers are for comparing our own builds.

## Knobs

All optional. `IO_MODE` (`epoll`, or `uring`), `URING_BUFS` (`ring`, or
`classic`), `FD_TABLES` (`own`, or `shared`), `READ_CLOCK_US` (0 follows the load; anything else fixes the clock),
`READ_CLOCK_MIN_US` (5000), `READ_CLOCK_MAX_US` (150000), `READ_CLOCK_PER_RATE` (3), `READ_MAX` (2000), `WRITE_CLOCK_US`
(5000), `WRITE_MAX` (256), `ARTICLE_LANE` (`side`, or `read`), `HUBS` (16), `HUB_COUNT` (1), `FEED_BOUND` (1), `THREAD_SCHED`
(`batch`), and `PG_OPTIONS` (session settings for our connections: generic plans, no JIT, no parallel workers). For
debugging: `MC_STATS`, `RD_DUMP`, `SQL_DUMP`.

## Credits

Ideas from other entries, in our own code:

- Batching reads from every connection into one round trip on a clock: #22's batching policy, #47's gather and #79's
  clock.
- One statement for all list and article reads in a batch: #168.
- Feed counts proved by a followee with 1,000+ articles: #61 and #100. The shared-followee bound on feed pages: #102
  and #105.
- One tags read answering every tags request in a batch: #48.
- SCHED_BATCH for the server's threads: #168, measured by #130.
- Reading each comment author once per execution: #152.
- One fd table per I/O thread with `unshare(CLONE_FILES)`: already in rust-epoll-theCatWisel, rust-epoll-WorriedArrow
  and c-epoll-unorig-username. We found it after hitting the fd limit, then saw they had it first.
- A read clock that changes with the load: nish-std-amritk and zig-iouring-harshitkhandelwal208 have their own forms.
  Ours is a plain rate times a constant.
- io_uring on the scorer's 6.8 kernel: registering a buffer ring again with a non-zero reserved byte when it fails
  with EINVAL (#60), and classic `IORING_OP_PROVIDE_BUFFERS` where buffer rings fail (#168).

Ours: the lane leader without timed waits, write answers through the read lane, the id-ordered lookups for article
details, one followee read per feed viewer for everything a feed needs, dropping the reads of clients that have
left, the epoll and io_uring server, the Postgres client, and the bcrypt core,
whose init words are generated from pi by `native/gen_pi.py`.
