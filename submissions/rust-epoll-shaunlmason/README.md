# rust-epoll-shaunlmason

Front: direct

Rust, no async runtime and no framework: raw epoll for HTTP, an own blocking PostgreSQL wire client, and every
read batched across request kinds so Postgres does as little work per request as possible.

| Part | What |
|---|---|
| HTTP | `epoll`, one thread per `SO_REUSEPORT` listener (cores / 4), keep-alive, pipelining, chunked bodies |
| Postgres | own v3 protocol client: SCRAM-SHA-256, named prepared statements, binary in/out, one Sync per batch |
| bcrypt | own implementation, cost 10, several hashes in lockstep; verified against the `bcrypt` crate in tests |
| JWT | HS256 with `hmac`/`sha2`, signature and `exp` checked on every request |

## Design

**Reads** queue up while a read lane is busy. The next free lane (one Postgres connection each, `READ_LANES`)
takes everything that queued during its gather window and answers it with two pipelines:

- *phase A* – one statement per kind over the batch's distinct keys (`unnest(...) WITH ORDINALITY`): users,
  profiles, articles by slug or id, comments, and the pages of every list (global, tag, author, favorited, feed).
- *phase B* – what phase A left open: counts, then once per distinct article its tag ids, favorite count and
  author, the names of all those tags, and the viewer flags (favorited, following) for every pair asked about.

A list page that ends short already tells its count (offset + rows), so phase B only counts lists whose page was
full: short author, favorited and tag lists need no count query at all.

**Writes** go through one lane in group commit: everything queued becomes one transaction, committed before any
reply is sent. Each write is a single statement (data-modifying CTEs). If any statement fails, the group is rolled
back and each write retried on its own, so one user's unique violation can't fail the others. A write whose
commit outcome is unknown (lost connection) answers 500 and is never retried.

**Every request is answered.** A request's reply handle answers 500 by itself if it's dropped unanswered (a lost
database connection mid-batch, a bug), so no client waits for its timeout.

**bcrypt** runs on its own threads, `bcrypt::LANES` (6) independent hashes interleaved round by round: one
bcrypt is a long chain of dependent S-box loads, and interleaving lets a core overlap them. Every hash still runs
all 2^10 rounds. Worker 0 waits up to `BCRYPT_WINDOW_MS` to fill its lanes; the others take only full sets.

No caching across requests: every response is computed from the database by statements that run after the
request arrived.

## Ideas taken from other submissions

Written from scratch, but several ideas come from reading the current leaders:

- **rust-epoll-WorriedArrow**: the overall shape (cross-kind batched read lanes in two phases, a group-commit
  write lane, lockstep bcrypt with one gathering worker), tag ids plus one tag-name lookup, viewer flags via
  `= ANY` per viewer, the capped-count form (`EXISTS ... OFFSET 999`), counting the global list from the oldest
  end of the primary key, and the session settings below.
- **zig-fourneau-y2kbugger** and the C++ entries: ids-first pages, and knowing a short page's count without
  counting.

## Configuration

| Variable | Default | |
|---|---|---|
| `DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT` | | as the rules say (`PORT` defaults to 80) |
| `IO_THREADS` | cores / 4 | epoll threads |
| `READ_LANES` | cores / 2 | read lanes (one Postgres connection each); fewer, larger batches measured cheaper |
| `READ_WINDOW_US` | 20000 | how long a lane gathers a read batch |
| `READ_MAX`, `WRITE_MAX` | 4096, 256 | batch size caps |
| `BCRYPT_THREADS` | 2 | bcrypt threads |
| `BCRYPT_WINDOW_MS` | 400 | how long the first bcrypt thread waits to fill its lanes |

Session settings (startup parameters on its own connections only): `plan_cache_mode=force_generic_plan` (the
batch statements take arrays and would otherwise be re-planned every time), `jit=off`,
`max_parallel_workers_per_gather=0`, `enable_memoize=off` (batched comment lookups hit almost no cache entries).

## Build and run

`install.sh` (root, once) installs Rust 1.99.0. `build.sh` builds `target/release/conduit` with the pinned
`Cargo.lock`; `start.sh` runs it. `cargo test --release` runs the unit tests (bcrypt, JWT, JSON, chunked bodies).
