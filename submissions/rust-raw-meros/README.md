# Rust, std only

Front: direct

A Conduit server written for this one challenge: Rust 1.99 with the standard library and **no third-party crate**.
HTTP/1.1, JSON, the Postgres wire protocol (SCRAM-SHA-256, pipelined extended protocol, binary codecs), SHA-256 / HMAC /
PBKDF2, HS256 JWT and bcrypt are all written here, and only as general as this workload needs. The design, the module
map and the rules compliance are in [DESIGN.md](DESIGN.md).

Short version: Postgres uses most of the box's CPU, so reads wait up to 30 ms in a queue and run as big batches (one
statement per kind, `unnest` of the requests' parameters, identical pages and articles computed once and shared by
borrow inside the batch). Writes run as group commits (one transaction, responses after the commit). Passwords are
hashed with up to six bcrypt computations interleaved on one thread. A request buffer is read once, moves into the job
and is rendered into the response without copies. Read requests queue per kind, and a lane runs one kind alone, so a statement
carries every request of its kind that has accumulated. Bcrypt runs in the idle scheduling class and sheds logins that waited
more than 8 s (see DESIGN.md).

## Build and run

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional tuning variables (defaults are for 8 vCPUs): `IO_THREADS`, `READ_LANES`, `WRITE_LANES`, `READ_WINDOW_US`,
`READ_BATCH_MAX`, `WRITE_WINDOW_US`, `WRITE_BATCH_MAX`, `BCRYPT_THREADS`, `BCRYPT_WINDOW_US`, `STATS_SECONDS` (print read-lane counters every N seconds; 0 = off).

Tests: `cargo test --lib` (unit tests) and `cargo test --lib -- --ignored --test-threads=1` (live tests against a local
Postgres with the dev seed; the Postgres client tests need `CREATE DATABASE pg_agent_test TEMPLATE conduit_dev OWNER
conduit` or `PG_TEST_URL`). `tools/difftest` sends random requests to this server and to a reference example server and
compares the answers (see its README).

## Measurements

### On a copy of the benchmark setup (GCP, europe-west4)

One n2-standard-8 box for the server and Postgres 18 (8 vCPU, 16 GB, Ubuntu with kernel 6.8), two load generator boxes, the
official `conduit-loadgen` and the scoring scripts. To check the rig, the current number 1 on the leaderboard
(asm-epoll-nickita-khylkouski) scored 130,000 users on it, the same as its leaderboard entry.

| Version | Result on the rig |
|---|---|
| first version of this PR | 110,000 users held for 5 minutes (120,000 failed on p95 544 ms) |
| set-based tag and favorite enrichment, feed shortcut | 110,000 (a 120,000 one-minute probe passed, the hold failed on p95 650 ms) |
| per-kind read queues, bcrypt in `SCHED_IDLE`, no quadratic page scan | a 128,000 probe passed with p95 112 ms and 0.04% errors; a 135,000 run of 90 s had p95 96 ms and 14% idle CPU. The 5-minute hold was not run. |

The version in this PR also batches writes per kind and shares the feed work per followee. It was verified locally (below)
and **has not been run on the rig**. Its score is unknown. The 135,000 numbers above were taken on a freshly created
database; the official run ages the database for several minutes first.

Overload behaviour, tested on the rig with 256,000 users (twice the capacity): the server stays up, answers 503 beyond the
queue limits, and the next run at 100,000 users after it had p95 85 ms and 0.01% errors. An earlier version stopped
accepting connections for good once it ran out of file descriptors; the io thread now retries `accept` every 20 ms.

### On one laptop (not the benchmark box)

Everything below ran on one laptop (Core Ultra 7 258V), the server and Postgres pinned to 2 P-cores and the load
generator on 6 other cores, full seed. They compare builds against each other; they are not scores.

- Conformance: 197/197 on the dev seed and on the full seed.
- Differential test against the Go reference server, same data: 20,000 random reads and 6,000 mixed writes; every
  difference is an unspecified edge case (status for paths Go's mux rewrites, `%00`/`%FF` in paths, an `exp` claim
  written as a string or float, offsets beyond 2^63).
- Postgres CPU per request on a mixed batch of 64 (`cargo test --release --lib read::bench -- --ignored`): 35.6 us,
  against 78.8 us for the SPEC's reference statements run one request at a time.
- Closed-loop load (`loadgen`, think time scaled by 0.2), same 2 cores, p95 under 500 ms: this server holds about 22,000
  users; the rust-tokio-meros base with the same 30 ms read window and batches of 512 holds about 19,000. At 14,000 users
  the new server uses 16% less CPU (Postgres 18% less, the non-bcrypt app side 45% less).
- A batching window of 10 to 80 ms cut Postgres CPU by 17% at the same request rate, window plus batches of 256 to
  512 by 39% (base server, 15,000 requests per second); the p95 rose from 12 ms to 34 to 60 ms.
- Killing all Postgres connections under load: the lanes reconnect, 0.28% of requests failed during the event.

- Set-based enrichment and feed changes, closed loop at 22,000 users (3 runs each): Postgres CPU 5,944 to 6,265 ticks
  against 6,241 to 6,380 for the version before the feed change; the p95 differs less than the noise between runs.
- Backend CPU per feed request, 2-phase feed against the single statement (`read::bench`): 143 to 141 us at batch 16,
  104 to 96 us at 128, 88 to 69 us at 512.
- Backend CPU per write in a group (`write::bench_tests`): favorite 111 to 20 us at 16 and 107 to 10 us at 128;
  comment 16 to 10 us and 16 to 6.5 us. The favorite figures are best cases: the benchmark favorites one article from
  many users, so the count is computed once per group.

Not measured: the final version on the rig, more than 135,000 users, the share of writes that stay in long enough
segments for the batching to apply under the real traffic mix.
