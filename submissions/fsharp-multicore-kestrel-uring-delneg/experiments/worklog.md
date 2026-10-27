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
- **27 high load with group commit**: 12,000 users, 29.5k req/s, 177.3 us/req, p95 84 ms (was 184.0, p95 96).
- **28 group commit for new comments**: `INSERT ... RETURNING` cannot name the request, so the new rows are matched
  back by (author, article, body) and their rank among identical ones (identical posts get distinct comments).
  189.4 / 184.0 vs 196.8 / 198.8 with `COMMENT_BATCH=0`. Conformance 197/197. Kept.
- **29 feed in one walk** (replay): the followees' article ids once (capped at 1000) for both count and page:
  433-442 vs 375-425 us. The per-followee probes are cheaper than sorting the whole set. Discarded.
- **Candidate (e19)**: 185.2 us/req (app 65.4, PG 121.2), p95 37.3 ms, 0 errors; overload PASS. Committed.
- **31 ring waits** (`MC_WAIT_N` 4 / 16): 180.2; 184.9 / 196.9 vs 181.8 / 183.3. Noise. Off.
- **32 batch sizes at 20 ms** (MC_STATS): tags 59, article 59, comments 59 (near the 64 cap), list 42, feed 33,
  profile 18, author 15, tag 14, favorite 7, comment 5, favorited 4, follow 3, user 2.4.
- Feed EXPLAIN (batch 16): viewers follow ~21 authors with ~900 articles between them; 13 of 16 reach the
  1000 cap. Count walk 0.17 ms, page 0.26 ms (21 probes, ~360 ids sorted), enrichment ~0.1 ms per request.
  Viewers in a batch share only ~9% of their followees, so per-batch sharing can't save much there.

## Overnight batch (box, us/req; 12k = 12,000 users, 6k = 6,000 users, think-scale 0.1)

- **33 I/O loops** at 12k: on 185.3 / 175.0 / 174.8; `LOOPS=1` 178.5 / 171.9 / 173.3 (app 57.6 / 55.9 / 56.5,
  p95 100 / 76 / 69 ms); `LOOPS=4` 179.0 / 185.9 / 190.0. One loop is maybe 3-5 us cheaper with a worse p95;
  four are worse. Pending replicates.
- **34 server GC** (`DOTNET_gcServer=1`, 2 heaps): 12k 172.5 / 176.0 / 178.5, 6k 186.4 vs on 192.6. A small gain is
  possible, p95 mixed. Pending replicates (m1).
- **35 no spin** (spin0): 175.6 / 176.4 / 176.8, 6k 191.5. Neutral. Off.
- **36 ring waits** `MC_WAIT_N=32` (1 ms): 178.8 / 173.7 / 181.6. Neutral. Off.
- **37 clock** 10 ms: 191.2 / 186.5 / 192.1 (worse); 30 ms: 178.2 / 177.8 / 174.9 (same as 20 ms, more latency).
  20 ms stays.
- **38 counts that walk the oldest end** (`COUNT_OLDEST`, cmp 0 differ): 6k 190.9 / 188.9 / 189.8 vs
  183.3 / 198.8 / 196.7; 12k 176.9 / 178.7 vs 172.2 / 184.3. Replay on an aged DB (620k articles, made by
  age-mc.sh): feed 394-422 vs 422-441 (worse), author 200-212 vs 197-209; on the seed no gain. Discarded, code
  removed.
- **39 bcrypt 5 lanes + `-funroll-loops`** (rbench, ms/hash on the box): `-O3` 4 lanes 22.44, 5 lanes 21.18,
  6-8 worse; `-funroll-loops` 4 lanes 22.03, 5 lanes 20.87 (-7% in all); `-fno-tree-vectorize` no change.
  Screens: 6k 195.7 / 182.9 / 175.2, 12k 179.1 / 173.7 (noise band). Pending replicates (m1).
