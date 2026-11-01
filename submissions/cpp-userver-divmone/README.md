# C++ / userver

Front: direct

| | |
|---|---|
| Language | C++20, g++ 13.3 (Ubuntu 24.04) |
| Framework | [userver](https://github.com/userver-framework/userver) 3.2: coroutine HTTP server |
| Postgres driver | userver's own `storages::postgres` (on top of libpq 16) |
| JSON | request bodies: userver `formats::json`; responses: a small hand-written writer |
| bcrypt | libxcrypt `crypt_rn` (`$2b$`, cost 10; verifies the seed's `$2a$` hashes) |
| JWT | HS256 on OpenSSL SHA-256, hand-written |

`install.sh` installs the official userver 3.2 release package for Ubuntu 24.04
(`ubuntu24.04-libuserver-all-dev_3.2_amd64.deb` from the userver GitHub release, pinned by SHA-256); apt pulls in
its dependencies from the Ubuntu archive. `build.sh` is a plain CMake + Ninja release build, with no downloads.
`start.sh` runs `build/conduit --config static_config.yaml`.

## Layout

| File | |
|---|---|
| `src/main.cpp` | component list |
| `src/api.cpp` | handler base: auth, body parsing, error responses, article JSON |
| `src/auth.cpp` | JWT issue/verify, bcrypt |
| `src/users.cpp`, `profiles.cpp`, `articles.cpp`, `comments.cpp` | the 19 endpoints |
| `static_config.yaml` | userver config; `HOST`, `PORT`, `DATABASE_URL` come from the environment |

## Optimizations and why

- **No Nginx (`Front: direct`).** On a local 8-core stand with the box's Nginx config, Nginx took ~14% of the
  CPU at the saturation point (1.1 of 8 cores) and added a proxy hop to every request. userver serves HTTP/1.1
  keep-alive itself, with one coroutine per connection, so it holds every user's connection directly. The
  listener's connection cap is raised from the default 32768 to 200000, and the per-connection receive buffer is
  cut from 32 KB to 8 KB (it is preallocated for every connection).
- **Fewer round trips to Postgres.** The SQL returns the same results as the reference SQL, but statements are
  merged where that keeps the semantics:
  - list pages and their capped `articlesCount` come back in one statement (`WITH p AS (page), c AS (count)
    SELECT c.n, p.* FROM c LEFT JOIN p ON true`);
  - `GET …/comments` checks the slug and reads the newest 100 comments in one statement (`LEFT JOIN LATERAL`);
  - follow/unfollow, favorite/unfavorite and create-comment do the lookup and the write in one statement with a
    data-modifying CTE. The full article select after a favorite stays a separate statement, so it sees the write.
  - Article create keeps the reference transaction (`INSERT article`, tags, `article_tags`).
- **Prepared statements**: userver prepares each query once per connection and caches it.
- **Literal `LIMIT`/`OFFSET` in the global and tag lists.** With them as parameters, Postgres can't reuse a generic
  plan for these two queries (it assumes an unknown `LIMIT` returns 10% of the rows) and replans on every call. On
  the full seed planning cost as much as executing (0.26–0.36 ms vs ~0.29 ms). With literals (validated integers,
  one prepared statement per page shape) planning drops to ~0.005 ms. On a local 8-core stand at the same load,
  Postgres CPU fell from 4.8 to 3.5 cores, p99 from 312 ms to 8 ms. The other lists already reuse generic plans.
- **`jit = off`** on our connections (`PGOPTIONS` in `start.sh`, a session setting). None of the real plans
  triggers JIT today, but a misestimated plan would otherwise spend milliseconds compiling on every call.
- **A fixed pool of 48 connections** (`DB_POOL_SIZE`), all opened at startup. 8 cores of Postgres don't benefit
  from more, and it stays far below the limit of 95.
- **bcrypt on its own task processor** (`BCRYPT_THREADS`, half the cores). A login costs ~50 ms of CPU; running it
  apart keeps the coroutine workers serving the 95% of cheap reads instead of queueing behind bcrypt.
- **Minimal userver pipeline**: only the exception-to-500 middleware. No tracing, access log, per-handler metrics,
  deadline propagation or throttling. Log level `warning`.
- **Responses are written straight into one string** (escaping, RFC 3339 timestamps, ints), reading Postgres text
  as `string_view`s without copies.
- **JWT**: the HMAC key pads are hashed once at startup, so each check is two SHA-256 compressions plus a JSON parse
  of the claims. The common header `{"alg":"HS256","typ":"JWT"}` is recognised without decoding it.

Nothing is cached across requests. Every request reads Postgres, every token is fully verified, and every login
runs bcrypt.

## Config (env)

| Variable | Default |
|---|---|
| `DATABASE_URL`, `JWT_SECRET` | required |
| `HOST`, `PORT` | `127.0.0.1`, `3000` (the box sets `0.0.0.0`, `80`) |
| `WORKER_THREADS` | `nproc` |
| `BCRYPT_THREADS` | `nproc / 2` |
| `DB_POOL_SIZE` | `48` |
| `EVENT_THREADS` | `2` (userver's libev network threads) |
