# Worklog: fsharp-epoll-delneg

Harness (our box, NOT official): wsl26, 24 CPUs (AMD, WSL2 kernel 6.18), Postgres 18 cluster pinned to CPUs 0-7,
server as user `challenge` in a systemd unit with `LimitNOFILE=200000` on CPUs 0-7, the real `bench/cmd/loadgen`
on other CPUs at real think time, full seed (fresh copy per search), box sysctls. Search like the scorer: 3-minute
warm-up at 500 users, 2-minute probes doubling from 25k then bisecting to 5%, 5-minute hold stepping down 5%.
Script: `experiments/h.sh`.

## Experiments

- **e01 #87 (`9de3218`) on the harness** (reference): probes 25k, 50k, 100k, 150k, 180k pass at 100-111 µs/req
  (app 45, PG 55-65); 190k and 200k flagged LG-limited (the load generator processes shared one CPU set and fell
  behind; fixed in the harness afterwards).
- **e02 new design, first build**: the warm-up showed PG at 4.4 ms/req. `currval()` is volatile, so in a `WHERE` it
  made the article lookup after each insert a sequential scan of 500k rows (POST /api/articles p50 916 ms). Fixed
  with a scalar subquery (`WHERE a.id = (SELECT currval(...))`).
- **EXPLAIN of the read statement** on a synthetic batch (1 global, 25 tag, 40 author, 8 favorited, 80 feed groups,
  200 direct reads): 26.4 ms. Groups 13.2 ms (feeds most of it; each tag count walks 1,000 index entries,
  0.125 ms); article rows with author, favorite count and tag ids about 10 ms for 1,388 distinct articles; viewer
  flags 2 ms. The followee probe left 20 of 80 feeds needing a count walk.
- **e04 tag/global count probe**: `EXISTS (... OFFSET 999)` proves the capped 1,000 without aggregating; 200 tag
  counts 15.3 ms -> 10.1 ms on the side cluster (every seeded tag has 1,000+ articles).
- **Note on low load**: at 25k users app CPU per request is high (97 µs) partly because bcrypt rarely fills its
  lanes (36 ms per single-lane hash vs ~10 ms per hash at 5-6 lanes).
- **e04 profile, 50k and 150k users** (cpu mode, perf on the app, pg_stat_statements on the cluster):
  - 50k: 141 µs/req (app 82, PG 59); 150k: 130 µs/req (app 65.5, PG 64.4). #87 at 150k: 110 (app 45.6, PG 64.4).
    So the first build is no better than #87.
  - App: bcrypt threads 38-40% of app CPU (logins rarely filled the lanes: 41 logins/s at 150k came out at about
    25 ms per hash). I/O threads 21-36%, mostly kernel TCP. Write threads 18% at 50k, nearly all of it in
    `System.Threading.Condition::Wait`: the timed `Monitor.Wait` of the 5 ms write clock spins before it
    blocks, and the four write threads did that for every tiny batch.
  - Postgres, 50 s at 50k: `rd` 26.0 s in 8,962 calls, comments 6.7 s in 2,198 calls, comment insert 0.7 s,
    favorite insert 0.6 s, tags 0.4 s, profiles 0.3 s. Only ~2,200 of the `rd` calls were read batches; the rest
    came from write batches answering their favorites (0.2-0.3 ms each for one article). A read batch's `rd`
    averaged ~10 ms for ~135 list and article requests: about 75 µs each.
- **e05**: bcrypt waits up to 250 ms for 6 lanes (logins are ~0.1% of requests; 6 lanes cost 11 ms per hash).
- **e06**: lanes without timed waits: one idle thread is the leader and sleeps out the clock (`Thread.Sleep`),
  the others block untimed.
- **e07**: write batches no longer read their answers in the transaction: after commit, favorites and follows go
  to the read lane (as an article or profile read), where they share the batch's `rd`.