- **40 buffer ring** (`MC_BUFRING=1`, e24): kernel 6.8.0-147 refuses the register with EINVAL; the retry with
  `resv[0]=1` works ("io: receive buffers from a buffer ring"), the same EINVAL that made #10 / #79 / #45 drop
  buffer rings. 6k 185.7 / 177.5 / 191.2 vs on 187.3 / 179.0 / 189.0; 12k 179.4 / 175.5 vs 179.4 / 183.2. Within
  noise. Discarded: the code is removed (keep only if it wins beyond noise).
- **41 aged-DB costs** (replay, PG us/req at real batch sizes): article 43.9 (b59), comments 147.5, list packed
  87.6, tag packed 354.

## Ideas from other PRs (2026-10-27 scan; LEADERBOARD.md, official box)

- #47 rust-epoll-WorriedArrow, 120,000 (30,189 req/s, app 28% / PG 60%, about 159 PG core-us/req): one queue of
  every read kind per lane; phase A per kind over distinct keys, phase B enriches the union of the batch's
  articles once (tags, favorite count, author), viewer flags as one `= ANY` scan per viewer. Batches up to 4096.
- #99 (follow-up to #61, 110,000): batch ordered by (filter, offset, limit, viewer); tags sorted in the app
  instead of `ORDER BY` in the tag subquery; reports a 130,000 hold on the official DO setup.
- #91 (follow-up to #52): `enable_hashagg = off` for the session ("generic plans oversized the DISTINCT hash
  tables"); a 40 ms / 256 read window.
- #95: batches up to 512 in one read-only snapshot; #97: #47 plus batch-local JSON, 128,000 locally.
- #100 (follow-up to #45): a single packed statement for list, feed, article, profile and tag reads; feed count
  proofs.

## Morning (2026-10-27)

