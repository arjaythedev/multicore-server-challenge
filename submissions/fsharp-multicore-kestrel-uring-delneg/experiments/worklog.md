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
