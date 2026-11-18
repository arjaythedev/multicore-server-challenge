# rust-uring-rishindra2005

Front: direct

A multicore RealWorld (Conduit) server in Rust, with a small C `io_uring` layer and x86-64 assembly kernels for bcrypt and SHA-256. It listens on port 80 itself and talks to PostgreSQL 18 over a hand-written wire-protocol client. There is no async runtime and no web framework.

## Architecture

Requests flow through four kinds of thread, each pinned to its own set of CPUs:

1. **Net reactors** (`src/net`) own the client sockets. They use `io_uring` with multishot accept and recv, provided buffer rings and direct descriptors. An epoll path is kept as a fallback. They parse HTTP/1.1, route the request and hand it to a database driver chosen by connection slot.
2. **Postgres drivers** (`src/plan`) collect the requests that arrive during one loop iteration into a batch. They plan the batch, send it as pipelined extended-protocol messages and render JSON straight from the result rows. All statements are named prepared statements, and the server runs with `plan_cache_mode=force_generic_plan`.
3. **Read, write and feed workers** (`src/pg`, `src/plan`) hold the actual database connections. Slots are spread over them with a multiplicative hash. Hand-off between threads uses single-producer queues and eventfds.
4. **KDF workers** (`src/sec`) run bcrypt (cost 10, as the spec requires) on separate threads. Logins and registrations that arrive within a short window (default 120 ms, `KDF_BATCH_WINDOW_MS`) are hashed together by a 4-lane or 6-lane interleaved Blowfish kernel. Each login still performs a real bcrypt computation.

Within one batch the planner merges work that is naturally shared, for example:

- point lookups of the same kind (user by id, user by email, profile, article by slug, comments) become one statement each;
- global article lists asking for the same limit and offset share one count/page query, and the per-viewer flags come from one extra step;
- several `GET /api/tags` requests in the same batch read one result.

All of this state lives only for the duration of a batch and is discarded afterwards. Nothing is kept across requests: there are no response caches, no query-result caches, no in-memory copies of tables, and no remembered JWTs or password hashes. Every write is committed before its response is sent. The schema is not modified.

### Source layout

| Path | Contents |
| --- | --- |
| `src/net` | `io_uring` and epoll reactors, HTTP parsing, buffer rings, send path |
| `src/plan` | batch planner/executor, write path, feed path |
| `src/pg` | wire protocol client, statement catalogue, row decoding |
| `src/sec` | bcrypt kernels and KDF worker, SHA-256/HMAC, JWT, SCRAM |
| `src/rt` | thread placement, SPSC queues, arenas |
| `build.rs` | generates the router and pre-encoded protocol messages from `SPEC.md` |

## Build

`install.sh` installs a pinned Rust toolchain plus clang/lld on Ubuntu 24.04. `build.sh` then builds with cross-language ThinLTO and profile-guided optimisation, using a short built-in training run (`--train`). If `llvm-bolt` is present it also applies a BOLT layout pass. If any of those optional steps fails, it falls back to a plain `cargo build --release`. The result is recorded in `BUILD_KIND` (`pgo+bolt`, `pgo` or `fallback`).

## Local results (unofficial)

These numbers come from my own test rig, not from the official benchmark box. The challenge was already closed when this work was done, so nothing here is an official score.

Rig: a Docker container limited to 8 CPUs (16 GB) running this server and Postgres 18 together, with the load generator pinned to the other CPUs. A run passes when p95 < 500 ms, p99 < 1000 ms and errors < 1%.

| Build | Users | Throughput | p95 | p99 | Verdict |
| --- | --- | --- | --- | --- | --- |
| `a0feb03` | 115,000 | 30.3k req/s | 79 ms | 235 ms | PASS |
| `a0feb03` | 120,000 | 31.2k req/s | 210 ms | 1.12 s | FAIL (p99) |

On the same rig the then-`#1` entry (`rust-epoll-theCatWisel`) passed 150,000 users, so **this submission does not beat it**. The highest load I could validate for this server is 115,000 users.

The newest commit (`8c0e120`, shared global-list query) measured about 10% faster than `a0feb03` at 125,000 users in an early run. A power policy on the test machine then capped every CPU at 2.0 GHz, which made later runs unusable. Its ceiling has therefore not been measured and is not claimed here.

Unit tests (`cargo test --release`) pass: 87 tests.