- **42 hashagg off** (#91; replay, PG us/req, warm round): feed 347 vs 356, author 190 vs 190, tag 329 vs 332,
  article 38 vs 39, comments 44 vs 44, list 55 vs 54. The first round looked like a win only because the default
  ran cold first. No effect on our plans. Discarded (screens dropped).
- **Seed feed facts**: 28 authors have >= 1000 articles (max 14,419); 78,628 of 99,932 viewers follow one of them;
  83,172 have >= 1000 feed articles (capped count). Followers per author: median 28, p90 99, p99 616, max 35,515.
- **43 feed count proof** (`FEED_PROOF`, idea from #100): per batch, the up to 8 followees that at least two
  viewers share are probed once for a 1000th article; a viewer following one gets count 1000 without its own
  walk (same statement, same snapshot). Replay (PG us/req): b16 394 / 391 -> 391 / 372, b33 367 / 355 -> 315 / 312,
  b64 339 / 319 -> 278 / 289. Row diff vs the current statement over 60 batches: 0 of 12,970 rows differ.
  Screens (e25, 12k): on 170.7 / 170.0 / 169.5 (PG 112.8 / 112.4 / 113.4) vs `FEED_PROOF=0` 174.4 / 186.4 / 176.6
  (PG 117.8 / 125.1 / 120.3). About -5 us of PG per request. Kept, on by default.
- **References on this box** (12k): #47 rust-epoll-WorriedArrow 183.8 us/req (app 77.4, PG 108.2), 24,836 req/s,
  p95 175 ms; #61 go-epoll-MegaPanchamZ 225.9 (app 75.6, PG 150.6), 28,270 req/s, p95 127 ms. Earlier (6k):
  #7 300.6, #22 374.1. Ours runs ~175-185 (app ~57-65, PG ~118): cheaper app, ~10 us more PG than #47.
- **44 feed clock 40 ms** (per-kind `WAIT_FEED`, e26): 12k 170.6 / 175.0 / 170.1 vs on 168.0 / 170.4 / 173.8; p95 95 / 98
  vs 73-85 ms. Bigger feed batches don't pay at this load. Discarded, code removed.
- **45 tag pages in one walk** (replay): one newest-first array of up to 1000 ids per distinct tag gives both the
  capped count and the page: b14 329-339 vs 318-321, b28 284-289 vs 273. Building the array costs more than the
  second walk. Discarded (never in the code).
- **43b proof width** (replay, `FEED_PROOF_N` 4 / 8 / 16): b33 312-442 / 306-341 / 330-339, b64 298-338 / 280-286
  / 288-302. 8 stays.
- **46 server GC** replicates (6k, e27): 188.4 / 192.6 / 173.9 vs on 206.6 / 175.2 / 178.8; app 66.0 / 69.9 / 65.6
  vs 71.2 / 65.1 / 66.4. No consistent gain. Discarded (workstation GC stays).
- **47 batch cap 128 for article and comments** (`BATCH_ARTICLE` / `BATCH_COMMENTS`, e28, 12k): 164.3 / 163.5 / 166.7
  vs on 163.6 / 166.5 / 169.2 (PG 108.6 / 107.5 / 110.5 vs 109.7 / 111.0 / 112.4), p50 25-27 vs 19-21 ms. About
  -1.5 us inside the noise, for more latency. Discarded (64 stays).
- **48 bcrypt 5 lanes + `-funroll-loops`** (e28, 5 is now the default): 12k on 167.5 / 173.9 / 169.5 (app 57.5 /
  58.3 / 57.9) vs `BCRYPT_LANES=4` 172.6 / 167.6 / 173.8 (app 59.8 / 58.2 / 59.9); with the h1 "on" runs (also
  5 lanes) 163.6 / 166.5 / 169.2. 6k (m1) 189.3 / 171.7 / 181.1 vs 206.6 / 175.2 / 178.8. rbench: 22.44 -> 20.87
  ms per hash. About -1.5 us of app per request. Kept. Conformance 197/197 dev and seed, overload PASS.
- Harness: `conf.sh` sometimes failed with errno 98 on 127.0.0.1:3000. The load generator's ephemeral ports on
  this box can include 3000, so a leftover loopback connection blocks the bind (not an issue on the official box,
  where the load comes from other machines). conf.sh now waits until no socket uses :3000 and retries once.
- **Profile at 12k** (perf, e28): bcrypt is ~49% of the app's CPU samples (`eks5` 44.7%, partial batches
  `eks4` 1.7, `eks3` 1.35, `eks2` 0.6): at this rate the lanes are full, and hashing is about half of the app's
  ~57 us per request. Next: JSON text arrays 1.7%, memmove 1.4%, kernel copies.
- **49 bcrypt `-march=native`** (rbench, Xeon Platinum 8260): 5 lanes 21.09 vs 20.93 ms/hash with
  `-O3 -funroll-loops`; `-O3 -march=native` 21.38; `-O2` much worse. Discarded.
- **Holds at real think time** (60,000 users, hold.sh): both runs "fail" with 62-75% timeouts, but they are
  limited by the load generator: it falls behind in 292-300 of 300 s, its users stall at ~42k, and the box sits at
  ~27% CPU. An independent probe during the second run (curl every 2 s, holdprobe.sh) got 200 from
  `/api/tags` and the article list in 9-34 ms throughout, with 35-58k established connections. The local box
  can't drive real-think holds this large; the 12k / think-scale 0.1 screens (the same request rate as ~120k
  real users) stay the proxy.
- **Final candidate** (ed47939): 12k 163.0 / 166.4 / 167.9 us/req (app 55.3 / 57.3 / 57.1, PG 109.5 / 110.7 /
  112.3), ~29.7k req/s, p95 64-77 ms, 0 errors; 6k 171.7 / 175.7 / 176.4, p95 35 ms.
- **50 bcrypt lane-state padding** (rbench, 0-496 pad words after each 4,168-byte lane state, against L1 set and
  4K aliasing between lanes): 5 lanes 20.91-21.41 vs 20.96 unpadded; 6-8 lanes stay worse. Discarded.

## Stop (budget of 50 reached)