- **e05-e07 at 50k/150k** (same sequence: 3-minute warm-up, 50k, 150k): e05 125.3/119.8 µs/req, e07 120.5/116.4
  (150k: app 55.5, PG 60.9). A 150k run on a fresh database (no warm-up, no 50k phase) cost 106.6 (PG 53.4):
  the database's age moves PG by ~7 µs/req, so builds are compared only in identical sequences.
- **e07 profile at 50k**: the write threads still spun, now in the kernel (`sched_yield`): `Thread.Sleep(TimeSpan)`
  rounds down to whole milliseconds, so the last fraction of each 5 ms clock was `Sleep(0)`. Fixed with `usleep`.
- **Real batches** (RD_DUMP at 150k, replayed on the side cluster): ~400 list and article requests, 475 distinct
  viewers, 1,037 distinct articles, 111 feed groups, 218 direct reads; 24k buffer accesses per execution: feeds ~10k
  (1,791 followee probes, 5.9k), article rows ~11.5k, viewer flags 2.9k. `EXPLAIN ANALYZE` with timing is ~7x
  slower than plain execution on WSL (clock reads), so its per-node times are not usable; buffers are.
  pg_stat_statements over 30 s at 150k: `rd` 42.3 s (28.8 ms per call), comments 12.4 s (11.7 ms, 4,340 rows per
  call: hot articles collect comments during the run), all writes ~3.3 s.
- **Dropped: one probe per distinct followee.** Distinct followees are 75-80% of (viewer, followee) pairs in real
  batches (1,339 of 1,791), so sharing them would save ~5% of the buffers at best, before the wider bounds.
- **e08** (SCHED_BATCH + usleep clock), same sequence as e05-e07: 50k 107.8 µs/req (app 50.1, PG 57.7), 150k 110.0
  (app 50.5, PG 59.5). Idle app CPU at the 500-user warm-up fell from 0.06 to 0.02 cores. At 150k bcrypt is still
  0.71 cores (17 ms per hash under load: CPUs 0-7 are 4 cores x 2 threads), the I/O threads' kernel time ~21 µs/req.
- **e09: article details as id-ordered set lookups** (one `= ANY(sorted ids)` scan each for authors, favorite counts
  and tags instead of three correlated subplans per article). Same rows on all 40 real batches; buffers per batch
  24,067 -> 17,624, but plain execution time unchanged (21.9 -> 21.2 ms per batch). Buffer hits are not what costs
  here: an ablation of the real batches puts feeds at ~8 ms, viewer flags ~4 ms and the article rows ~5 ms of
  ~21 ms, and the flags cost ~3 µs per subplan call (two short index scans per viewer). Kept (no slower, fewer
  buffers), with the follows flag now the viewer's whole followee list, checked in the app.
- **e01b #87 search** (fixed harness): 25k 116.3, 50k 101.7 (app 50.1, PG 51.6), 100k 100.6, 150k 105.8 (app
  43.8, PG 61.9); the 200k probe was flagged LG-limited: loadgen processes with 40k users on ~2.4 CPUs each stalled
  ("sampler tick 8185 ms late", timer lag > 50 ms). The search was stopped: above ~190k this harness measured the
  loadgen. Searches now run the loadgen on CPUs 8-22 with 25k users per process (`PER`, `LGLAST`).
- **e10: two read lanes.** Comments, profiles, users and logins have their own lane and connections (3), so their
  statements run in parallel with `rd` (5 connections) instead of after it in the same backend.
- **#87 profile run** (same sequence as e08: warm-up, 50k, 150k): 50k 101.9 µs/req (app 51.0, PG 51.0), 150k 99.3
  (app 44.6, PG 54.8). e08 in the same sequence: 107.8 and 110.0. So at this point the new design is ~10% more
  expensive per request than #87: PG +5 µs at 150k, app +6 µs (I/O threads 0.91 vs 0.78 cores, bcrypt 0.72 vs
  0.63, libcrypto 2.6x #87's share).
