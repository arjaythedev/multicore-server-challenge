# Rust · hyper · tokio-postgres (thread-per-core)

Front: direct

| | |
| --- | --- |
| Language | Rust 1.99.1 (official tarball, installed by `install.sh`) |
| HTTP | `hyper` 1.x (HTTP/1.1 keep-alive) + `hyper-util`, hand-written router |
| Runtime | `tokio` 1.x, one single-threaded runtime per worker thread |
| Postgres driver | `tokio-postgres` 0.7.x (no pool crate), `NoTls` |
| Other crates | `bcrypt` 0.15 (cost 10), `hmac` + `sha2` (HS256), `base64`, `serde_json` (request bodies only), `socket2`, `mimalloc` |
| Exact versions | pinned by `Cargo.lock`; `build.sh` uses `--locked` |

## What it does differently, and why

**Serves the internet directly (no Nginx).** Saves the CPU Nginx would use. Every virtual user's keep-alive
connection lives in this process; idle connections are never closed by the server.

**Thread per core, shared nothing.** `APP_THREADS` single-threaded tokio runtimes (default `max(2, cores/2)`),
each with its own `SO_REUSEPORT` listener and its own Postgres connections. A request is parsed, queried and
answered on the same thread: no work stealing, no cross-thread wake-ups, no locks on the request path. The app
needs little CPU; the rest of the box is left to Postgres.

**Few Postgres connections, pipelined.** `DB_CONNS_PER_THREAD` (default 4) connections per thread, so about 16
backends in total on 8 cores (the limit is 95). `tokio-postgres` pipelines concurrent requests over one
connection and coalesces them into few socket writes; Postgres in turn flushes several answers at once. Each
request picks the connection with the fewest requests in flight. Statements are prepared once per connection.

**One round trip per endpoint on the hot paths.**

* List endpoints return the page *and* the capped count in one statement (the count is an uncorrelated
  sub-select that is evaluated once). Only an empty page needs a second statement.
* For `/api/articles` and `?author=` the page is cut out first (`ORDER BY id DESC LIMIT/OFFSET` on the index) and
  only then joined and decorated, so the per-row sub-selects (tags, favorites, follows) never run for rows that
  `OFFSET` skips.
* Comments: existence check and comments in one statement (a `LEFT JOIN LATERAL` yields one all-NULL row for an
  article without comments and no row for an unknown slug).
* Comment insert, favorite, follow: the lookup (→ 404) and the write are one statement (data-modifying CTE).
* Article creation: the reference's transaction (id, article, tags, links) is one atomic CTE statement, so no
  multi-statement transaction ever needs to be pinned to a shared, pipelined connection.
* Delete comment: one `DELETE ... USING`; only a failed delete looks up why (404 vs 403).

**Session settings on our own connections** (rule 2 allows session-level `SET`): `jit = off` and
`max_parallel_workers_per_gather = 0`, plus (default on, `PG_GENERIC_PLANS=0` turns it off)
`plan_cache_mode = force_generic_plan`, so each statement is planned once per connection instead of on every
execution (with `LIMIT`/`OFFSET` as parameters the planner otherwise keeps choosing custom plans, and planning
is a big part of what a list request costs). A generic plan can't see the `LIMIT` value and assumes a page is
10% of the table, so `enable_hashjoin` and `enable_mergejoin` are off as well: every join here is a
primary-key lookup, and nested loops over indexes are always the right plan. `synchronous_commit` is untouched:
every write is committed before its response. `conduit --check` prepares every statement against the real
database and prints the generic plans (see below).

**Cheap, honest security.** HS256 is verified on every request (HMAC over the received bytes, constant-time
compare, `alg` must be HS256, `exp` checked); nothing is cached. Passwords are bcrypt cost 10 and every login
verifies against the stored hash. bcrypt runs on its own OS-thread pool (`BCRYPT_THREADS`, default = cores) at a
lowered scheduling priority (`BCRYPT_NICE`, default 10, `0` disables; set on this process's own threads only), so
a 60 ms hash can never block an event loop and it gives way to request handling when the box is saturated.

**Small per-request cost.** Responses are written straight from borrowed row data into one buffer by hand-written
JSON writers (no serde on the response path); timestamps are formatted from the binary `timestamptz` value;
`GET /api/tags` fetches one `text[]` instead of 200 rows; `mimalloc`; fat LTO and `target-cpu=native` (built on the
box that runs it).

## Tuning knobs (environment variables, all optional)

| Variable | Default | Meaning |
| --- | --- | --- |
| `APP_THREADS` | `max(2, cores/2)` | worker threads (single-threaded runtimes) |
| `DB_CONNS_PER_THREAD` | `4` | Postgres connections per worker (total is capped at 90) |
| `BCRYPT_THREADS` | cores | bcrypt pool size |
| `BCRYPT_NICE` | `10` | nice value of the bcrypt threads (`0` = normal priority) |
| `PG_GENERIC_PLANS` | `1` | `0` = leave Postgres plan caching and join methods at their defaults |

## Checking it

```bash
bash test/run.sh submissions/rust-hyper-arnabanimesh             # the conformance suite to be run from challenge repo root
cargo test                                                       # unit tests: JSON escaping, timestamps, JWT, query parsing
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_lg ./target/release/conduit --check
```

`--check` connects, prepares all 30 statements (a typo in any SQL fails here, with Postgres's message) and prints
`EXPLAIN (GENERIC_PLAN)` for the list, article and comment statements. It prints a `!!` line if a plan contains a
hash/merge join or a sequential scan of `users`; there should be none.