Kept this session: the batch-shared feed count proof (3093246) and 5 bcrypt lanes with `-funroll-loops`
(ed47939). Addendum items: buffer ring with the resv retry measured and dropped (noise); loops, server GC, clock,
spin and ring-wait knobs re-measured (defaults stay); PR ideas from #47, #91, #95, #97, #99, #100 reviewed, #100's
feed count proof adopted, #91's hashagg off measured (no effect).

## Run 2 ([McscFs2], from 27 Oct; budget 100 experiments from n=51)

- **Baselines** (ed47939, 12k): 168.9 / 167.1 us/req (app 58.7 / 56.6, PG 112.0 / 112.0); #47 on the same box 184.2 /
  190.7 (app 78.6 / 77.9, PG 107.5 / 114.0) at 24.8k req/s (its 400 ms bcrypt window and 20 ms lane clock add
  ~85 ms of p50, so its closed-loop users send less). **Heavy screen = 14,000 users** at think-scale 0.1: 32.3k
  req/s, 174.1 us/req, p95 140 ms; the load generator's process used 81% of its 2 CPUs and never fell behind
  (box 7.2 of 8 cores busy). 12k and 14k from here on.
- **pg_stat_statements at 12k** (pgss.sh: extension on for one run, reset at 75 s, dropped after; one window
  each). Ours (on.env, 29.7k req/s): 460 s of exec time; feed packed 184 s (33.4 ms x 5,526 calls, ~40%), article
  76 s (6.6 ms), comments 54 s (2.6 ms), author/tag packed lists 50 + 40 s, global packed 16 s, favorited 13 s,
  writes ~15 s. #47 (25.2k req/s): 331 s; feed 105 s (19.4 ms, pages only, no enrichment), artx 70 s
  (11.4 ms), comments 49 s, flags 29 s, tag list 20 s, article base 13 s, author list 10 s, tagnames 9 s. Per
  request ~15.5 ms ours vs ~13.1 ms #47: the planner (phase A pages + phase B artx/flags once per article) is
  where #47 saves Postgres time.
- **n=51 planner stats** (PLANNER=1, MC_STATS, 12k): 163.8 us/req (app 64.2, PG 100.2) but 26.4k req/s, p50 75 ms
  (all eight read kinds wait for one 20 ms clock, then two phases in a row); ~48 planner batches/s of ~410 requests.
