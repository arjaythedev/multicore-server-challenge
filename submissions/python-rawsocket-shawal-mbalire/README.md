Front: direct

# Python raw socket submission

from the previous challenge, i wondered whether sockets could remove all the overhead

## Software

- Python 3 (system `python3` on Ubuntu 24.04)
- `psycopg` 3.3.4 with its C implementation `psycopg-c` (compiled from source by `build.sh`); one connection per
  worker (16 by default, of Postgres's 100). `psycopg_pool` 3.3.3 is used only in the optional threaded mode.
- `bcrypt` 5.0.0, plus the OS's libxcrypt (`libcrypt.so.1`, loaded with `ctypes`) for the bcrypt computation itself:
  same algorithm and hash format, about 14% less CPU. pyca/bcrypt makes salts and is the fallback if libxcrypt is missing
- `PyJWT` 2.15.1
- `orjson` 3.13.0: all JSON encoding (dataclasses natively, about 4x the stdlib encoder) and decoding

All pins live in `constraints.txt` (transitives included); `build.sh` installs against it and `start.sh` runs the project `.venv`.

## Architecture (hexagonal / ports & adapters)

```
conduit_server/
├── domain/            pure business logic: frozen dataclasses + validation/slug/paging rules. No I/O deps.
│   ├── models.py      response shapes (User, Profile, Article, Comment…)
│   └── services.py    slugify (byte-identical to SQL SLUGIFY), strict limit/offset, tagList checks
├── ports/             Protocol contracts — inbound (transport) & outbound (db, crypto)
├── adapters/
│   ├── inbound/       raw socket server (epoll via selectors), path-param router, controllers
│   └── outbound/      psycopg PostgreSQL repository + bcrypt/JWT adapter
├── main.py            composition root: wires pool → repository → crypto → controllers
└── scripts/check.py   static wiring check (used by `just check`)
```

## How it works

- **Processes: share first, split only for the GIL.** `main.py` builds everything once (imports, compiled routes,
  SQL strings, the listening sockets), calls `gc.freeze()` so the shared pages stay copy-on-write, then forks
  `WORKERS` (default 6) workers. The workers exist only because one GIL can't use more than one core. A worker doesn't
  sit idle while Postgres runs its queries (see Transport), so it needs no spare workers to cover the waits, and fewer
  workers keep more queries in flight per Postgres connection. At 8,000 users, app + Postgres CPU per request was
  565k ns with 16 workers, 532k with 8, 503k with 6 and 441–455k with 4 (whose p99 rose to 270–430 ms). Each one
  opens its own connections (connections can't cross a fork). The parent opens one `SO_REUSEPORT` listener per worker on the same port before
  forking, and the kernel hashes each new connection to one of them. Served directly, every virtual user keeps one
  connection on the worker that accepted it, so the split has to be even. At 8,000 users it gave 470–542 connections
  per worker, against 106–846 with one shared `EPOLLEXCLUSIVE` listener (still available as `REUSEPORT=0`), and halved
  the median latency (3.3–4.4 ms against 5.4–7.9 ms over four pairs). If any
  worker dies, the parent stops the server (rule 9: no restarts). With `WORKERS=1` nothing forks.

- **Transport** (per worker): one epoll loop thread does non-blocking accept/recv/send and HTTP/1.1 framing,
  and runs each complete request's synchronous router call inline. A worker is a single thread, so nothing
  contends for its GIL. The earlier design ran handlers on a thread pool per worker. It cost about 20 context
  switches per request in GIL handoffs and carried about 25% fewer req/s on the same CPU. It is still there with
  `THREADS=N` (N threads sharing `DB_BUDGET / WORKERS` pooled connections, results handed back through a
  deque + `eventfd`). The exception in inline mode is the three bcrypt routes (register, login, `PUT /api/user`,
  marked `offload=True` on the route). They run on one helper thread per worker with its own connection, through the
  same deque + `eventfd`, so a ~40 ms bcrypt doesn't stall the worker's other connections (bcrypt releases the GIL).
  The hot reads (article, comments, tags, the lists and feed, profile, current user: about 95% of requests) don't
  block the worker either. Their handlers are generators that `yield` the repository's query (`row = yield
  db.q_find_article(...)`). The loop sends it on a third connection kept in libpq pipeline mode, whose socket sits in
  the same epoll, and resumes the handler when the result arrives. Meanwhile it serves other requests, so several
  queries are in flight at once. Postgres reads them from its socket together, and each costs less: one blocking
  round trip took 30 µs of Postgres CPU and 16.5 µs of ours; with two in flight, 14.3 and 8.1 µs. Each query has its own
  Sync, so each runs in its own transaction, as in autocommit. Writes stay synchronous on the first connection.
  `PIPELINE=0` turns it off. At most 3 connections per worker, 18 in all. Writes never block: whatever the kernel doesn't take waits in a per-connection buffer under `EPOLLOUT`. A
  connection has one request in flight at a time (keeping HTTP/1.1 order), and pipelined bytes are handled after it.
  Idle keep-alive sockets close after 90 s: there is no Nginx in front, every virtual user holds its own connection,
  and 90 s outlasts the workload's 70 s maximum think time, so users don't reconnect between pages. `TCP_NODELAY` is on.

- **Routing** — 19 endpoints registered via decorators (`@router.get/post/put/delete`). Routes
  are compiled regexes, so `/api/articles/:slug/favorite` captures params. Handlers return
  `(status, dataclass-or-dict)`; the router serializes dataclasses and emits JSON with a correct
  `Content-Length`, mapping `ApiError` to `{"errors": {"body": [...]}}` for 401/403/404/422/500.

- **Data layer**: one connection per worker (`SingleConnection`, same `.connection()` contract as a pool,
  reconnects if broken). It is configured once with autocommit (no BEGIN/COMMIT round-trips around reads; the
  article insert uses an explicit transaction), `jit = off`, `enable_seqscan = off`, `TimeZone = UTC`
  (session-level only, rule 2), and then every statement is prepared server-side. Statements run on libpq directly
  (`conn.pgconn.exec_prepared`), and rows are decoded by one reused psycopg C `Transformer` per connection, so values
  are exactly what psycopg returns. psycopg's own `cursor.execute` spent about 45 µs of Python per statement
  (query parsing, generators, cursor setup); this path costs a few µs. Results match the
  challenge's reference SQL, checked row for row on the full seed. The SQL is reshaped for Postgres CPU:
  - every list and the feed are **one statement**: the capped count in a CTE, LEFT JOINed to the page, with the
    per-row subqueries computed only for the rows left after LIMIT/OFFSET;
  - tag names come from `tags_pkey` lookups (a JOIN to `tags`, or a seq scan of its 200 rows, ran once per article);
  - the comments page fetches the article and its comments in one statement, and `/api/tags` returns one array row.

  Postgres time for a global list page went from 1.62 ms to 0.61 ms (pgbench, one client). The rest:
  newest-first by id paging, feed via lateral join, article insert + tag upsert in one transaction, slug computed
  in Python from the `nextval` id. List rows omit
  `body`; timestamps are RFC 3339 UTC with truncated 3 fractional digits.

- **Security** — no caching, no shortcuts: every login does a fresh bcrypt verify (cost 10,
  over-72-byte passwords rejected as 422), every request re-verifies the JWT signature
  (HS256-only, `exp`/`iat` checked, string `sub` required) with stdlib `hmac` (PyJWT checked base64 one character
  at a time in Python and was the largest CPU cost per request), and anonymous viewers pass `0` as the viewer id.
  bcrypt runs at most 2 at a time per worker, so a login burst can't take every request thread. Passwords over
  72 bytes are rejected, as pyca/bcrypt does; passwords containing NUL go to pyca/bcrypt (C strings end at NUL).

- **CPU per request**: JSON goes through the C encoder with a shallow dataclass hook (no `dataclasses.asdict`
  deep copy), list rows are built as dicts directly, timestamps are formatted with `isoformat` instead of
  `strftime`, and routes are indexed by method. 204 responses carry no body (stray bytes would corrupt the next
  keep-alive response).

## Measured (local, full seed, loadgen `-think-scale 0.2` on the same 10-CPU laptop)

| Version | Test users | req/s | p95 | Result |
|---|--:|--:|--:|---|
| single-threaded loop (before) | 1,000 | 101 | 10 s (timeouts) | fail, 87% errors |
| 5 workers | 1,000 | 1,267 | 65 ms | pass |
| 5 workers | 4,000 | 5,225 | 33 ms | pass |
| 5 workers + CPU fixes | 8,000 | 6,740 | 679 ms | fail; laptop CPU saturated (app 4.1 cores, Postgres 3.3) |
| 16 inline workers + SQL rewrite | 8,000 | 8,412–9,271 | 461–705 ms | at the laptop's CPU ceiling (app 4.1 cores, Postgres 3.6) |
| + statements on libpq directly | 8,000 | 9,142–9,772 | 155–532 ms | load generator now the bottleneck (app ~2.9 cores) |
| + JWT/parse/router/glue trims, libxcrypt bcrypt, bcrypt off the loop, `SO_REUSEPORT`, JSON trims | 8,000 | 9,692–10,349 | 84–328 ms | 2 of 3 runs pass (p99 178 and 516 ms; the third 1.5 s) |

At 8,000 test users the per-request CPU went from about 600 µs app + 490 µs Postgres to about 410 µs + 370 µs,
then to about 280–330 µs + 320–345 µs with the libpq path, and is now about 290–305 µs + 365–375 µs (runs vary
10–20% on this laptop, Postgres included). One run in three still fails p99; that is not yet confirmed to be the
checkpoint stalls described below.

Where an app request's CPU goes (`scripts/cpusplit.sh 8000`, ns per request, latest run, all changes in):

| Stage | ns/req | Share | Calls/req |
|---|--:|--:|--:|
| bcrypt (logins and sign-ups, cost 10, fixed by the rules; libxcrypt) | 47,823 | 15.8% | 0.001 |
| libpq round trip (send + wait + recv, parameters) | 45,422 | 15.0% | 1.10 |
| controllers and frozen dataclasses | 42,203 | 13.9% | 1.00 |
| JWT verify/issue | 32,223 | 10.6% | 0.83 |
| JSON encode + response bytes | 30,173 | 9.9% | 1.00 |
| socket recv + HTTP framing | 23,834 | 7.9% | 1.00 |
| row decode (psycopg C) | 21,934 | 7.2% | 2.12 |
| repository glue (dict rows, connection) | 18,653 | 6.1% | 2.88 |
| socket send | 14,103 | 4.6% | 1.00 |
| router dispatch | 12,775 | 4.2% | 1.00 |
| HTTP parse | 10,057 | 3.3% | 1.00 |
| request wrapper, JSON decode, accept/close, unaccounted | 4,359 | 1.4% | |
| **app total** (about 9,300 of it is the timing instrumentation itself) | **303,559** | | goal 50,000 |
| **Postgres** | **373,728** | | |
| **total CPU per request** | **677,287** | | goal 266,667 (≈11,800 req/s on 8 vCPU) |

bcrypt's per-request share swings between runs (36,000–48,000 here) because logins are rare (about 0.1% of
requests) and each costs ~40 ms. The laptop is a hybrid Intel Core Ultra 7 255H (fast and slow cores). Under full
load its Python stages cost about 5× their single-thread cost (JWT verify 42 µs against 8.4 µs alone), so compare
runs with each other rather than reading the absolute numbers as the box's.
The laptop's own Postgres runs default settings (128 MB shared buffers, 1 GB max WAL). Its forced checkpoints
stall the whole server for a second or two, which is the likely cause of the failing p99 runs.

## Measuring

All scripts need a local database `conduit_lg` (a copy of the full seed) and the load generator at
`/tmp/conduit-lg/loadgen`.

| Command | What it does |
|---|---|
| `bash scripts/loadtest.sh <label> <users> [WORKERS]` | scoring-style run: overall result, verdict, CPU split; JSON with a per-second timeline in `/tmp/conduit-lg/<label>.json` |
| `WORKERS=6 bash scripts/cpusplit.sh <users>` | app user/sys µs, Postgres µs and context switches per request, then the per-stage ns table above. `STAGES=0` runs the plain server without the stage table |
| `PYTHONPATH=. .venv/bin/python scripts/diffsql.py` | checks the repository's SQL against the spec's reference SQL (should print 0 mismatches) |
| `PYTHONPATH=. .venv/bin/python scripts/profile.py` | single-thread CPU per endpoint, plus cProfile output |

`cpusplit.sh` starts the server through `scripts/stagetimer.py`. It wraps the hot functions with per-thread CPU
clocks (`time.thread_time_ns`, which leaves out time spent waiting for a core) and charges each stage only its own
time. `scripts/breakdown.py` prints the table. The stages add up to the measured app CPU, and the wrappers
themselves cost about 9 µs per request. Sampling profilers mislead here: they count a thread waiting for a free
core as running.

## Justfile guide

| Command        | What it does                                                                                     |
|----------------|--------------------------------------------------------------------------------------------------|
| `just`         | list all recipes                                                                                  |
| `just test`    | full conformance suite: builds, starts on a fresh `conduit_dev` copy, runs `test/run.sh` (197 steps) |
| `just venv`    | create/recreate `.venv` with pinned deps                                                          |
| `just lint`    | syntax gate (`py_compile` over all sources)                                                        |
| `just check`   | lint + composition-root wiring check: asserts all 19 routes register cleanly (`scripts/check.py`)   |
| `just paths`   | echo resolved CWD / submissions / repo-root paths                                                  |

Typical flow from a clean checkout:

```
just venv    # only if needed; `just test` builds anyway
just check   # fast static gate
just test    # the real 197-step conformance run
```

