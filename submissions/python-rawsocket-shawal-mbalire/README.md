Front: direct

# Python raw socket submission

from the previous challenge, i wondered whether sockets could remove all the overhead

## Software

- CPython 3.15 (3.15.0, installed by `install.sh` with uv 0.13.0, as in `examples/python`; Ubuntu's own `python3` is
  3.12), standard library only for the server: `select.epoll`, `socket`, `os.fork`
- `psycopg` 3.3.4 with its C implementation `psycopg-c` (compiled from source by `build.sh` against `libpq-dev`), used
  mostly as a thin layer over libpq: prepared statements, pipeline mode and its C row decoder. `psycopg_pool` 3.3.3 is
  used only in the optional threaded mode
- `bcrypt` 5.0.0 (salts, and the fallback), plus the OS's libxcrypt (`libcrypt.so.1`, loaded with `ctypes`) for the
  bcrypt computation itself: same algorithm and hash format, about 14% less CPU
- `PyJWT` 2.15.1 (only to derive the HS256 header; tokens are signed and verified with stdlib `hmac`)
- `orjson` 3.13.0: request bodies and the user responses

All pins live in `constraints.txt` (transitives included); `build.sh` installs against it and `start.sh` runs the project `.venv`.

## Architecture (hexagonal / ports & adapters)

```
conduit_server/
├── domain/            pure business logic: frozen dataclasses + validation/slug/paging rules. No I/O deps.
│   ├── models.py      response shapes (User, Profile, Article, Comment…)
│   └── services.py    slugify (byte-identical to SQL SLUGIFY), strict limit/offset, tagList checks
├── ports/             Protocol contracts — inbound (transport) & outbound (db, crypto)
├── adapters/
│   ├── inbound/       raw socket server (epoll), router, controllers
│   └── outbound/      libpq/psycopg PostgreSQL repository + bcrypt/JWT adapter
├── main.py            composition root: wires connections → repository → crypto → controllers, forks workers
└── scripts/check.py   static wiring check (used by `just check`)
```

Every response except the three user routes (`/api/users`, `/api/users/login`, `/api/user`) is a JSON body that
Postgres builds (`json_build_object`), which the server passes through as bytes. The dataclasses in `domain/models.py`
build the user responses, and they are the contract `scripts/diffsql.py` checks every Postgres-built body against.

## How it works