- **e11: feed bounds per page depth.** The bound came from the batch's deepest feed page (usually 50), so page-1 feeds
  scanned back to a hub's 50th newest article instead of its 10th. Now one bound per (hub, depth). Same rows on the
  real batches, 21.6 -> 20.9 ms per batch.
- **Generic vs custom plans** for `rd` on the real batches: 26.5 vs 27.5 ms (planning included): generic stays.
  Not materializing the single-use CTEs (fc, tg, au and more): 30 ms, much worse.
- **e12: bounded feeds from one index scan** (`author_id = ANY(followees) AND id >= bound`, then sort the few rows)
  instead of a subplan per followee; 86 of 111 feeds in a real batch take it. Same rows; time within noise
  (maybe -2%).
- **e13: one HMAC context per thread** (`IncrementalHash`) for JWT checks instead of `HMACSHA256.HashData`, which
  sets up a new OpenSSL context per call.
- **e14: `recv`/`send` on client sockets** instead of `read`/`write` (which go through the VFS layer first), with
  `MSG_NOSIGNAL`.
- **e10 search** (100k start, 25k users per loadgen process): 100k 101.8 µs/req (app 49.4, PG 52.4; p50 29.5 ms vs
  #87's 37), 200k pass at 113.6 (app 53.3, PG 60.3, p95 102 ms). The 400k probe overloaded the box as intended,
  and in the 300k probe after it the server died: "Out of memory." then SIGABRT, 1.3 GB peak, no kernel OOM, 27 GB
  free. A crashed server isn't restarted by the scorer, so this matters more than speed.
- **e15: overload defenses.** Each epoll event and each inbox delivery has its own try/with (an error closes that
  connection only); a spare fd is given up at EMFILE to accept and close the newcomer; past 150,000 queued jobs a
  lane answers 503; unhandled exceptions are logged.
- **e16: connection threads reconnect with retries.** A failed batch reconnected once and let a second failure
  (Postgres full, fd table full) escape the thread, which kills the process.
- **e01c #87 search** (solo, 100k start): 100k 99.2 µs/req (app 47.9, PG 51.3, p95 60 ms), 200k pass 107.9 (app
  49.2, PG 58.7, p95 174 ms), 400k fail (14.8% errors), 300k fail (6.8%), 250k fail (1.97%, p95 635 ms), 220k pass,
  230k pass (p95 415 ms); **hold 230k pass: p95 474 ms, p99 569 ms, 0.07% errors. Score 230,000** on this harness.
  At 220k its logins: p95 276 ms, p99 325 ms, no errors.
- **e17: each feed viewer's follows read once.** A feed viewer's follows were scanned in the hub candidates, once
  per hub bound, in the page scan, in the count probe and again for the `following` flags: five scans and up to 16
  probes. Now one `fl` row per distinct feed viewer holds the followee array and the rest use it (`&&` against
  the hubs, `= ANY` for the page and the count). Same rows on the 40 real batches; buffers per batch 16,208 ->
  12,069 (-26%). On a copy with 10% of `follows` deleted and re-inserted without vacuum (pages no longer
  all-visible, like a long run): 19,387 -> 14,095. Execution time is within noise while a search runs on the box.
- **Harness: two lanes.** Lane A: app + PG `main` (:5432) on CPUs 0-7, loadgen 8-11, app :80. Lane B: app + PG
  `laneb` (:5434, same config, seeded from `conduit_seed`) on CPUs 12-19, loadgen 20-23, app :8081. Lane runs
  compare CPU per request at a fixed load below capacity, within one lane only (the lanes are on different CCDs of
  the 7900X3D). Probes near capacity and holds run solo. Every phase now also reports login and sign-up p95/p99/errors
  and every route with a non-2xx status or an error class (`routes.py`). The Postgres and app ports are reserved
  from the ephemeral range (with 1024-65535, loadgen sockets took :5434 on 127.0.0.1).
