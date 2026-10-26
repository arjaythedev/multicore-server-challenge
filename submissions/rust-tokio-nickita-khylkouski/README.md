# Rust / Tokio

Front: direct

Rust 1.99.0, Tokio 1.53.2, tokio-postgres 0.7.18, PostgreSQL 18 and mimalloc 0.1.52. Dependencies are pinned in Cargo.lock.

This is [Scooter1337's MIT-licensed rust-tokio submission (#7)](https://github.com/arjaythedev/multicore-server-challenge/pull/7) with the read path reworked. The HTTP server, JSON, bcrypt, group commit and most SQL are #7's, which builds on [cknutson12's rust-hyper submission (#1)](https://github.com/arjaythedev/multicore-server-challenge/pull/1). Attribution is retained in LICENSE.

## What changed from #7

- **gzip for JSON over 1 KB while the link is busy** (`src/http.rs`), with the challenge's Nginx rule (`gzip_min_length 1024`, level 1), for clients that send `Accept-Encoding: gzip` (the load generator does). On the Boat test boxes the ~32k req/s ceiling turned out to be the network, not PostgreSQL. At that rate the target sent ~115 MB/s (about 1 Gbit/s) with 10% of TCP segments retransmitted, while 16–25% of the CPU sat idle. List pages are ~10 KB and compress 2.7x. Compression is not free, though. At a fixed 10.6k req/s, compressing every eligible response cost 78 µs of app CPU per request against 64 µs without it (PostgreSQL ~147 µs either way). That is ~7% of the box's work, which a CPU-bound box on a faster link would simply lose. So by default the share of eligible responses that get compressed is adjusted every 50 ms. It moves up by 1/16 while the bytes sent in the last window were above 100 MB/s (`HTTP_GZIP_ABOVE_MBS`) and TCP retransmitted at least 0.5% of its segments (`HTTP_GZIP_RETRANS`, per mille, from /proc/net/snmp), and down otherwise. A full link drops segments (10% on the Boat boxes); a CPU-bound box sending the same bytes over a faster link drops none and sends plain JSON. At that same load the default build sent plain JSON and used the same CPU as gzip off. The counters file is opened once at startup and reread. At 200,000 users the service's `LimitNOFILE=200000` leaves no spare descriptors. A fresh open each window then failed with EMFILE, the failure counted as loss, and a box with no retransmits compressed anyway. That cost 0.55 of the 8 cores, at 52.2k req/s with p95 ~125 ms; with the fix the box serves 52.8k and 52.7k at p95 41 and 39, the same as `HTTP_GZIP=0` (52.7k, p95 38–40). With the limit set below the traffic, it compressed only part of the responses. Compression uses libdeflate at level 1 into pooled buffers, about 1.8 µs per KB on the test box's Ryzen 9950X. Higher levels save only ~2% more on this data. ISA-L was 13% faster at level 1 with the same ratio, which is not worth a second native library.
- **A separate runtime for database I/O** (`src/db.rs`, `DB_THREADS`, default 1). Postgres connection drivers and the read/write actors run on their own Tokio worker. On the request workers, a finished round trip waited behind HTTP tasks before the connection sent its next query, which left the backends idle for ~40% of each round trip. On its own runtime, the time a read connection spends on each take halved (~750 → ~340 µs under load). End-to-end probes on these boxes could not separate it from network noise; `DB_THREADS=0` restores #7's layout.
- **One read queue for every read connection** (`src/sched.rs`, idea from #22). #7 assigns a read to a connection when it arrives. Here, reads wait in one queue for each query family. A connection that finishes its round trip takes the oldest waiting family together with the other waiting requests of that family, up to 256 (from #52; #53 went from 64 to 128). No connection sits idle while another has a backlog, and requests that waited together share one SQL execution. At a fixed 200,000 users on one AWS box, a cap of 64 served 49.1k and 49.3k req/s (p95 ~640 ms), 128 served 50.1k and 50.9k, and 256 served 51.5k (p95 229). With the feed count shortcut below, 128 served 51.6k, 256 served 52.1k and 52.2k (p95 128 and 105), and 512 served 52.2k. Going from 64 to 256, statement time per request in `pg_stat_statements` fell 5–6% for the feed and lists and rose 12–13% for comment and single-article reads, so the gain is not cheaper SQL per request. If a connection fails, the jobs it had not started go back into the queue at their original age. There is no collection delay. Jobs hold only the encoded request and its reply channel.
- **More shared SQL** (from #32). As in #7, overlapping global, tag, author and favorited pages compute each distinct count, page and article once per execution. Here, list batches always use that shared form (it was ~14% cheaper per row even with every page distinct), and single-article and comment reads for the same slug share one materialized article/comment set when at least half the batch repeats a slug (`READ_SHARE_LIST_PCT`, `READ_SHARE_UNIQUE_PCT`). Viewer flags (favorited, following) are always per request. In the global list they come from two short index range reads per viewer (favorites within the batch's id window, followees) instead of a probe per (request, article); the list statement went from 3.96 to 1.69 ms for a 64-viewer batch. Global and tag list batches read the tags and favorite counts of all their articles with one grouped index scan each, as the feed does, instead of a subquery per article: tag-list batches got 13–14% faster and global ones 3–5%, both alone and with six concurrent sessions, on a database aged by 15 minutes of load, with identical responses for 2,033 reads. Author lists stay per article, since grouping made them 1–2% slower (`READ_ENRICH_SET`). In two full searches on the same AWS box, the grouped form served more requests at every probe: 39.5k vs 39.1k req/s at 150,000 users, 39.0k vs 38.7k at 200,000, 38.3k vs 37.8k at 180,000 and 38.1k vs 36.7k at 170,000. The followed feed pages every request first, then fills each distinct article once, joining tags against the 200-row tags table and grouping favorite counts (`FEED_BATCH`, 2–5% less backend CPU for the feed in a replay of captured batches, identical results). Each viewer's followee ids are read once for both the count and the page, and a viewer with 1000 or more followed articles is capped by an `EXISTS` on the 1000th (2–3% less per feed batch in pgbench, identical rows over 3,787 requests). Before that walk, the batch's 8 most shared followees (each followed by at least two of its viewers) are checked once each for a 1000th article of their own, and a viewer following one of them is capped at 1000 directly (from #61, which checks 32; `READ_FEED_BIG`). In the seed, 28 authors have 1000 or more articles, and 78,628 of the 83,172 users whose feed reaches the cap follow one of them. Against the plain walk, a 64-viewer batch took 18.2 instead of 20.3 ms and a 32-viewer batch 10.7 instead of 11.5 (checking 4 or 16 followees was the same, 32 was slower), with identical results. At a fixed 200,000 users it served 49.9k and 50.1k req/s against 49.1k and 49.3k with a cap of 64, and 52.1k against 51.5k with 256. Every feed article's author is one of the viewer's followees in the same snapshot, so its `following` flag is true without a lookup (another 4%).
- **Packed batch results** (`READ_PACK`, `src/read_batch.rs` `demux`). A shared list, feed or article batch used to return one full row per (request, article), so an article on 64 viewers' pages crossed the socket 64 times with its title, description, tags and author. Now each distinct article (or comment) comes back once, plus one narrow row per request with its count, its page ids in order and the ids of the articles it favorited and the authors it follows. The app hands each request its header followed by handles to the shared rows (no copies) and sets the flags from those short arrays. For a 64-viewer global page this is 32 kB instead of 526 kB and 1.6 instead of 3.5 ms in PostgreSQL. At 200,000 users (saturated, alternating builds), per-execution time fell 2–13% across the list families and 4% for the feed (together with its new CTEs), and throughput went from 42.8k to 43.7k req/s. Anything unexpected in a packed result (a missing or duplicate header or article) fails the batch over to per-request execution.
- **Within-request order restored by the app** (`READ_APP_SORT`). The rows already arrive grouped by request, so the batched statements have no final `ORDER BY` over the whole batch's wide rows; the app sorts each request's (at most 100) rows by id, or comments by (created_at, id).
- **One read syscall per request instead of two** (`src/http.rs`). #7 waits for readability before taking a buffer, then reads with `try_read_buf`. In Tokio 1.53 only the `poll_read` path clears readiness after a short read, so every socket stayed "readable" after its request and the next loop paid an EAGAIN `recvfrom` and an extra task poll. Reading with `read_buf` after the readiness wait keeps idle sockets bufferless and removes that call (strace on 4,000 keep-alive requests: 12,490 → 8,490 `recvfrom`, 4,000 → 0 errors).
- **Smaller per-response work**: text columns are written to JSON as borrowed bytes without a second UTF-8 check (PostgreSQL validated them; the connection uses `client_encoding=UTF8`), and compressed responses carry no `Vary` header, like the challenge's Nginx (`gzip_vary` is off).
- **Cheaper per-request app code** (same bytes out). JSON strings are escaped in one SSE2 pass that stores each 16-byte block while checking it (`src/json/escape.rs`; a 3 KB list page 1.6 → 0.8 µs). Timestamps are written from a two-digit table (53 → 29 ns). Deciding whether a batch takes the shared form sorts its keys once instead of comparing every pair of frames (256 frames: 48 → 2 µs on the single DB thread). The vendored `tokio-postgres` keeps one column-offset table per result set instead of a `Vec` per row, so the per-request row clones in `demux` no longer allocate, and id arrays are read in place. A JWT payload in exactly the form this server issues is read directly after the signature check; anything else still goes through `serde_json`. At a fixed 230,000 users (alternating builds, same box) the app went from 2.28 to 2.13 cores and the box served 59.9k and 59.9k req/s at p95 152 and 189 ms against 59.4k and 59.2k at p95 237 and 257.
- **Viewer flags read once per list, author names resolved once** (`READ_LIST_FLAGS`, `READ_AUTHOR_KEY`). In packed global lists each distinct viewer's favorites and followees are read once per batch, and tag lists read flags with one `= ANY(page)` read per request instead of one probe per article. Author lists resolve each distinct name once and page and count by id. Offline on an aged copy of the lab database: global 2.76 → 1.54 ms (96 viewers), tag 3.46 → 3.26 ms, author 2.80 → 2.54 ms, with identical rows. Together with the item above: 60.3k and 60.2k req/s at p95 108 and 112 ms against 59.5k at p95 236, and the same bytes as before for 2,033 reads.
- **Three Tokio workers on eight CPUs** instead of two (`APP_THREADS` default `3 × cores / 8`). With the shared queue, the extra worker keeps HTTP parsing and JSON from becoming the tail-latency bottleneck once PostgreSQL saturates the box.
- **Stale password jobs are skipped** (`src/password_batch.rs`, `BCRYPT_SHED_MS`, default 8000). The one bcrypt worker finishes about 45 logins/s while PostgreSQL keeps the other cores busy. At a fixed 200,000 users the load asks for 54/s, so the queue grew without bound. Every login then waited past the load generator's 10 s timeout, and the worker went on hashing passwords for clients that had already given up: 61% of logins failed, and 0.04–0.07% of reads also timed out. Now a job that has waited 8 s without starting gets a 503 at once, and the worker takes the next one. In two runs, login failures fell to 24–25% (all fast 503s), read timeouts went to zero and total errors fell from 0.10% to 0.03%, at 52.2k and 52.3k req/s and p95 121 and 114 ms. A second bcrypt worker (`BCRYPT_THREADS=2`) served every login but took ~0.4 core from PostgreSQL: 51.4k req/s, p95 314.

Every request still reads PostgreSQL. Each SQL execution takes one READ COMMITTED snapshot, and responses wait for ReadyForQuery. No result, token or password is retained across requests. Writes keep #7's durable group commit: responses are released only after COMMIT.

## Inherited from #7

- Direct HTTP/1.1 using httparse:
  - fixed-capacity buffer free lists and separate 1 KiB request buffers;
  - stack response headers and vectored writes;
  - buffers released while sockets are idle;
  - bounded read completion after the first request byte.
- Prepared generic plans and separate read/write connections. Failed connections and their statements are replaced together, without replaying requests. Global and tag pages compute exact favorite counts and viewer membership in one index scan. Capped tag counts avoid aggregation when the cap is proven.
- Durable group commit. Failed batches roll back and retry their requests individually, so one invalid registration cannot reject another write. Uncertain commits are never retried.
- Borrowed PostgreSQL text arrays, direct JSON serialization and SSE2 string escaping on x86-64. Fat LTO and one codegen unit.
- Bounded bcrypt work using the Openwall/libxcrypt 4.4.36 core, cost 10, with fresh random salts. Up to five independent hashes are interleaved here (four in #7; each lane's S-boxes take 4 KB of the 32 KB L1 data cache, and more lanes were no faster). Startup checks compare the interleaved paths against the original core. The native source and its license are documented in native/README.md.

No schema/config changes, CPU affinity or host tuning.

## Settings

On eight CPUs the defaults are:
- three Tokio workers;
- six read connections sharing one queue;
- two grouped write connections;
- one database I/O worker;
- one bcrypt worker;
- gzip for clients that accept it, while more than 100 MB/s is being sent over a link that drops segments.

Optional process settings:
- `APP_THREADS`, `DB_CONNS`, `DB_WRITE_CONNS`, `BCRYPT_THREADS`, `WRITE_BATCH_US`, `BCRYPT_BATCH_MS`, `BCRYPT_SHED_MS`;
- `DB_THREADS`: database I/O workers, default 1; 0 runs database I/O on the request workers;
- `HTTP_GZIP=0`: never compress responses; `HTTP_GZIP=1`: compress every eligible response;
- `HTTP_GZIP_ABOVE_MBS`: the egress rate above which compression starts, default 100 (MB/s);
- `READ_BATCH_SIZE`: group cap, default 256 (32 with `READ_SCHED=0`); 0 disables read batching;
- `READ_SCHED=0`: go back to #7's per-connection routing;
- `READ_SCHED_MODE=mixed`: let one take fill its cap across families;
- `READ_FEED_CAP`: group cap for feed reads, default the group cap;
- `READ_FEED_BIG=0`: walk every feed request's followed articles for its count, without the shared-followee check;
- `READ_PACK=0`: one full row per (request, article) in shared batches;
- `READ_APP_SORT=0`: order batched rows in SQL;
- `READ_FLAG_ARRAYS=0`: per-row `EXISTS` flags in the unpacked shared global list;
- `READ_LIST_FLAGS=0`: per-(request, article) flags in packed global and tag lists, instead of per-viewer arrays read once per batch (global) and one `= ANY(page)` read per request (tag);
- `READ_AUTHOR_KEY=0`: shared author lists join `users` by name per page and count and by id per article, instead of resolving each author once;
- `READ_SHARE_LIST_PCT` (default 100) and `READ_SHARE_UNIQUE_PCT` (default 50): the largest share of distinct non-viewer keys at which a list or slug batch still uses the shared form;
- `READ_ENRICH_SET=0`: per-article tag and favorite-count subqueries in every shared list; `=1` groups the author and favorited lists too;
- `READ_FOLLOWEE_LIST=0`: one `follows` probe per comment instead of the viewer's followee ids;
- `HTTP_GZIP_RETRANS`: retransmit rate in per mille that marks the link as full, default 5; 0 uses the byte rate alone;
- `PG_PARALLEL=1`: keep the server's parallel-worker setting (by default the sessions set `max_parallel_workers_per_gather = 0`);
- `BATCH_STATS=1`: print coalescing counters, queue wait and read-connection idle time every 10 s;
- #7's `READ_TAG_ROUTE`, `READ_COMMENT_SET` and `READ_TAG_BATCH`, all 1 in start.sh.

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Measurements

These are not official scores.

On AWS (us-west-2): a c7i.2xlarge target (4 cores / 8 threads, Xeon 8488C, 15.7 GB, Ubuntu 24.04, PostgreSQL 18, set up with the repo's `box/setup-box.sh`, seed and `score/` tools, four addresses as in the official setup), loaded from one c7i.4xlarge in the same zone (never above 64% CPU). Full `conduit-loadgen search` runs, fresh database each:

| build | score | hold req/s | hold p95 / p99 (ms) | target CPU over the hold (harness monitor) |
|---|---|---|---|---|
| this submission, run 1 | **170,000** | 41,913 | 402 / 436 | 95% (app 25% / db 69%) |
| this submission, run 2 | **170,000** | 41,829 | 500 / 553 | |
| #7 (rust-tokio-Scooter1337) | 120,000 | 31,659 | 82 / 155 | 89% (app 19% / db 69%) |

This submission passed 150,000 (p95 18 and 17) and 170,000 (p95 336 and 251) and failed 180,000 (p95 712 and 524) and 190,000 (p95 641 and 642); the second hold passed with p95 499.7, right at the limit, so 170,000 is this build's edge on this box. #7 passed 120,000 (p95 14) and failed 128,000 (p95 713). Near its limit this box switches between two regimes: the same build at a fixed load shows p95 ~15 ms with small read batches or 200–600 ms with large ones (a fixed 190,000-user run of an earlier build passed at 47,950 req/s, p95 463). At 200,000 users the service's `LimitNOFILE=200000` is a few files short of one connection per user, so some `accept` calls fail with EMFILE throughout the run; the faster box below still passed there.

A second c7i.2xlarge target, set up the same way, landed on a faster host: the 170,000 build above served 49.1k and 49.3k req/s at a fixed 200,000 users there. Full searches on it, with `-start 150000 -max 200000` (`-start 120000` for #7) and the build at each stage:

| build | score | hold req/s | hold p95 / p99 (ms) | errors | target CPU over the hold |
|---|---|---|---|---|---|
| the 170,000 build above | 180,000 | 44,028 | 472 / 523 | 0.09% | 94% (app 25% / db 68%) |
| + read cap 256 and the feed shortcut, run 1 | **200,000** | 49,883 | 340 / 431 | 0.39% | 97% (app 32% / db 65%) |
| + read cap 256 and the feed shortcut, run 2 | **200,000** | 49,598 | 381 / 473 | 0.38% | |
| + login shedding and the gzip fix (this submission) | **200,000** | 51,734 | 190 / 253 | 0.03% | 96% (app 27% / db 68%) |
| #7 (rust-tokio-Scooter1337) | 130,000 | 32,319 | 495 / 625 | 0% | 91% (app 21% / db 70%) |

#7 passed 130,000 (p95 423) and failed 140,000 (p95 973) at ~32.3k req/s. The 170,000 build passed 180,000 (p95 289) and failed 190,000 (p95 601) and 200,000 (p95 786). The later builds passed their 200,000 probes at p95 210, 209 and 119. 200,000 is the top of these searches, and also where `LimitNOFILE` runs out. In the last hold, 23% of logins got the fast 503 and the other errors were 432 timeouts out of 15.5 million requests.

`conduit-loadgen search` doesn't reset the database between phases. By the hold, the probes before it have added ~100,000 articles and hundreds of thousands of favorites and comments, and cleared most of the visibility map, so every read costs more than on a fresh copy. A single 14-minute run at 175,000 users on one aging database passed at 44,752 req/s, p95 356 / p99 393, 0.10% errors. The batch size grew as it aged: feed batches went from ~32 to ~55 requests, and total feed backend CPU still rose from 2.33 to 2.58 cores. With the grouped list enrichment, a fresh 190,000-user fixed run passed at 49,721 req/s, p95 178 / p99 217. That run isn't a full search.

The Boat measurements below came first. They were run with the challenge's own `conduit-loadgen search` and `score/` tools (`switch.sh` gives a fresh database per run) on Boat sandboxes:
- target: 8 vCPU / 16 GB, Ubuntu 24.04, PostgreSQL 18 on the same box;
- load: three 16-vCPU load boxes, never above 45% CPU.

Full `conduit-loadgen search` with gzip on every eligible response (before the egress rule), on the same 0%-steal target box as the searches further down:

| build | score | hold req/s | hold p95 / p99 (ms) | target CPU |
|---|---|---|---|---|
| this submission | **160,000** | 41,848 | 345 / 548 | 88% busy |

The search passed 140,000 (p95 361) and 160,000 (p95 441) and failed 170,000 (p95 851). A later build (with the read and JSON changes above, gzip still on every eligible response) scored 160,000 again on a freshly resumed target: probe p95 214 / p99 621, hold 41,205 req/s at p95 451 / p99 666. It also passed a 2-minute 170,000 probe (44,792 req/s, p95 193), but its 170,000 hold failed (p95 618) on stalls every 65–70 s. Those stalls came from the sandbox's own snapshot agent, which took 2–3 of the 8 cores each time while it archived Postgres's changed files. With that agent paused, the median per-second p95 of the 160,000 hold was 95 ms. The two limits now arrive together: the CPU is ~88% busy (PostgreSQL ~63% of it, with ~16% of all CPU spent pinning and locking shared buffers), and in an earlier 180,000-user probe the target sent 108 MB/s with 12% of segments retransmitted.

Without gzip, the box topped out near 31–33k req/s for every configuration tried. That ceiling was the network (see gzip above), and the difference between builds was in how latency held up near it. The results below are from that build, before gzip and the database runtime.

Probes at 120,000 users after a warmup, alternating variants on one set of boxes:

| build | passed | probe p95 (ms) |
|---|---|---|
| this submission | 5 / 5 | 171, 218, 253, 343, 386 |
| #7 as submitted | 1 / 5 | 362; failures 716–1869 |
| #7 with `APP_THREADS=3` | 2 / 3 | 323, 407; failure 600 |
| this submission with `READ_SCHED=0` | 0 / 3 | 686–1920 |

Full `conduit-loadgen search` runs (start 110,000, bisect, 5-minute hold) on a second target box (0% CPU steal) with the same load boxes, alternating order:

| build | run | score | hold req/s | hold p95 / p99 (ms) | 120,000-user probe p95 / p99 (ms) |
|---|---|---|---|---|---|
| this submission | 1 | **120,000** | 31,182 | 337 / 655 | 400 / 784 pass |
| #7 | 1 | 110,000 | 28,879 | 141 / 397 | 485 / 1,070 fail |
| #7 | 2 | 110,000 | 28,752 | 249 / 690 | 540 / 1,322 fail |
| this submission | 2 | **120,000** | 31,224 | 324 / 634 | 354 / 767 pass |

Neither build passes 130,000 users (p95 ≈ 0.8–1 s at ~32k req/s).

Tried and dropped:
- feed counts capped with `EXISTS (… OFFSET 999 LIMIT 1)` over a fresh followee subquery, as the tag count is (+12% feed backend CPU, interleaved replay; the kept form reuses one followee array), summed per-followee capped counts (+56%), and the count and page read in one pass over each followee's articles (+48–81%);
- favorite counts without heap fetches: PostgreSQL 18 dropped the bitmap scan's skip-fetch, and every exact rewrite was slower;
- comments always shared: batches rarely repeat a slug, and the shared form cost 16.7 ms per execution against 6.7 unshared. In 2 s of logged statements at 170,000 users, 99% of the slugs in each comment and article batch were distinct;
- feed pages read once per distinct followee in the batch and merged per viewer: 23.5 vs 18.9 ms for a 64-viewer batch. Only ~20% of (viewer, followee) pairs in a 64-viewer batch repeat a followee, and the planner hashed each viewer's followees and scanned the shared list again for every viewer;
- a smaller cap for feed batches under the 256 cap (64: 51.5k vs 52.1k and 52.2k req/s at 200,000 users);
- `enable_memoize = off` (several PRs): 49.0k vs 49.1k and 49.3k req/s at 200,000 users;
- one capped walk for the feed count, `count(*)` over the first 1000 followed articles, instead of the `EXISTS` and then a full count (several PRs): 17.9 vs 17.65 ms for a 64-viewer batch, identical rows;
- 8 or 5 read connections with the 256 cap: 52.2k and 51.8k req/s against 52.2k and 52.3k with 6 at 200,000 users;
- a second bcrypt worker (above);
- feed pages for viewers who follow a big author read as that author's top rows plus one `= ANY` scan of the other followees above the big author's last page id (PostgreSQL 17 can stay on a leaf between array keys): 18.2 vs 18.8 ms for 64 viewers and 32.8 vs 32.5 for 128, since the scan still positions once per followee;
- `APP_THREADS` 2 or 4: the same CPU and p95 as 3 at 200,000 users;
- flag arrays in the tag list's wide rows (16.1 vs 13.0 ms for a 64-viewer batch): its pages spread over too many ids and authors;
- inline assembly, unrolling or `-march` for bcrypt. BMI2 assembly rounds hashed 9.5% faster with PostgreSQL on the hyperthread sibling but took 2.8% of that backend's work. At 230,000 users the box served the same requests (60.3k and 60.2k vs 60.4k and 60.3k req/s) and only 2% more logins, since one worker hashes all the time either way;
- a feed built in the app: one walk per distinct followee in the batch, a merge in Rust, then enrichment for the page ids only. It returned identical pages but was only 0–8% faster (32–128 viewers), because 85–90% of a batch's followees are followed by one of its viewers;
- comment and single-article variants (output trimmed, authors joined once per batch, tags grouped per batch): within ±5%;
- one Sync for several statements (one implicit transaction): pgbench shows ~3 µs less backend CPU per statement, but a read statement already serves ~13 requests here, so it would save ~0.4%;
- two pipelined read groups per connection, which lowered coalescing and raised PostgreSQL CPU per request;
- 4, 5 and 10 read connections;
- four Tokio workers;
- mixed-family takes, which gave no measurable difference;
- feed variants that drop the always-true `following` flag or restructure the favorite lookups, which also gave no measurable difference;
- feed and list enrichment through `= ANY(array)` lookups instead of per-row index probes: 15–35% fewer buffer hits, but 20–40% more backend CPU with six concurrent backends on Boat (re-measured on AWS, the grouped scans won for the global and tag lists and are kept there);
- comment authors read with one sorted `= ANY(array)` users lookup per batch and each slug's comments read once: identical rows, but 40% slower (0.84 vs 0.57 ms for 6 requests, 2.2 vs 1.5 ms for 16) on an aged database. Index descents fell from 503 to 223, but buffer hits barely moved (1,459 vs 1,509), because each author is on its own heap page;
- walking the feed's capped count oldest-first (fewer heap fetches cold, no difference warm);
- 5 or 7 read connections on AWS: two 200,000-user runs of the same build gave 43.7k and 48.2k req/s, so the difference was not measurable;
- 4, 6 or 8 read connections replayed against PostgreSQL alone: backend CPU per request rises only ~20% from one to six backends, so fewer connections do not pay for the lost parallelism;
- gzip levels above 1 (~2% smaller) and ISA-L (13% faster at level 1, same ratio);
- compressing responses under 1 KB (one TCP segment either way).

## Validation

- All 197 unchanged conformance checks on the full seed (`test/run.sh`), with the default settings and with `READ_SCHED=0`.
- Release unit tests (including the queue's age order and requeue) and Clippy.
- A batching equivalence test: about 2,000 distinct reads (lists, tags, authors, favorites, feeds, articles, comments, profiles; anonymous and 40 viewers) answered one at a time must be byte-identical to the same reads answered six times each from 96 concurrent connections. 0 mismatches, also with `DB_CONNS=1`, which forces the largest groups, and over 20,000 requests from 300 connections with `READ_SHARE_UNIQUE_PCT=100`, where every family ran packed hundreds of times.
- Write checks under concurrency:
  - 64 users favorite and unfavorite one article: counts stay in range and the final count matches the database;
  - read-after-write on a second connection for create, comment, follow/feed and delete;
  - 16 concurrent registrations of one name produce one 201;
  - mixed success/failure registration batches stay isolated;
  - 200 clients hang up mid-request.