- **Processes: share first, split only for the GIL.** `main.py` builds everything once (imports, routes, SQL strings,
  the listening sockets), calls `gc.freeze()` so the shared pages stay copy-on-write, then forks `WORKERS` (default 6)
  workers. The workers exist only because one GIL can't use more than one core. A worker doesn't sit idle while
  Postgres runs its queries (see Transport), so it needs no spare workers to cover the waits, and fewer workers keep
  more queries in flight per Postgres connection. At 8,000 users, app + Postgres CPU per request was 565k ns with 16
  workers, 532k with 8, 503k with 6 and 441–455k with 4 (whose p99 rose to 270–430 ms). Each worker opens its own
  connections (connections can't cross a fork). The parent opens one `SO_REUSEPORT` listener per worker on the same
  port before forking, and the kernel hashes each new connection to one of them. Served directly, every virtual user
  keeps one connection on the worker that accepted it, so the split has to be even. At 8,000 users it gave 470–542
  connections per worker, against 106–846 with one shared `EPOLLEXCLUSIVE` listener (still available as
  `REUSEPORT=0`), and halved the median latency. If any worker dies, the parent stops the server (rule 9: no
  restarts). With `WORKERS=1` nothing forks.

- **Transport** (per worker): one epoll loop thread does non-blocking accept/recv/send and HTTP/1.1 framing, and runs
  each request's handler inline. A worker is a single thread, so nothing contends for its GIL. (A thread pool per
  worker cost about 20 context switches per request in GIL handoffs and carried about 25% fewer req/s on the same CPU;
  it is still there with `THREADS=N`.)
  - Handlers are generators that `yield` the repository's query (`body = yield db.q_find_article_json(...)`). The loop
    sends it on a connection kept in libpq pipeline mode, whose socket sits in the same epoll, and resumes the handler
    when the result arrives. Meanwhile it serves other requests, so several queries are in flight at once. Postgres
    reads them from its socket together, and each costs less: one blocking round trip took 30 µs of Postgres CPU and
    16.5 µs of ours; with two in flight, 14.3 and 8.1 µs. Each query has its own Sync, so it runs in its own
    transaction and is committed before its result (and so the response) comes back.
  - Each worker has 2 read pipelines (`PG_READERS`), and a query goes to the one with fewer in flight. Writes go to a
    third, write pipeline. Every write is one statement (CTEs), so it is atomic on its own.
  - The three bcrypt routes (register, login, `PUT /api/user`, `offload=True` on the route) run on one helper thread
    per worker with its own connection, results handed back through a deque + `eventfd`, so a ~40 ms bcrypt doesn't
    stall the worker's other connections (the libxcrypt call releases the GIL).
  - Postgres connections: 4 per worker, 24 in all (the helper's opens on first use). `main.py` refuses to start a
    configuration that could open more than 95. `PIPELINE=0` runs every query blocking on one connection instead.
  - Writes to clients never block: whatever the kernel doesn't take waits in a per-connection buffer under `EPOLLOUT`.
    A connection has one request in flight at a time (keeping HTTP/1.1 order), and pipelined bytes are handled after
    it. Idle keep-alive sockets close after 90 s: there is no Nginx in front, every virtual user holds its own
    connection, and 90 s outlasts the workload's 70 s maximum think time, so users don't reconnect between pages.
    `TCP_NODELAY` is on.

- **Routing**: 19 endpoints registered with decorators (`@router.get/post/put/delete`). Paths without parameters are
  one dict lookup; the rest are matched segment by segment (`/api/articles/:slug/favorite`). Handlers return
  `(status, body)`, where the body is JSON bytes from Postgres or a dataclass that `orjson` serializes. `ApiError`
  becomes `{"errors": {"body": [...]}}` for 401/403/404/422; unexpected errors give a generic 500 (details go to
  stderr). 204 responses carry no body (stray bytes would corrupt the next keep-alive response).

- **Data layer**: every connection is configured once with autocommit, `jit = off`, `enable_seqscan = off`,
  `enable_memoize = off`, `plan_cache_mode = force_generic_plan` and `TimeZone = UTC` (session-level only, rule 2), and
  then every statement is prepared server-side. Statements run on libpq directly (`pgconn.send_query_prepared` in
  pipeline mode, `exec_prepared` otherwise): psycopg's own `cursor.execute` spent about 45 µs of Python per statement
  (query parsing, generators, cursor setup). Results match the challenge's reference SQL, checked on the full seed by
  `scripts/diffsql.py`. The SQL is reshaped for Postgres CPU:
  - every list and the feed are **one statement**: the capped count in a CTE, then the page as one JSON array, with
    the per-row subqueries computed only for the rows left after LIMIT/OFFSET;
  - responses are built in SQL (`json_build_object`, `json_agg`), timestamps formatted by `to_char` (RFC 3339 UTC,
    milliseconds truncated): about 320 ns of Postgres per value against 750 ns of Python;
  - each write and its response is one statement: e.g. favorite inserts in a CTE and returns the article, adjusting
    `favorited` and `favoritesCount` by the CTE's row count (one statement can't see its own writes); create-article
    upserts its new tags with `ON CONFLICT DO UPDATE`, so a tag another request commits at the same moment still gets
    its `article_tags` row;
  - tag names come from `tags_pkey` lookups, and the comments page fetches the article and its comments together.
  `force_generic_plan`: under `auto`, Postgres re-planned the list statements on every execution (~180 µs each).

- **Security**: no caching, no shortcuts. Every login does a fresh bcrypt verify (cost 10; passwords over 72 bytes
  are rejected as 422, as pyca/bcrypt does; passwords containing NUL go to pyca/bcrypt, since C strings end at NUL).
  Every request re-verifies the JWT signature (HS256 only, `exp`/`iat`/`nbf` checked, string `sub` required, strict
  base64url) with stdlib `hmac` (PyJWT checked base64 one character at a time in Python, then the largest CPU cost
  per request). Anonymous viewers pass `0` as the viewer id. The server won't start without `JWT_SECRET`.

## Measured (local, full seed, loadgen `-think-scale 0.2` on the same 10-CPU laptop)

| Version | Test users | req/s | p95 | Result |
|---|--:|--:|--:|---|
| single-threaded loop (before) | 1,000 | 101 | 10 s (timeouts) | fail, 87% errors |
| 5 workers | 1,000 | 1,267 | 65 ms | pass |
| 5 workers | 4,000 | 5,225 | 33 ms | pass |
| 5 workers + CPU fixes | 8,000 | 6,740 | 679 ms | fail; laptop CPU saturated (app 4.1 cores, Postgres 3.3) |
| 16 inline workers + SQL rewrite | 8,000 | 8,412–9,271 | 461–705 ms | at the laptop's CPU ceiling (app 4.1 cores, Postgres 3.6) |
| + statements on libpq directly | 8,000 | 9,142–9,772 | 155–532 ms | load generator now the bottleneck (app ~2.9 cores) |
| + JWT/parse/router/glue trims, libxcrypt bcrypt, bcrypt off the loop, `SO_REUSEPORT` | 8,000 | 9,692–10,349 | 84–328 ms | 2 of 3 runs pass |
| + Postgres pipeline (6 workers), JSON built by Postgres, Postgres tuned like the box | 8,000 | not recorded | not recorded | pass, p99 11–44 ms |
| + pipelined single-statement writes, CPython 3.15 via uv | 8,000 | 10,576 | 2.9 ms | pass (p99 9.4 ms) |

