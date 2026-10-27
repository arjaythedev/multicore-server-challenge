
# C++ / Drogon, split read/write pools

Front: direct

| |                                                                                     |
|---|-------------------------------------------------------------------------------------|
| Language | C++20, Drogon (coroutines, `HttpController`); GCC, pinned in the build              |
| HTTP | Drogon's built-in HTTP/1.1 server, keep-alive, `Content-Length` bodies              |
| Postgres | Drogon `orm::DbClient` over `libpq` — extended query protocol, text results         |
| JSON | `Json::Value` / `Json::FastWriter` for responses, `req->getJsonObject()` for bodies |
| JWT, bcrypt | HS256 via `jwt-cpp`; own bcrypt (`$2b$`, cost 10, `Lanes<N>` interleaved)           |
| Allocator | `jemalloc`                                                                          |
| Dependencies | Drogon, `jwt-cpp`, `robin_hood` (header-only), Postgres client library              |

## Design

Postgres uses most of the box's CPU, so most of the work goes into spending less Postgres time per request.

- **Two pools.** Reads and writes go to different `DbClient`s — 12 read connections, 16 write connections. A slow `INSERT` waiting for its WAL flush never blocks a `SELECT` queued on the same connection, and Postgres's own group commit handles the write side. Both pools are ordinary `DbClient`s (`isFast = false`): `FastDbClient` would give `(threads_num + 1) × connectionNumber` connections, uneven per IO thread, which under direct mode is 72 uneven connections instead of 28 predictable ones.
- **One statement per request, where it counts.** 
- Replace 80 correlated subqueries per page with 5 batched `WHERE … = ANY($1::bigint[])` scans for tags, favorites, and follows. Use short-lived robin_hood unordered maps/sets (20–100 entries, open addressing, no allocations) for side lookups. This cuts Postgres CPU dramatically, keeping the read pool at 12 connections.
- **The feed takes the newest `limit + offset` per followed author.** `CROSS JOIN LATERAL` per followee, not the newest `limit + offset` overall and then a sort. With 100 follows × 100 articles each, the old shape sorted 10,000 rows per request; the new one touches at most `follows × (limit + offset)` and sorts only the survivors.
- **Runtime.** `SIGPIPE` ignored — a client that closes its keep-alive socket mid-response must not kill the process. `threads_num = 6` on an 8-core box, leaving two cores for Postgres. `LimitNOFILE=200000` for direct mode's tens of thousands of keep-alive sockets.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `DB_READ_CONNS` | `12` | Read pool size (`default` client) |
| `DB_WRITE_CONNS` | `16` | Write pool size (`write` client) |
| `HOST`, `PORT` | `127.0.0.1`, `3000` | Listen address |
| `DATABASE_URL` | — | `postgres://user:pass@host:port/dbname` (required) |
| `JWT_SECRET` | — | HS256 secret (required) |



## Build and run

```bash
sudo bash install.sh && bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```


