# Rust: Tokio — kamkmgamer

**Front: direct**

Rust/Tokio Conduit server tuned for the multicore challenge. It uses a hand-written HTTP/1.1 front end, a
pipelined PostgreSQL client, direct JSON serialization, mimalloc, and native batched bcrypt.

## Stack

| Piece | Version |
|---|---|
| Rust | 1.99.0 (`install.sh`) |
| Runtime | Tokio 1.53.2 |
| HTTP | httparse 1.10.1 + direct Tokio sockets |
| PostgreSQL driver | vendored tokio-postgres 0.7.18 |
| JSON | hand-written responses; serde_json 1.0.154 for request bodies and fallback claims |
| JWT | HS256 with hmac 0.12 + sha2 0.10 + base64 0.22 |
| Passwords | native Openwall-compatible bcrypt, cost 10 |
| Allocator | mimalloc 0.1.52 |

Dependencies are pinned in `Cargo.lock`. Release builds use fat LTO, one codegen unit, panic abort, a stripped
binary, and `-C target-cpu=native`; the native bcrypt C backend receives matching `-march=native` and
`-mtune=native` flags.

## Shape

```text
Tokio runtime
├── direct HTTP/1.1 connection tasks
├── read pool: prepared binary PostgreSQL statements
├── write pool: durable grouped commits
└── bounded native bcrypt workers
```

On the challenge's eight-core box, the defaults are two Tokio workers, six read connections, two write
connections, and one bcrypt worker. `APP_THREADS`, `DB_CONNS`, `DB_WRITE_CONNS`, `BCRYPT_THREADS`,
`BCRYPT_BATCH_MS`, `WRITE_BATCH_US`, `READ_BATCH_SIZE`, `READ_BATCH_US`, and `READ_SQL_BATCH` remain configurable.

## Optimizations

- Direct HTTP/1.1 avoids the Nginx hop. Request and response buffers use thread-local free lists, stack response
  headers, vectored writes, and keep-alive connections without idle buffer retention.
- Prepared binary PostgreSQL statements use separate read/write pools, least-load routing, compatible read
  grouping, array-parameterized LATERAL batches, and durable grouped commits. No query result is retained between
  requests.
- Compatible `/api/comments` reads are packed into one prepared `unnest` execution with request ordinals, then
  demultiplexed back to each response. The query preserves per-article comment order and still returns a 404 for an
  unknown article.
- Favorite and unfavorite now mutate the join table and return the updated article from one durable SQL statement;
  the count adjustment reflects whether the CTE actually inserted or deleted a row.
- Responses are serialized directly into reusable buffers. PostgreSQL timestamps and text arrays are read from
  binary values, and JSON escaping uses an x86-64 SIMD fast path.
- Canonical load-generator JWTs use a strict allocation-free claims parser after signature verification. Reordered,
  escaped, fractional, or `nbf` claims use the complete JSON validation path. Query and header integers use one
  checked scan.
- Bcrypt remains cost 10 for every hash and verification, but independent jobs are interleaved through the native
  implementation so login bursts do not stall the Tokio workers.

## Rules

Every request reads PostgreSQL while it is served. There are no response, row, password, or token-verification
caches. Writes wait for a durable commit before the response. Every token's HS256 signature, algorithm, expiry,
and optional `nbf` are checked on every request.

## Build and run

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```

## Validation

- `cargo fmt --check`
- `cargo test --release --locked`: 13 passed, 2 ignored
- Fresh PostgreSQL 18 dev seed: all 197 conformance checks passed

The local accelerated load probe passed at 3,000 users (p95 182 ms, p99 327 ms, zero errors), but the host was
load-generator limited and shared with unrelated workloads; it is not an official leaderboard score.

## Attribution and changes

This submission is derived from [PR #7](https://github.com/arjaythedev/multicore-server-challenge/pull/7) by [@Scooter1337](https://github.com/Scooter1337), using submissions/rust-tokio-Scooter1337 as its base. Most of the existing source, native code, vendored dependencies, lockfile, and launcher are retained from that entry; credit for the original implementation belongs to Scooter1337.

Our changes are:

- add the direct Tokio HTTP/PostgreSQL implementation and its grouped read and durable grouped-write paths;
- add SIMD JSON serialization, mimalloc, and native batched bcrypt;
- add the strict allocation-free canonical load-generator JWT fast path, complete JSON-validation fallback, and checked single-pass integer parsing;
- pin the toolchain and dependencies and provide the native CPU/LTO release build and validation scripts.

This is an optimized derivative of #7, not an unrelated Rust implementation.
