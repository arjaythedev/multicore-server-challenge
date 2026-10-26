# Worklog (F# multicore, delneg)

All numbers are local, on a Synteq box (8 shared vCPUs, Xeon Platinum 8260, 16 GB, Ubuntu 24.04, kernel
6.8.0-147), not the grader's box. Postgres 18 on the same box, configured by `box/setup-box.sh`.

Protocols (scripts in `scripts/`):
- **screen** (`screen.sh`): fresh DB + cold caches (switch.sh), loadgen pinned to CPUs 6-7 with `-think-scale`,
  CPU per request over the last 120 s of a 150 s window, loadgen excluded. Decides experiments; never a user count.
- **hold** (`hold.sh`): real think time, 60 s ramp + 300 s hold, loadgen on the same box (a lower bound).
- **overload** (`overload.sh`): 3 x (2,000-user burst killed mid-request + 2,000 reset connections), then the
  server must still serve.

## Phase 0-1 (26 Oct)

- Box: Go 1.27.3, dev and full seed (conduit_seed, 2.3 GB), conduit-tools installed, .NET 11 RC 3 SDK.
- First version (8f9f089): 197/197 on dev and full seed, first try. Shape (after Opt's addendum 1: one shared
  read queue, not per-loop connections): 2 I/O loops (own ring, SO_REUSEPORT listener, multishot accept into
  fixed files, multishot recv with classic provided buffers), one Postgres thread owning 6 read + 8 write
  connections in its own ring and every batch queue (#22's policy: no timer, batch <= 64, kind <= 6 connections,
  depth 1), 2 bcrypt threads x 4 lanes (C core from #10), cross-thread hand-offs through eventfd mailboxes.
- Bugs on the way: SINGLE_ISSUER rings must be created on the thread that enters them (else every
  io_uring_enter fails and the loop spins); an O_NONBLOCK eventfd makes io_uring answer EAGAIN instead of waiting.

## Screens: baseline and references (26 Oct)

6,000 users, think-scale 0.1, ~15.8k req/s, steal 0:

| run | box us/req | app | Postgres | p95 |
|---|---|---|---|---|
| #7 (rust-tokio-Scooter1337) | 300.6 | 84.1 | 221.7 | 6.5 ms |
| #22 (csharp-sockets-jh-d) | 374.1 | 97.7 | 278.9 | 7.0 ms |
| v1 (8f9f089) | 326.6 | 86.8 | 243.8 | 5.4 ms |
| v1 again, e1-off-a / e1-off-b | 324.7 / 322.9 | 86.8 / 86.0 | 241.1 / 240.9 | 5.5 / 5.6 ms |

Repeat noise on the same build: ~2 us/req. The app's threads during a screen: Postgres thread ~0.32 core, two
bcrypt threads ~0.42 core together (cost 10 is fixed by the rules: ~30 us of every request), two I/O loops ~0.41
core.

Tooling: `replay.sh` / `replay-all.sh` time each batched statement (dumped by the server with `MC_DUMP_SQL`) over
fixed seeded inputs in one backend and read its CPU from /proc: SQL shape A/B without HTTP noise. All box jobs
(builds, screens, replays) go through one queue so nothing overlaps a measurement.

## Experiments 1-3 (26 Oct)

- **1 tags broadcast** (`TAGS_BROADCAST`, on by default): one `ARRAY(SELECT name FROM tags ORDER BY name)` answers
  every tags request queued when it starts (#48 says this is allowed). 319.7 vs 324.7/322.9: -4 us/req. Small:
  the batched per-request form was already cheap. Kept.
- **2 #7's shared lists** (`LIST_SHARED`): 5.2k req/s, Postgres 1122 us/req: a disaster. EXPLAIN in the replay:
  under `force_generic_plan`, `LIMIT r.l` over a LATERAL page is estimated at a tenth of the table, so the planner
  hash-joins the batch's pages to all 500k articles and 100k users (34 ms per request). #7 avoids it with a
  constant `LIMIT 100` around the page; the API caps limit at 100, so a `SELECT * FROM (page) LIMIT 100` wrapper
  is exact. Added to every shared and packed page.
- **3 packed lists** (`LIST_PACKED`, `FEED_PACKED`; #82's form): each distinct article of a batch comes back once,
  then one narrow row per request (count, page ids, favorited ids, followed authors). The app writes each article's
  JSON once per batch with both flags false and assembles every response from those bytes (`Db.Packer`). Global
  list: one count per batch (the per-request count walks 1000 index entries: over half of a list request's cost),
  each viewer's flags by two range reads; filtered lists: a count per key and `= ANY(page)` flags; feed: each
  viewer's followees read once for count and page, every author followed. Replay, PG CPU per request at batch 16:
  global 237 -> 69, tag 325 -> 269, feed 431 -> 356. Responses identical to the per-request form for 603
  concurrent requests over 18 users (`compare.py`).
- Screens, 3 vs base: packed 351.6 (app 80.8, PG 274.9) vs base 321.6 / 320.8 (app 86.5, PG 239.4). App -6 us
  (each article's JSON once per batch), PG +35. `MC_STATS` (now per kind): 6,500 statements/s averaging 2.2
  requests (list 2.3, feed 2.0, tag 1.5, article 2.7). Replay by batch size (us PG CPU per request):

  | batch | list | list packed | tag | tag packed | feed | feed packed |
  |---|---|---|---|---|---|---|
  | 1 | 462 | 563 | 500 | 638 | 725 | 694 |
  | 2 | 306 | 319 | 400 | 488 | 450 | 544 |
  | 4 | 275 | 200 | 363 | 388 | 419 | 438 |
  | 16 | 237 | 69 | 325 | 269 | 431 | 356 |

  Batch 16, other kinds: article 112, comments 77, author 262 (packed 183), favorited 219 (packed 181), profile
  19, user 23, tags 4. Two lessons: packed only above a batch size (`LIST_PACKED_MIN` 4 for the global list,
  `PACKED_MIN` 8 for the rest), and batch size itself is the big lever: weighting batch-16 costs by the request
  mix gives ~134 us/req of reads against 239 measured at batch 2.2. Next: the batch clock.
- **4 batch clock 3 ms** (`BATCH_WAIT_US=3000`): 320.8 -> **247.2** us/req (PG 237.6 -> 175.1, app 87.6 -> 77.0),
  p95 5.4 -> 9.8 ms, p99 14.9 -> 18.5. Under the 250 target already. (#79 measured the same direction.) Fewer
  statements also means fewer Postgres wake-ups and fewer sends and receives on the Postgres thread.
- **5 packed above a batch size** with the clock: 238.5 / 240.3 vs 247.2 / 254.9 (clock alone). Kept.
- **6 shared article/comments** (#82, `SLUG_SHARED`): 239.4 / 241.1, no gain over 5 at this load. Off by default.
- **7 longer clocks**: 6 ms 220.0, 10 ms 209.8 us/req (p95 14.5, 21.0 ms). The closed-loop users wait longer,
  so req/s drops a little (15.6k, 15.4k); CPU per request keeps falling. Replicates and 20 ms queued.
- **Candidate (e7)**, defaults: tags broadcast, packed lists above a batch size, 3 ms clock, shared forms off:
  241.6 us/req (app 77.8, PG 167.7), p95 9.6 ms, 0 errors; batches now average 7.3 requests (comments 13.7,
  article 11.4, list 7.7, feed 5.5). Overload PASS, 197/197 on dev and full seed. Committed.
- Profile (perf, 30 s): bcrypt is 43% of the app's samples. Lanes, one thread, cost 10: 1 lane 60.1 ms per
  hash, 2 lanes 36.8, 3 lanes 26.4, 4 lanes 23.8. Logins run at ~16/s and mostly batch already (p50 login 148 ms:
  they wait for company); the average is ~26 ms per hash, so ~24 us of every request is the bcrypt floor.
- Commit 3e85e34 pushed; upstream PR #87 opened (local numbers marked as not official).
- **9 clock length** (env only): 6 ms 221.0; 10 ms 213.4 / 213.0; 20 ms 197.8 / 196.6 (p95 35-36 ms, far under
  the 500 ms limit). 30 / 50 ms and a batch cap of 256 queued.
- **10 bcrypt batching**: logins at ~16/s. Waiting up to 150 ms for company even when the hashers are idle: app
  73.3 -> 69.5. With one hasher thread as well (more lanes filled): app 66.1, box 200.0 vs 207.6. One thread
  hashes ~42 logins/s at 4 lanes; ~120k users would ask ~33/s on a busy box, too tight, so the second thread now
  helps only while 4 or more jobs are queued (`BCRYPT_HELP_AT`).
- **11 clock 30 / 50 ms**: 193.2 / 190.8 us/req, p95 48 / 61 ms. Diminishing: 20 ms takes most of it at p95 35 ms.
  The clock only matters below saturation; at full load batches fill on their own.
- **12 batch cap 256** (20 ms): 204.6 vs 197 at 64. Discarded.
- Article EXPLAIN (batch 16): only index lookups (slug, user, tags, favorites count, flags); nothing to cut in the
  plan. Unix socket to Postgres: no, the box's pg_hba allows scram on 127.0.0.1 only (and `$DATABASE_URL` is TCP).
- **13 shared slugs at 20 ms**: 198.7 vs 198.5. Still nothing; stays off.
- **14 FEED_BIG** (the batch's most shared followees checked once for a 1000th article, from #82/#61): same
  responses (cmp 603 requests, 0 differ), 192.9 / 193.8 vs 192.2 / 197.4. Within noise on this DB, where few
  authors reach 1000 articles. Code removed.
- **15 bcrypt helper**: hasher 0 always runs, hasher 1 joins only while 4+ logins are queued, and a login waits up
  to 150 ms for company even when idle. 196.3 / 193.8 vs 208.1 / 201.9 (app 68.2 vs 74.7). Kept: a burst of logins
  still gets both threads.
- **16 knobs at 20 ms** (one screen each, base ~194): BATCH_INFLIGHT 3 192.7, DB_CONNS 4 **187.1**, server GC
  189.5, LOOPS 1 186.5 (app 62.9). One I/O thread would have to carry ~25k req/s at 100k users: no. Four read
  connections next, at 6,000 users and at high load (fewer connections = bigger batches, but less parallelism).
- **17 bcrypt lanes** (bench): 4 lanes 22.8 ms per hash, 5 lanes 21.5, 6-8 no better (the 4 KB state per lane
  starts to crowd L1); x86-64-v3 the same; -O2 much worse (33.0). Not worth the change.
- **Candidate (e14)**: 20 ms clock, bcrypt helper: 197.2 us/req (app 68.4, PG 131.4), p95 37.0 ms, 0 errors.
  Overload PASS, 197/197 on dev and seed. Committed.
- **19 four read connections, replicated**: 205.1 / 196.7 vs 198.2 / 194.6. The single 187.1 was noise; the
  screen's spread is about +-4 us, so small effects go to the SQL replays instead.
- **20** DB_CONNS 3: 196.7; DB_CONNS 4 + BATCH_INFLIGHT 3: 193.7. Noise band; defaults stay.
- **21 high load** (6 read connections): 10,000 users at think-scale 0.1, 25.1k req/s, 186.0 us/req, p95 60 ms;
  12,000 users, 29.1k req/s, 184.0 us/req, p95 96 ms, 5.36 cores (+1.5 for the load generator). With 4 read
  connections p95 at 12,000 was 138 ms: fewer connections cost parallelism at high load.
- **22 feed count** (replay): one capped walk instead of `EXISTS ... OFFSET 999` then `count(*)`: 360-367 vs 365
  at batch 16, worse at 8. The first replay of a run is cold (r1 numbers dropped).
- **23 comments**: a follow probe per comment instead of the viewer's followee array: 52.1 vs 47.9. Discarded.
- **24 Postgres split** (60 s of a screen, by backend): read connections 1.74 cores, write connections 0.35
  (~23 us/req: ~405 us per write request at ~860 writes/s), background processes ~0. Group commit is next.
- **25 write replay** (`scripts/wreplay/`, psql pipelines like the app's): a favorite (insert + article read +
  commit) costs Postgres 375-442 us alone; batched 4: 175-217, 8: 144-167, 16: 115-133 per request.
- **26 group commit** for favorite, unfavorite, follow, unfollow: write kinds on the same 20 ms clock; the batch's
  insert or delete is one statement (rows in key order, so concurrent batches lock in the same order), then the
  batched article or profile read answers each request, all in one transaction on a write connection. If the
  batch fails, each request runs again alone (the old path). 189.5 / 190.4 / 188.3 vs 207.1 / 196.2 us/req;
  write connections 0.349 -> 0.217 cores. Conformance 197/197 (dev, seed), responses identical. Kept.