- **e18: no 503s.** The backlog cap (503 past 150,000 queued jobs) is gone: a connection has at most one request in
  flight, so the queues can't outgrow the open connections, and a 503 would spend the 1% error budget. Instead
  reads whose client has disconnected (the load generator gives up after 10 s) are dropped from their batch; under
  overload that is the work that piles up. Writes always run. Also: dispatch waits for a reply to be fully sent
  before parsing a pipelined request (with epoll a partial send could have let a later reply go first).
- **e19: io_uring loops** (`IO_MODE=uring`, `native/uring.c` on raw syscalls). Per I/O thread: a multishot accept, a
  multishot recv per connection into 8,192 provided 2 KB buffers, sends from the pinned reply, an eventfd read for
  replies from other threads, and one `io_uring_enter` that submits and waits. Setup flags are tried from
  SINGLE_ISSUER + DEFER_TASKRUN down. The buffers are a buffer ring, registered again with `resv[0] = 1` on EINVAL
  (Ubuntu 6.8.0-1xx builds have that check inverted, which killed #60 at startup on the scorer), or, if that fails or
  `URING_BUFS=classic`, handed over with `IORING_OP_PROVIDE_BUFFERS` (the path #168 uses on the scorer). Multishot
  accept and recv fall back to one-shot on EINVAL, and a loop whose ring can't be opened runs epoll. wsl26 runs 6.18,
  which doesn't have the bug, so the classic path is tested by forcing it: 197/197 with epoll, uring and uring +
  classic.
- **e18 profile** (solo, warm-up, 50k, 150k; same sequence as e08 and the #87 profile): 50k 109.4 µs/req (app 50.2,
  PG 59.3), 150k 107.9 (app 49.3, PG 58.7). #87 in that sequence: 101.9 and 99.3 (app 44.6, PG 54.8 at 150k). So
  this is still ~9% more per request than #87 on both sides. PG at 150k by connection: read 1.61 cores, side
  0.49, write 0.18. App: bcrypt threads 39% of the app's CPU (0.76 cores for 38.6 logins/s = 19.7 ms per hash;
  #87: 0.63 cores), I/O threads 45% (kernel 33 points of it, mostly TCP; on loopback that includes the load
  generator's receive path). Logins at 150k: p95 305 ms, p99 358 ms, no errors.
- **e20: bcrypt state on the stack.** 3.8% of the bcrypt threads' samples were in `__tls_get_addr`: the lane state
  was a `__thread` array, which in a shared object is reached through that call, and gcc called it again inside the
  interleaved rounds. (The microbenchmark linked the C file into an executable, where TLS is a plain `%fs` offset, so
  it never showed.) Through the .so, as the server loads it: 6 lanes 13.16 -> 10.56 ms per hash, 5 lanes 13.9 ->
  11.6 (CPU 23, sibling busy). Same hashes on the known-answer vectors.
- **e19 io_uring vs epoll, lanes A and B at once, 80k users, 60 s windows** (app µs/req; PG ~59-61 in all):

  | run | lane A | lane B |
  |---|---|---|
  | 1 | epoll 50.4 | uring 50.3 |
  | 2 | uring 54.2 | epoll 52.8 |
  | 3 | epoll 52.3 | uring 52.8 |
  | 4 | classic 51.9 | classic 52.2 |

  Within a lane: A epoll 51.4 vs uring 54.2, B uring 51.6 vs epoll 52.8, so no difference beyond the ±2 µs noise.
  Same p50/p95 (27-28 / 44-45 ms), no errors on any route in any mode, logins p95 ~345 ms. io_uring holds ~80 MB
  more (the buffer pools). Where the time goes explains it: on the I/O threads the kernel's TCP work is ~3/4 of the
  CPU and io_uring doesn't change it; it removes the epoll and syscall-entry part (a few percent of the I/O threads),
  and adds completion handling, pinning each reply and copying out of the provided buffers.
- **Closing io_uring connections without a cancel scan** (an idea Denis passed on from a PR #211, which isn't in the
  upstream repo, so not read): cancelling by fd (`IORING_ASYNC_CANCEL_FD`) makes the kernel search the pending ops,
  cancelling by user_data is a direct lookup. We already submit no cancel at all: close is `shutdown(SHUT_RDWR)`,
  which wakes the connection's one pending recv through the socket's own wait queue (it completes with 0, and a
  completion for a closed connection is ignored and hands its buffer back), then `close`. No fixed files, so
  nothing needs cancelling before a close either.
- **e19 decision: epoll stays the default.** Run 5 completed the set (lane A uring 54.1, lane B epoll 52.8): across
  both lanes io_uring is ~0.8 µs/req worse on average, inside the noise and of no use. `IO_MODE=uring` stays as an
  option, with its 6.8 fallbacks.
- **e21: follows lists in one index scan, body flag by hash.** Feed viewers' followees (`fl`) and the other viewers'
  (`fw`) are each one grouped scan of `follows` over the sorted viewer ids instead of one subplan per viewer, and
  the direct-read body check is `IN (subquery)` (a hashed subplan) instead of `= ANY(ARRAY(...))`, which scanned
  the array for every article. On the 40 real batches: identical rows except 10 `t=4` rows with an empty array
  (viewers who follow no one; the server already treats a missing row as no follows). Execution 20.6 -> 20.0 ms per
  batch (seed), 22.7 -> 22.2 (aged follows), in both orders; buffers unchanged.
- **Box rebooted (night of 3-4 Nov)**: the e20-vs-#87 lane run died after its first pair; CPU pins (runtime
  properties) were lost, so `h.sh` now enforces them on every run. First pair at 80k, different lanes, so only a hint:
  #87 lane A 103.2 µs/req (app 49.9, PG 53.2), e20 lane B 104.5 (app 46.5, PG 57.9). The statements over 60 s:
  comments 14.7 s (ours, 6.6 ms x 2,238) vs 11.2 s (#87, 5.7 ms x 1,951); `rd` 48.0 s vs ~45 s for #87's set of list,
  article and flag statements; buffers 39M vs ~55M, so again PG CPU doesn't follow buffers.
- **Dropped: one scan for all direct-read slugs** (instead of one lookup per read). Same rows on the real batches,
  no change in time (19.7 vs ~20.1 ms per batch, wall 2.77 vs 2.78 s).
- **Lane runs side by side cost more than one lane alone**: e21 in lane A with lane B idle: 92.3 µs/req at 80k (app 40.9,
  PG 51.4), against 104-115 with both lanes busy (those are e19/e20, so not a clean comparison, but the jump is too big
  to be the code). Lane results compare only with runs made under the same conditions. First RD_DUMP with comments
  came out of the 500-user warm-up (tiny batches), discarded; redone at 150k without a warm-up.
- **e21 hold at 220k crashed the process 150 s in** (solo, epoll): until then p95 100-130 ms, p99 ~140 ms at 57,500 req/s, then
  6 s of ~650 errors/s (`conn_closed`/`conn_reset` with `dropped (client gone)` on our side), and `OutOfMemoryException` on thread
  `io-1` with a 100 MB heap, stack only in the runtime's exception code. Same family as the e10 "Out of memory." at 300k: both only
  above 200,000 users, where the fd budget forces evictions. Replay (`experiments/evict.py`, 800 clients, fd limit 420) crashes the
  old build in under 40 s, with a stack overflow in the exception path.
- **e23: the cause was stale epoll events.** The connection table was global and the epoll tag was the fd alone. Loop A evicts fd X;
  loop B accepts a new connection, gets number X; A's batch still holds an event for X, and A runs B's connection. Two threads on one
  `Conn` corrupt each other's LRU lists and buffers. The tag now carries the generation, and an event for an older one is ignored.
  Same replay: no crash. io_uring never had the bug (its completions always carried the generation): e21 with `IO_MODE=uring` passed
  its 220k hold, p95 140, p99 193, 0.10% errors, 116.9 µs/req (app 51.0, PG 65.9), against #87's 124.9 at 230k.
- **Harness: conntrack.** That hold's errors were all timeouts, starting ~180 s in, with `nf_conntrack: table full` in dmesg:
  `box/setup-box.sh` sets `nf_conntrack_max=1048576`, wsl26 had 262144, and 3,000 re-dials/s leave 120 s TIME_WAIT entries. `h.sh` sets
  it now, so holds before this point above ~200k carry that artifact (#87's 230,000 too: it may do a bit better on the fixed harness,
  to be re-run before the PR).
- **e24: each I/O thread owns its fd table.** `RLIMIT_NOFILE` is counted per fd table, and `unshare(CLONE_FILES)` gives a thread its
  own, as a worker of a multi-process server has. Above 200,000 users every shared-table server pays: evicted idle connections re-dial
  on their next request (~3,000 connects/s at 220k here, 1.07M in the hold), with accept, close and TIME_WAIT on top. Four tables hold
  ~800,000. The connection table moves into the loop, since one number is a different socket per loop. Two things need care: a file
  first opened on a loop thread and kept open would be invisible to the other threads, so stderr's stream and all assemblies are opened
  before the threads start; and a loop's copy of the table keeps Postgres sockets open, so closing one now does `shutdown` first.
  Replay with `FD_TABLES=shared` also shows what EMFILE does to a .NET process: `Failed to initialize assembly ... System.Diagnostics.
  StackTrace.dll`, a lazy load failing for want of an fd; connection fds now can't starve the runtime's table. Replay: ~19k req/s vs ~9k.
  Considered and not taken: io_uring direct descriptors (fixed files) also escape the fd limit, but on 6.8 file releases are FIFO behind
  the oldest pending request's resource node, so an idle connection's pending recv holds back the release of every socket closed after it.
- **e25: comments take each viewer's whole followee list from one grouped scan** (`follows` over the sorted viewer ids) instead of
  first collecting the authors each viewer's threads have and probing per viewer. On 40 real batches, run-aged DB: 3.97-4.31 -> 3.55-3.78 ms
  per call, buffers about equal, and the statement loses a parameter. Also tried: joining users per comment and dropping `t=2`: 5.1-5.4 ms, worse.
  The rd ablation on the same batches (15.4 ms per batch): no feeds 8.4, no favorite counts 9.6, no tags 12.9, no list counts 13.4, no flags
  13.7, no follows 14.5, no authors 14.4, no bodies 15.1. A feed's articles are nearly all its viewer's alone, so feeds pay for rows the
  other lists share.
- **bcrypt build check (not an experiment, no change).** bcrypt is the largest single app cost (~11-20 ms x 0.1% of requests), so: flags at 6 lanes,
  CPU 23, best of 6: `-O3 -funroll-loops` 10.5 ms per hash, `-O3` 10.7, `-march=x86-64-v3` 10.8, `-mtune=znver3` 11.3, `-O2` 16.8. Ubuntu 24.04's gcc 13.3,
  which the scorer's build uses, 10.7. That's ~2.9 cycles per lane per round; a hand-allocated assembly loop would have 14 instructions per lane-round, ~2.3
  cycles at best on a 6-wide core, so ~1% of total CPU for x86-only assembly. Not worth it.
- **Dropped: favorite flags in one scan** (all viewers x all the batch's articles on `favorites_pkey`, instead of one probe per viewer). Same buffers, but 10.1 ->
  24.4 ms per batch on real batches: 836 ids in a second `ANY` make it much slower per tuple. Groups in a batch were already distinct per key (9.6 tag, 14.2 author, 32
  feed groups per batch), so there's no count to share there either; a capped tag count costs its 1,000 index tuples per tag.
