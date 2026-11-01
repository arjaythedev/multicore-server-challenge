
# C++ / Drogon, split read/write pools

Front: direct

| | |
|---|---|
| Language | C++20, Drogon commit `360980c9cd7205b94a0728a10eaa8cff19656977` ; GCC |
| HTTP | Drogon's HTTP/1.1 server, keep-alive, `Content-Length` |
| Postgres | Drogon `orm::DbClient` over `libpq` — extended query protocol, text results |
| JSON | `Json::Value` / `Json::FastWriter`; `req->getJsonObject()` for bodies |
| JWT, bcrypt | HS256 via `jwt-cpp` (pinned, see below); own bcrypt (`$2b$`, cost 10, `Lanes<N>`) |
| Allocator | `jemalloc`, `-O3 -march=native` |
| Dependencies | Drogon (pinned), `jwt-cpp` (pinned), `robin_hood` (header-only), libpq |

Pinned versions:

| Dependency | Version / commit |
|---|---|
| Drogon | `360980c9cd7205b94a0728a10eaa8cff19656977` |
| jwt-cpp | `v0.7.1` |
| robin_hood | header-only, vendored |
| picojson | submodule of jwt-cpp (installed from its pinned submodule checkout) |

## Design

Postgres is the bottleneck (most of the box's CPU), so most of the work is spent making each request cost less Postgres time.

- **Two pools.** 12 read + 16 write connections. A slow `INSERT` waiting for WAL flush never blocks a `SELECT` queued behind it. Both are plain `DbClient`s (`isFast = false`): `FastDbClient` would give `(threads_num + 1) × connectionNumber` connections, uneven per IO thread — 72 unpredictable instead of 28.
- **One statement per request, where it counts.** Follow/unfollow, favorite/unfavorite, create/delete comment, update/delete article fold lookup, ownership check and write into one data-modifying CTE.
- **Lists cut the page first.** Every list (global, by tag, by author, by favorited) does an index-only scan of its page before joining `users` or computing anything per row.
- **Per-row work is batched, not correlated.** The naive list runs 80 correlated subqueries for a 20-article page; here the page select returns only `articles` + `users`, and four `WHERE … = ANY($1::bigint[])` statements fill in tags, favorite counts, favorited and following for the whole page. 5 index scans instead of 80 lookups.
- Side maps are `robin_hood::unordered_flat_map` / `_set` — short-lived, no per-node allocations.
- **Feed takes the newest `limit + offset` per followed author** via `CROSS JOIN LATERAL`, not the newest overall and then a sort.
- **bcrypt cost 10.** Hash on register/change, verify on every login — against a dummy hash for unknown emails, so response times do not leak which emails exist.
- **Runtime.** `SIGPIPE` ignored; `threads_num = 6` (two cores left for Postgres); session settings pinned per connection.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `DB_READ_CONNS` | `12` | Read pool (`default`) |
| `DB_WRITE_CONNS` | `16` | Write pool (`write`) |
| `HOST`, `PORT` | `127.0.0.1`, `3000` | Listen address |
| `DATABASE_URL` | — | `postgres://user:pass@host:port/dbname` (required) |
| `JWT_SECRET` | — | HS256 secret (required) |

`threads_num = 6` lives in `config/config.json`. `gzip` / `brotli` off, `max_connections_per_ip = 0`, `keepalive_requests = 0`, `idle_connection_timeout = 120` (think time up to 70 s), `client_max_body_size = 1M`.

## Session settings

At startup, a `SET` batch runs enough times to hit every connection in both pools:

```
jit                        = off
max_parallel_workers_per_gather = 0
enable_memoize             = off
synchronous_commit         = on
```

`plan_cache_mode` stays at `auto` — a generic plan can be catastrophically worse than a custom one when the planner cannot see parameter values.

## Build and run

```bash
sudo bash install.sh && bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`install.sh` pins Drogon and jwt-cpp to the versions above.

## What this is not

It is not the 120k-user submission. That one has its own Postgres client, batches 666 reads per sync and up to 777 writes per transaction, and writes JSON straight from Postgres's binary rows into pooled buffers.
Drogon does not let us do any of those things without replacing Drogon, and replacing Drogon is a story for another time.
(Could rebuild drogon with AI by replacing std containers with robin_hood and jsoncpp with simdjson though but ... just no)
I dare call it a relatively prod-safe implementation.
Was pretty curious, how far is it possible to get with bare drogon, without resorting to libpq or iourings and epolls.
Failure is always an option...
But real failure is when you stop trying.

## Rules we follow

- No cross-request caching. Every request reads Postgres while served; only connections and prepared statements are reused.
- Every login verifies bcrypt cost 10 against the stored hash; every registration and password change hashes with cost 10; every request verifies JWT signature, `alg` and `exp`.
- Writes committed before responding (`synchronous_commit = on`).
- Nothing in the database is created or altered; only session settings are used.
- 28 connections total, headroom inside `max_connections = 100`.
- Every dependency is pinned (see the table above); `install.sh` checks out the exact Drogon commit and jwt-cpp tag.

## Credits

- `bcrypt.hpp` / `bcrypt_tables.cpp` are adapted from
  cpp-asio-c-hatton (MIT License).
  Original copyright belongs to its authors; see the header of `bcrypt.hpp`
  for the original notice.
- `jwt-cpp` — Thalhammer/jwt-cpp (MIT).
- `robin_hood` — martinus/robin-hood-hashing (MIT).
- Drogon — drogonframework/drogon (MIT).

