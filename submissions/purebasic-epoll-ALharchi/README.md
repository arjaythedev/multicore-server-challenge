# PureBasic, epoll, one file

Front: direct

A Conduit server in PureBasic 6.41, compiled with the free version from purebasic.com. The free version won't
compile a source file longer than 781 lines, and that limit shaped most of the design: everything is in
`conduit.pb`, 650 lines including comments.

| | |
|---|---|
| Language | PureBasic 6.41 Free, C backend (gcc 13 from Ubuntu 24.04), built with `--optimizer --thread` |
| HTTP | hand-written HTTP/1.1 on epoll, no framework |
| Postgres | libpq from apt; every statement is prepared once per connection |
| JSON | responses are built by Postgres; request bodies are parsed with PureBasic's JSON library |
| bcrypt | PureBasic's `CreatePasswordHash` / `VerifyPasswordHash`, cost 10 |
| JWT | HS256, with HMAC-SHA256 from libcrypto (OpenSSL 3) |

## How it works

The server starts `THREADS` worker threads (32 by default). Each one has its own epoll instance, its own
`SO_REUSEPORT` listening socket and its own Postgres connection. A worker reads a request, checks the token, runs
one prepared statement and writes the response with a single `send`.

Every endpoint is one SQL statement that returns the finished response body (`json_build_object`, `json_agg`).
The app never decodes rows. It copies the bytes Postgres sends into the socket, which is what keeps the code short.
Writes are a single statement too: a data-modifying CTE does the write and reads back the result in the same round
trip. Each statement is its own transaction, so the response only goes out after the commit. A statement can't see
its own insert in its snapshot, so the favorite endpoints add what they changed to the count.

## What made a difference

Postgres uses about two thirds of the CPU and the app about a quarter, so nearly all the tuning went into the SQL.
I measured it with pg_stat_statements on a local copy of the full seed.

Generic plans. Planning the list queries took 0.5 to 0.8 ms per call, about as long as running them.
`plan_cache_mode = force_generic_plan` removes the planning, but with the reference query shape
(`a.id IN (SELECT ... LIMIT $2 OFFSET $3)`) the generic plan is bad, because the planner doesn't know how many
rows `LIMIT $2` will return. The lists now fetch the page of ids first and build each article in a `LATERAL`
subquery behind `OFFSET 0`, so the plan is the same whatever the limit is. A page of the global list went from about
1.9 ms (planning plus execution) to 0.6 ms, and throughput went up by about 30%.

Tag names by primary key. The `article_tags JOIN tags` subquery was planned as a hash join over all 200 tags for
every article. Looking each name up by `tags.id` is faster, and the order comes out the same.

## What didn't

Batching reads. I tried the unnest + LATERAL batching the top entries use, for tags, single articles and comments:
one statement per kind for each epoll round. Batches averaged 4.5 requests and halved the number of those
statements, but CPU and throughput didn't change. When Postgres builds the JSON, nearly all of the cost is per
request, so there's little per-statement overhead left to save. It also cost 74 lines, so I took it out.

One scan for `favoritesCount` and `favorited`. `favorites_article_idx` doesn't include `user_id`, so a single
scan has to visit the table, and it was no faster than the two index lookups.

Fewer threads. A worker blocks while its query runs and while bcrypt runs, so with 12 to 24 threads a 50 ms login
hash or a slow feed holds up every connection on that thread. 32 was the best; 48 was worse.

## Numbers

These come from my own machine, so they can't be compared with the leaderboard: a Ryzen 5 2600X under Docker Desktop,
with the app and Postgres limited to 4 cores (8 threads), the load generator on other cores, the full seed and
60-second measurement windows. Around 40,000 users pass at 8,500 to 10,000 req/s. At 50,000 users, p95 misses the
limit by a small margin.

## Notes

- `install.sh` downloads the free version from purebasic.com and checks its sha256. The URL has no version number,
  so if a new release is published there, the checksum will fail and the hash needs updating.
- The Postgres connection uses `sslmode=disable`. libpq's OpenSSL setup crashes next to the PureBasic runtime,
  and the database is on loopback anyway.
- Optional setting: `THREADS`, the number of worker threads and of Postgres connections (default 32).

## Running

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```
