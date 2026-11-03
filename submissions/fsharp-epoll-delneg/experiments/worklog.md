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
