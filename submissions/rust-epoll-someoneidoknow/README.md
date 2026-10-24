# Rust, raw epoll

Front: direct

| | |
|---|---|
| Language | Rust 1.99.0 (rustup, pinned in `install.sh`), edition 2024 |
| HTTP | Own HTTP/1.1 server on raw `epoll` via `libc` 0.2.191; no async runtime |
| Postgres | Own wire-protocol client: SCRAM-SHA-256, prepared statements, pipelining, binary format |
| JSON | Responses written by hand from Postgres rows; `serde_json` 1.0.154 for request bodies |
| JWT, crypto | HS256 and SCRAM via `ring` 0.17.14 |
| bcrypt | Own 4-lane interleaved implementation, checked bit-exact against `bcrypt` 0.19.3 in tests |
| Allocator | `mimalloc` 0.1.52 |

All versions are pinned in `Cargo.toml` and `Cargo.lock`.

## Design

Postgres uses most of the box's CPU, so most of the work goes into spending less Postgres time per
request.

- **Event loops.** One thread per 4 CPUs, each with its own `SO_REUSEPORT` listener, epoll instance
  and Postgres connections. Nothing is shared on the request path. An idle keep-alive connection
  holds no buffers.
- **Read coalescing.** Reads of the same kind wait up to 20 ms in a per-kind queue, then go out
  as one statement: the request parameters become arrays, and the query runs once per request
  inside `unnest(...) CROSS JOIN LATERAL`. Each row is tagged with its request's position.
- **Shared work inside a batch.** List, article and comment batches compute each distinct page,
  capped count, comment thread and article metadata (tags, favorite count, author) once per
  statement. Viewer-specific fields (`favorited`, `following`) are still computed per request.
- **Group commit.** Writes wait up to 10 ms and commit together in one transaction, so many
  requests share one WAL flush. Every response is sent only after its commit. If a batch fails,
  each request in it is retried alone. Sign-ups, user updates and article creates never share
  a batch.
- **One round trip per request.** Lists return the page and the capped count in one statement.
  Follow, unfollow, deletes and updates fold their lookup and ownership check into one statement.
- **Cheaper SQL.** Pages pick their ids before any per-row work, so `OFFSET` rows cost one index
  step. Tag names are looked up by primary key. The global and tag counts check for a 1000th row
  before counting. Session settings: `plan_cache_mode = force_generic_plan`, `jit = off`,
  `max_parallel_workers_per_gather = 0`.
- **bcrypt.** One hash is a chain of dependent table lookups, so 4 hashes run interleaved in one
  thread. A lone login waits up to 100 ms for others to fill the batch.