The earlier rows' p99 failures were mostly the laptop's own Postgres, which ran with 128 MB of shared buffers and
forced checkpoints; it now runs the box's settings (`box/pg-conf.sh`). Per request, CPU went from about 600 µs app +
490 µs Postgres to about 197 µs + 330 µs.

Where an app request's CPU goes (`WORKERS=6 bash scripts/cpusplit.sh 8000`, ns per request, latest run):

| Stage | ns/req | Share | Calls/req |
|---|--:|--:|--:|
| bcrypt (logins and sign-ups, cost 10, fixed by the rules; libxcrypt) | 42,050 | 21.4% | 0.001 |
| event loop and pipeline code (not timed) | 34,092 | 17.3% | |
| libpq (send, receive, parameters) | 33,573 | 17.1% | 2.91 |
| socket recv + HTTP framing | 20,796 | 10.6% | 1.00 |
| JWT verify/issue | 16,163 | 8.2% | 0.80 |
| controllers (generator handlers) | 13,950 | 7.1% | 2.99 |
| socket send | 11,521 | 5.9% | 1.00 |
| router dispatch | 8,234 | 4.2% | 1.00 |
| HTTP parse | 7,518 | 3.8% | 1.00 |
| repository glue | 5,663 | 2.9% | 2.00 |
| JSON encode + response bytes | 2,523 | 1.3% | 1.00 |
| accept/close, row decode, JSON decode | 432 | 0.2% | |
| **app total** (about 7,700 of it is the timing instrumentation itself) | **196,515** | | goal 50,000 |
| **Postgres** | **329,990** | | |
| **total CPU per request** | **526,506** | | goal 266,667 (≈30,000 req/s on 8 vCPU) |

bcrypt's per-request share swings between runs because logins are rare (about 0.1% of requests) and each costs
~40 ms. The laptop is a hybrid Intel Core Ultra 7 255H (fast and slow cores). Under full load its Python stages cost
about 5× their single-thread cost, so compare runs with each other rather than reading the absolute numbers as the
box's.

## Measuring

All scripts need a local database `conduit_lg` (a copy of the full seed) and the load generator at
`/tmp/conduit-lg/loadgen`.

| Command | What it does |
|---|---|
| `bash scripts/loadtest.sh <label> <users> [WORKERS]` | scoring-style run: overall result, verdict, CPU split; JSON with a per-second timeline in `/tmp/conduit-lg/<label>.json` |
| `WORKERS=6 bash scripts/cpusplit.sh <users>` | app user/sys µs, Postgres µs and context switches per request, then the per-stage ns table above. `STAGES=0` runs the plain server without the stage table |
| `PYTHONPATH=. .venv/bin/python scripts/diffsql.py` | compares every Postgres-built response (reads, and writes inside rolled-back transactions) with the spec's reference SQL (should print 0 mismatches) |
| `PYTHONPATH=. .venv/bin/python scripts/profile.py` | single-thread CPU per endpoint, plus cProfile output |

`cpusplit.sh` starts the server through `scripts/stagetimer.py`. It wraps the hot functions with per-thread CPU
clocks (`time.thread_time_ns`, which leaves out time spent waiting for a core) and charges each stage only its own
time. `scripts/breakdown.py` prints the table. The stages add up to the measured app CPU, and the wrappers
themselves cost about 8 µs per request. Sampling profilers mislead here: they count a thread waiting for a free
core as running.

## Justfile guide

| Command        | What it does                                                                                     |
|----------------|--------------------------------------------------------------------------------------------------|
| `just`         | list all recipes                                                                                  |
| `just test`    | full conformance suite: builds, starts on a fresh `conduit_dev` copy, runs `test/run.sh` (197 steps) |
| `just venv`    | create/recreate `.venv` with the pinned deps (runs `build.sh`)                                     |
| `just lint`    | syntax gate (`py_compile` over all sources)                                                        |
| `just check`   | lint + composition-root wiring check: asserts all 19 routes register cleanly (`scripts/check.py`)   |
| `just paths`   | echo resolved CWD / submissions / repo-root paths                                                  |

Typical flow from a clean checkout:

```
just venv    # only if needed; `just test` builds anyway
just check   # fast static gate
just test    # the real 197-step conformance run
```
