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

Tests: `cargo test --lib` (unit tests), `cargo test --lib -- --ignored` (needs a local Postgres with the dev seed), and
`tools/difftest` (random requests against the reference example servers, see its README).
