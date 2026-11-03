# F# on epoll, with batched Postgres reads (delneg)

Front: direct

| | |
|---|---|
| Language | F# 11 on .NET 11 RC3 (official SDK tarball, SHA-512 checked in `install.sh`), ReadyToRun, tiered PGO |
| HTTP | our own HTTP/1.1 server on epoll (P/Invoke to libc), no ASP.NET |
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
 4 I/O threads (epoll, SO_REUSEPORT)      read lane, 20 ms clock         5 connections: rd + tags,
 parse in place, JWT, route  ─────────►   lists, articles, tags     ───► one pipelined round trip per batch
                             ─────────►   side lane, 20 ms clock    ───► 3 connections: comments, profiles,
                                          comments, profiles, users      users, logins
                         ◄── per-thread reply inbox, one eventfd write per batch of replies ◄──
                             ─────────►   write lane, 5 ms clock    ───► 4 connections: one implicit
                                                                          transaction per batch, answered
                                                                          only after it commits
                                          bcrypt: 2 threads, 6 lanes
```

- **I/O.** Each I/O thread has its own epoll set and listener, and uses `recv`/`send`, which skip the VFS layer that
  `read`/`write` go through. A request that arrives in one read is parsed straight from the read buffer. The handler either answers at once (validation, auth errors) or queues a job. Replies come
  back through the thread's inbox, and the thread is woken once per batch of replies, not once per reply. Near the
  fd limit, the connection that has been idle longest is closed.
- **Lanes.** All I/O threads feed the same three queues. One idle connection thread per lane at a time sleeps out
  the clock (`usleep`) and then takes everything queued; the others block. We started with a timed `Monitor.Wait`,
  which spins before it blocks: on the write threads that spinning took more CPU than the writes. Reads are split in
  two lanes so that the comments statement runs in a second backend while `rd` runs, not after it.
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
- **Comments.** One statement per batch for every thread requested. Each comment author is read once, and the
  `following` flags look only at the follows from each viewer to the authors in the threads that viewer asked for.
- **Writes.** A batch's favorites, follows and comment changes go in one implicit transaction (one Sync), one request
  per user and kind per batch; the rest wait for the next batch. After the commit, comments are answered from their
  `RETURNING` rows, and favorites and follows go to the read lane to be answered with the article or profile.
  Sign-ups, settings and article changes each get their own transaction.
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

(results to come)

## Credits

Ideas from other entries, in our own code:

- Batching reads from every connection into one round trip on a clock: #22's batching policy, #47's gather and #79's
  clock.
- One statement for all list and article reads in a batch, and comment threads whose follows lookup is scoped to
  their authors: #168.
- Feed counts proved by a followee with 1,000+ articles: #61 and #100. The shared-followee bound on feed pages: #102
  and #105.
- One tags read answering every tags request in a batch: #48.
- SCHED_BATCH for the server's threads: #168, measured by #130.
- Reading each comment author once per execution: #152.
- io_uring on the scorer's 6.8 kernel: registering a buffer ring again with a non-zero reserved byte when it fails
  with EINVAL (#60), and classic `IORING_OP_PROVIDE_BUFFERS` where buffer rings fail (#168).

Ours: the lane leader without timed waits, write answers through the read lane, the id-ordered lookups for article
details, one followee read per feed viewer for everything a feed needs, dropping the reads of clients that have
left, the epoll and io_uring server, the Postgres client, and the bcrypt core, whose init words are generated from pi
by `native/gen_pi.py`.