- **51 batch planner** (#47, `src/Planner.fs`; A,B alternating x3): 12k 164.3 / 172.6 / 159.7 vs 167.6 / 168.1 /
  168.1 us/req (mean -1.4%); 14k 160.2 / 158.4 / 162.4 vs 166.8 / 170.9 / 174.1 (mean -6.0%). Postgres drops
  ~15 us/req (96-99 vs 111-116 at 14k), the app gains ~7 (64-65 vs 57-59: per-batch key tables, row copies, JSON
  pieces). Closed-loop req/s at 14k 29.4-29.7k vs 32.0-33.3k, p95 183-210 vs 130-158 ms (one 20 ms clock for all
  eight kinds, then two round trips). Overload check PASS (tags 200, after: 15,433 requests, 0 errors). **Kept, on
  by default** (`PLANNER=0` falls back).
- **Planner pg_stat_statements** (12k, PLANNER=1): 366 s exec at ~26.4k req/s (13.9 ms/req; #47 13.1). Feed 97 s
  (18.5 ms/call, below #47's 19.4: the count proof), artx 95 s (15.7 ms; #47 artx 70 + tagnames 9), comments
  54 s, flags 29 s, tag list 24 s, article 15 s, author list 11 s.
- **Per-thread app CPU** (perf, 12k): planner postgres thread 13.0 us/req vs 10.3, I/O threads 23.5 vs 20.8,
  bcrypt 29.6 vs 29.0. On the postgres thread, writing `/api/tags` bodies (one per request, the full tag list)
  was ~1.5% of the app's samples: now written once per broadcast batch and copied (`Handlers.tagsRows`).
- **artx replay** (`scripts/artx.sh`, 700 newest-skewed articles per batch, generic plans, backend CPU, 3 runs):
  names by per-tag subquery (ours) 12.6-13.1 ms; #47's tag ids + tagnames 11.9-12.6; names by join 19.5-20.7
  (worse); tag ids alone 10.3-10.9. 200 tags in the seed and after a run, so reading all `(id, name)` once per
  batch is nearly free. Split of the tag-id form: no favorite count 3.7-3.9, no author join 8.2-9.0, no tags
  8.3-8.5: the exact favorite count is ~65% (the newest 700 articles carry ~21k favorites, max 1,578 on one).
- **Feed page cutoff replay** (`scripts/feedpl.sh`, 44 feed pages per batch over random followers, limit 10,
  offset 0 or 10-40): current planner feed 11.3-11.8 ms per batch (counts alone 3.2); with #102's cutoff (the
  batch's most shared followees' (limit + offset)-th newest id bounds every follower's per-followee scan): 2 of
  8 followees 8.0-8.4, 2/32 8.6-9.0, 1/64 9.1-10.1, 1/1000 18.9-20.4. Rows equal on 30 batches.
- **52 tag ids in artx** (p3; A,B alternating x3, `PLANNER_TAGIDS=0` as the old arm): 14k 153.3 / 153.8 / 150.2
  vs 154.3 / 157.5 / 163.4 us/req (mean -3.8%, PG 89-93 vs 94-101); 12k 170.1 / 162.4 / 152.7 vs 172.7 / 174.9
  / 158.4 (-4.1%). cmp 603 requests 0 differ (tag order included), 197/197 dev and seed. **Kept.** The 12k
  screens of the planner are bimodal (PG ~92-100 or ~105-109 per run, in both arms); 14k is steadier.
- **53 #79's asm bcrypt kernel** (`asm_gen.zig` ported to Python, 11 instructions per lane-round, `ah` and
  `bextr` forms; rbench3: one pinned core, best of 3, two rounds, all hashes checked): ms/hash at lanes 1-5,
  C 56.6 / 34.8 / 25.5 / 22.1 / 20.95; ah 63.9 / 33.9 / 25.1 / 21.5 / 20.2; bextr 62.8 / 35.1 / 27.3 / 24.2 /
  23.1. -3.6% at our 5 lanes, under 1 us/req. **Discarded.** The box is a Xeon 8260 (Cascade Lake, 2 load
  ports); the S-box loads bound the C core already, #79's 7.9 ms/hash is on Zen 5.
- **Aged-copy replays** (`age-mc.sh`: seed + a run's worth of writes, autovacuum on): artx names by subquery
  21.8-22.1 ms/batch, tag ids + tagnames 20.6-22.0, names by join 28.6-29.2, tag ids 18.3-19.5; without the
  favorite count 4.1 (the count is ~78% of artx on the aged copy). Feed page bound P0 12.1-12.6, 2 of 8
  8.9-9.3, 2/32 8.9-10.2, 1/64 9.5-10.5, 1/1000 20.0-21.8; rows equal.
- **54 feed page bound** (#102; p4, A,B alternating x3, `FEED_CUT=0` as the old arm): 14k 148.4 / 149.0 / 152.3
  vs 153.0 / 154.3 / 152.2 us/req (mean -2.1%, PG 87-89 vs 91-92); 12k 151.3 / 147.6 / 151.4 vs 161.1 / 155.3
  / 152.9 (-4.0%). 197/197 dev and seed. **Kept.** p4 also adds `PLANNER_WAIT_US` (the planner's own clock,
  default the batch clock: no change).
- **56 comments statement** (`scripts/cmtpl.sh`, 60 slugs per batch): no final ORDER BY 1.85-1.90 ms/batch vs
  1.90-1.95 on the seed (aged, one round: 7.25 vs 7.65); authors read once by `= ANY` and hash-joined 2.45-2.60
  (worse); without authors 1.0-1.1. **Discarded** (B's order is not guaranteed by SQL). A `tee /dev/stderr` in
  a replay truncated the box's queue log, which lost the other aged rounds.
- **Profiles at 12k**: #47's app 82.3 us/req, bcrypt 51.8% of its samples (~42.6 us/req; ours ~29). Our
  Postgres at 14k (pgsplit): read connections 2.27 cores, write 0.26.
- **55 grouped favorite counts** (p5, `PLANNER_FAVGRP`): 14k 143.6 / 145.3 / 146.9 vs 143.1 / 143.3 / 153.1
  us/req; 12k 154.7 / 153.3 / 143.9 vs 146.7 / 157.3 / 148.8. No change. **Discarded.** The artx replay that
  suggested it (-40%) drew article ids with repeats, which the per-article form counts again and again; the app's
  artx gets distinct ids. With distinct inputs: 5.9-6.2 vs 5.7-6.0 ms/batch (tag ids and authors by `= ANY`
  too: no change). The earlier artx replay numbers (n=52 and the aged copy) carry the same bias; n=52 stands on
  its screens. artx.sh now draws distinct ids.
- **pg_stat_statements on p5 at 14k** (350 s of execution): artx 85 s (809 rows/call, 14.1 ms), feed 85 s
  (16.3 ms), comments 57 s (1,392 rows/call, 10.8 ms), flags 32 s, tag list 26 s, article 15 s, author list
  11 s, writes ~25 s.
- **57 comment authors in phase B** (replay, aged copy: 60 slugs, 1,592 comments, 1,488 distinct authors per
  batch): comments as now 7.0-7.85 ms/batch; without the users join 3.35-3.5 plus one users-by-id `= ANY`
  statement 3.1-3.35. ~-10% of comments, ~1.5% of Postgres. **Discarded** (a user row costs ~2.1 us either way;
  everything is cached, shared_buffers 4 GB). Same copy, distinct ids: artx per-article counts 7.2-7.4 vs grouped
  7.7-8.0, as n=55 found. `age-mc.sh` now looks authors up by row number (47 s instead of 30+ min) and
  refuses to start under 5.5 GB free (the copy and its WAL took the box to 1.1 GB once; dropped at once).
- **58 `enable_memoize = on`** (session setting, off since the start): generic plans add Memoize over the feed and
  tag pages' article fetch and the comments' users lookup. 14k 149.2 / 151.5 / 165.2 vs 145.9 / 151.9 / 157.5;
  12k 156.3 / 159.9 / 152.6 vs 150.6 / 155.7 / 146.5. **Discarded.**
- **59 v1's knobs on the planner build** (14k, one round each of on, `LOOPS=1`, `BATCH_MAX=256`, 4 read
  connections with dispatch depth 2, bcrypt waits 400 ms, `PLANNER_WAIT_US=30000`): on 149.7 / 164.7 / 156.5,
  l1 145.3 / 143.5 / 145.5, b256 145.8 / 142.6 / 146.9, c4d2 150.4 / 143.2 / 145.6, bw400 153.2 / 144.0 / 146.4,
  pw30 153.0 / 146.9 / 146.2. The on arm always ran first in its round: inconclusive. One I/O loop had less
  kernel time in every round (sys 18.0-18.2 vs 19.5-20); l1 and b256 re-tested in rotated order (v2r2).
- **Postgres profile at 14k** (perf over all backends): index descents dominate (`_bt_first` 35% inclusive,
  `_bt_search` 18%, `_bt_compare` 10% self), subplans 20%, heap fetches 16%, buffer lookups 4.5% self; the wire
  protocol does not show. Fewer separate index scans is the only lever left on the Postgres side.
- **60 one I/O loop, batch cap 256** (rotated order): `LOOPS=1` 14k 143.1 / 146.5 / 153.8 vs 150.9 / 162.0 / 146.9
  us/req, 12k 153.3 / 148.0 / 153.2 vs 154.9 / 151.0 / 152.3; app lower in every pair (60.5-63.3 vs 63.1-67.0).
  **Not adopted**: one ring at ~23 us/req tops out near 42k req/s, below the ~53k that 8 cores allow at this
  CPU per request, and the score is the most users held with every core busy. `BATCH_MAX=256` 149.0 / 147.4 /
  150.8: noise.
