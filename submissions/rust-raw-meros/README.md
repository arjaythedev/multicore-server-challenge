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
and is rendered into the response without copies.

## Build and run

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional tuning variables (defaults are for 8 vCPUs): `IO_THREADS`, `READ_LANES`, `WRITE_LANES`, `READ_WINDOW_US`,
`READ_BATCH_MAX`, `WRITE_WINDOW_US`, `WRITE_BATCH_MAX`, `BCRYPT_THREADS`, `BCRYPT_WINDOW_US`.

Tests: `cargo test --lib` (unit tests) and `cargo test --lib -- --ignored --test-threads=1` (live tests against a local
Postgres with the dev seed; the Postgres client tests need `CREATE DATABASE pg_agent_test TEMPLATE conduit_dev OWNER
conduit` or `PG_TEST_URL`). `tools/difftest` sends random requests to this server and to a reference example server and
compares the answers (see its README).

## Measurements (local, not the benchmark box)

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

Not measured: the benchmark box, more than 60,000 simultaneous users, the effect of the window and lane counts at
33,000 requests per second.
