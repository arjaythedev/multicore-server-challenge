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
