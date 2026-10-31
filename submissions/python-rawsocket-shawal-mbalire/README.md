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
- Logins (with the broker): a multi-lane bcrypt in C, `conduit_server/adapters/outbound/native/bcrypt_lanes.c`, built
  by `build.sh` with gcc and called through `ctypes`. It is OpenBSD's bcrypt, run for up to 8 passwords in lockstep so
  one hash's S-box loads overlap the others' waits; Blowfish's initial tables are generated from the digits of pi
  (`gen_pi.py`). Cost 10, CPU per hash, single thread on the laptop: libxcrypt 38.4 ms; 1 lane 37.6, 2 lanes 19.8,
  4 lanes 11.3, 6 lanes 8.8, 8 lanes 9.3. Hashes are byte for byte libxcrypt's (checked when it loads, and on 139
  hashes across costs, lane counts, `$2a`/`$2b`/`$2y` and password lengths); without the library, libxcrypt is used
- `PyJWT` 2.15.1 (only to derive the HS256 header; tokens are signed with stdlib `hmac`)
- Token verification: `conduit_server/adapters/outbound/native/jwt_verify.c`, a CPython extension built by `build.sh`.
  It checks the signature (HMAC-SHA256, SHA-NI when the CPU has it) and `exp`/`iat` on every request, for tokens in
  the form this server issues; any other token is checked by the Python code with stdlib `hmac`, with the same result.
  1.8 → 0.24 µs per token, single thread. `JWT_NATIVE=0` turns it off
- `orjson` 3.13.0: request bodies and the user responses

All pins live in `constraints.txt` (transitives included); `build.sh` installs against it and `start.sh` runs the project `.venv`.

## Architecture (hexagonal / ports & adapters)

```
conduit_server/
├── domain/            pure business logic: frozen dataclasses + validation/slug/paging rules. No I/O deps.
│   ├── models.py      response shapes (User, Profile, Article, Comment…)
│   ├── services.py    slugify (byte-identical to SQL SLUGIFY), strict limit/offset, tagList checks
│   └── errors.py      DuplicateError (raised by any database adapter)
├── ports/             Protocol contracts; import no adapter
│   ├── inbound.py     HttpRequest, RequestParser, HttpApplication (router), InboundServer (transport)
│   └── outbound.py    repository, query pipeline, database driver, password hasher, tokens, JSON codec
├── adapters/
│   ├── inbound/       raw socket server (epoll), router, controllers
│   └── outbound/      libpq driver (repository, pipelines, broker), bcrypt hasher, HS256 tokens, orjson codec
├── registry.py        which adapter plugs into each port, by environment variable
├── main.py            composition root: builds the chosen adapters, wires them into the controllers, forks workers
└── scripts/check.py   static wiring check (used by `just check`)
```

Every adapter is chosen at startup by an environment variable (`registry.py`; the first listed is the default, an
unknown name stops the server with the list of choices). Controllers only see the ports, so an adapter can be swapped
without touching them:

| Variable | Port | Adapters |
|---|---|---|
| `HTTP_SERVER` | `InboundServer` | `epoll` (Python loop on epoll), `uvloop` (libuv, C) |
| `JSON_CODEC` | `JsonCodecPort` | `orjson` (Rust), `msgspec` (C), `stdlib` (`_json`, C), `ujson` (C), `rapidjson` (C++), `yyjson` (C; fails one conformance step: decodes `\u` escapes wrongly), `pydantic` (pydantic-core, Rust) |
| `DB_DRIVER` | `DatabaseDriverPort` | `libpq` (psycopg-c), `libpq-ctypes` (psycopg's pure-Python libpq bindings), `libpq-rows` (rows, bodies built in the app with the codec), `asyncpg` (needs `HTTP_SERVER=uvloop`; no broker) |
| `PASSWORD_HASHER` | `PasswordHasherPort` | `bcrypt` (multi-lane C + libxcrypt), `libxcrypt` (libcrypt.so, one at a time), `pyca` (pyca/bcrypt, Rust) |
| `TOKENS` | `TokenPort` | `hs256` (C verify, SHA-NI), `hs256-py` (stdlib HMAC), `pyjwt` (PyJWT) |

The non-default adapters' dependencies (uvloop, asyncpg, msgspec, ujson, python-rapidjson, yyjson, pydantic) are installed only with `ALT_ADAPTERS=1 bash build.sh`
(also set it for `test/run.sh`, which runs build.sh). Each passes the conformance suite. Measured against the
defaults (laptop, `conduit_full`, 24,000 test users, alternating runs, `STAGES=0`):

App and Postgres CPU per request (µs, user+sys), req/s; every run PASSed unless noted. The defaults ran several
times across the session: app 90–96, Postgres 154–185, 29.9k–31.4k req/s.

| Change from the defaults | App | Postgres | req/s | Note |
|---|--:|--:|--:|---|
| `HTTP_SERVER=uvloop` | 97, 100 | 177, 185 | 31.7k, 30.2k | same responses byte for byte on raw HTTP edge cases |
| `TOKENS=hs256-py` | 93 | 167 | 31.0k | C verify saves ~2 µs/req (224 → 1,280 ns per token single-thread) |
| `TOKENS=pyjwt` | 134 | 181 | 30.9k | 13.6 µs per token |
| `PASSWORD_HASHER=libxcrypt` | 132 | 163 | 30.9k | multi-lane bcrypt saves ~40 µs/req |
| `PASSWORD_HASHER=pyca` | 151 | 177 | 31.2k | |
| `DB_DRIVER=libpq-ctypes` | 95 | 181 | 31.3k | psycopg-c saves ~4 µs: most results are one JSON value, no row decoding |
| `DB_DRIVER=libpq-rows` (orjson) | 117 | 188 | 30.9k | bodies built in the app; no batched forms |
| `BROKER_BATCH=0` (JSON statements unbatched) | 105 | 200 | 30.2k | the like-for-like baseline for libpq-rows |
| `libpq-rows` + `JSON_CODEC=msgspec` / `pydantic` / `ujson` | 124 / 130 / 137 | 194–197 | 29.6k–30.0k | |
| `BROKER=0` (epoll / uvloop) | 147 / 133–155 | 277–287 | 27.3k–28.9k | p99 2.0–3.4 s |
| `DB_DRIVER=asyncpg HTTP_SERVER=uvloop PG_READERS=3` | 130–132 | 317–347 | 23.8k–25.2k | against BROKER=0; p50 150–220 ms (one query at a time per connection), 0.06–0.13% errors |

So Postgres building the JSON costs it about what building the bodies costs the app (rows: −12 µs Postgres, +12 µs app
against unbatched JSON), and batching only works on the JSON statements. asyncpg's statements cost Postgres as much as
libpq's on one connection (190 against 180 µs for a list page, with asyncpg's statement cache; explicit `prepare()`
with the cache off cost 490), but without pipelining each query is its own round trip and connections queue.

JSON codecs (`scripts/codeccheck.py`): every one writes the same JSON as orjson (rapidjson and yyjson escape control
characters in upper-case hex, so their bytes differ). A 20-article page, single-thread: orjson 6.8 µs, msgspec 18.6,
pydantic 36, yyjson 66, ujson 76, rapidjson 99, stdlib 108. Most accept some bodies orjson rejects (NaN, Infinity,
1e400, lone surrogates); yyjson decodes `\u` escapes wrongly. Tokens (`scripts/tokencheck.py`): the three verifiers
agree on 4,057 tokens.

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
  restarts). With `WORKERS=1` and `BROKER=0` nothing forks.

- **One Postgres process for all workers** (`pg_broker.py`, `BROKER=1`, the default). Postgres is most of the CPU per
  request, and much of a read's cost is work that other requests repeat at the same moment: the same list page, the
  same popular article, the same capped count. One statement over many requests does that work once, but only if the
  requests wait in one place, and each worker alone had 0–1 queries in flight. So a broker process owns every
  Postgres connection (`BROKER_READERS` read, default 8, and `BROKER_WRITERS` write, default 2), and each worker sends
  it its queries over a Unix socketpair made before the fork: one frame per loop pass, `marshal`-encoded. The broker
  queues reads by statement; when a read connection has nothing in flight, it takes the queue whose oldest request is
  oldest and runs it as one unit (see Data layer). At 20,000 test users this held 25.5k req/s at p95 121 ms, where the
  per-worker connections (`BROKER=0`) failed at 18.6k req/s with p95 1.3 s. At capacity (46,000 test users, ~55k req/s on
  a fresh seed copy) each message carries about 11 requests, and the worker side of the IPC costs about 0.8 µs per
  request (measured against a stub broker: 5.9 µs per request one at a time, 0.55 µs twenty at a time). The broker's
  event loop uses about half a core there, its two bcrypt threads about one core, each worker about 0.4 of a core.

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
  - With `BROKER=0`, each worker has 2 read pipelines (`PG_READERS`), and a query goes to the one with fewer in
    flight; writes go to a third, write pipeline. Every write is one statement (CTEs), so it is atomic on its own.
  - The three bcrypt routes (register, login, `PUT /api/user`, `offload=True` on the route) run on one helper thread
    per worker with its own connection, results handed back through a deque + `eventfd`, so a ~40 ms bcrypt doesn't
    stall the worker's other connections (the libxcrypt call releases the GIL).
  - With the broker, login (`broker=True` on the route) runs on the loop instead: it yields its user lookup and then
    its bcrypt to the broker, whose bcrypt threads (`BcryptBatcher`, `BCRYPT_THREADS`, default 2) hash up to 6
    logins from all workers at once. A lone login waits up to `BCRYPT_WAIT_MS` (default 100) for others; a second
    thread takes only full batches, when logins back up.
  - Postgres connections: the broker's 10 (8 read, 2 write) plus one per worker for the bcrypt helper, 16 in all (with `BROKER=0`: 4 per
    worker, 24). `main.py` refuses to start a configuration that could open more than 95. `PIPELINE=0` runs every
    query blocking on one connection instead.
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

  The broker runs a unit of queued requests in one of three ways:
  - **Batched statement** (`pg_repository.BATCHED`: global list from 4 requests, feed, author, tag and favorited
    lists from 2, article from 2, comments from 4):
    parameters are arrays with one element per request, the shared work runs once (an article's tags, favorites
    count and author once per distinct article; the list's capped count once per unit), and one body comes back per
    request. Single-connection Postgres time per request, batched against single, at 16 requests: global list 96 µs
    against 175, article 22 against 38, comments 12 against 21. The keys are looked up through `LATERAL ... LIMIT 1`
    and deduplicated from `unnest` of an array: the generic plan can't see that a CTE is small, so it merge-joined all
    of `articles` and sized a hash table for thousands of rows. `scripts/batchcheck.py` checks that every batched body
    is byte for byte the single statement's. If a batch fails, its requests run again one by one.
    In the list batches each request's count and page are its own (feed: per viewer; author, tag and favorited
    lists: per distinct key), the article data is built once for the union of the pages, and the pages are put together in one grouped
    join (a subquery per request scanned all the shared articles each time). The feed's cost is mostly per article,
    favorites counts above all (popular authors' articles have up to 2,000), so the batch saves the most when feeds
    overlap. The feed's capped count reads the author index once for all followees (`author_id = ANY (...)`, one
    index scan in PostgreSQL 17+) rather than once per followee: the same rows, ~20% less time for the count alone.
    Tag and favorited lists had measured 15–35% slower batched on a drifted local database; on fresh copies
    of the seed they are cheaper batched (Postgres 109 against 114 µs per request), so they are batched too.
  - **Shared** (tags, no parameters): one execution answers every request in the unit.
  - Anything else: pipelined single statements, one Sync each.

  Writes queue the same way. A unit of several writes is **one transaction** (group commit, rule 6): `BEGIN`, the
  statements, `COMMIT` behind one Sync, sharing one WAL flush; each reply goes out only after `COMMIT` returns. If any
  statement fails, the broker rolls back and runs each write again on its own, so only the one at fault gets the error.
  Committed one at a time, writes waited about 5 s at 20,000 test users; grouped, their p99 was under 100 ms.

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

From here on, measured on `conduit_full`, the complete seed (the earlier `conduit_lg` had only 117k of the ~2M follows
and 154k of the ~2.5M comments, so most feeds were empty). Each row is one run, `STAGES=0`:

| Version | Test users | req/s | p95 | p99 | Result |
|---|--:|--:|--:|--:|---|
| per-worker pipelines (`BROKER=0`) | 16,000 | 19,209 | 370 ms | 932 ms | pass |
| per-worker pipelines (`BROKER=0`) | 20,000 | 18,566 | 1,292 ms | 2,791 ms | fail |
| broker, batched reads, group commit (6 read connections) | 20,000 | 25,529 | 121 ms | 223 ms | pass |
| same, 8 read connections | 24,000 | 25,854 | 494 ms | 915 ms | pass |
| same, 6 read connections | 24,000 | 26,535 | 588 ms | 1,082 ms | fail |
| + batched feed and author lists (6 read connections) | 24,000 | 27,535–28,756 | 271–351 ms | 599–616 ms | pass (2/2; without: 0/2) |
| same | 28,000 | 29,694 | 443 ms | 957 ms | pass |
| same, 8 read connections | 28,000 | 27,499 | 608 ms | 1,001 ms | fail |
| + multi-lane bcrypt for logins, in the broker | 28,000 | 30,240–31,185 | 459–481 ms | 706–884 ms | pass (2/2; without: 0/2) |

From here on, each run is on a fresh copy of the exact seed (`TEMPLATE=conduit_box`, see "Measuring"): by then
`conduit_full` had drifted to 772k articles against the seed's 500k, which made Postgres 155–185 µs per request
there against 100–126 on fresh copies. Load spread over 3 loopback IPs, `STAGES=0`:

| Version | Test users | req/s | p95 | Result |
|---|--:|--:|--:|---|
| 6 read connections | 44,000 | 49,598 | 261 ms | pass |
| same | 48,000 | 46,357 | 566 ms | fail |
| same | 46,000 | 44,131–48,642 | 458–552 ms | 1 of 2 pass |
| 8 read connections (now the default) | 46,000 | 52,622–53,094 | 254–330 ms | 3 of 3 pass |
| same | 50,000 | 48,338–53,019 | 413–622 ms | 4 of 8 pass, Postgres 114 µs/req |
| + tag and favorited lists batched | 50,000 | 49,586–51,789 | 399–561 ms | 4 of 6 pass, Postgres 109 µs/req |

At 50,000 test users the laptop is at its edge (all 10 CPUs busy, the load generator included), so pass or fail
there is close to a coin flip; CPU per request is the steadier measure. At about 52k req/s a request costs about
70 µs of app CPU and 105 µs of Postgres CPU, all of it in the client backends (each of the 8 readers about 0.6 of a
core). bcrypt for logins is the largest single app cost, about 28% of app CPU (cost 10 is fixed by the rules; 6
lanes measured best); the rest is spread over socket I/O, the event loop and the handlers, a few µs each.

Per request at 8,000 test users (`cpusplit.sh`, two runs each): app + Postgres CPU went from 477–509k ns
(`BROKER=0`) to 389–407k with the broker on 2 read connections. At saturation (24,000 test users) Postgres used
about 4.7 cores, the workers about half a core each and the broker a quarter of one: the queue in front of the read
connections is where requests wait, and the unbatched statements (the feed above all) were the largest cost.
Batching the feed and author lists took Postgres from 161–174 to 143–146 µs per request at 24,000 test users.

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

All scripts need a local copy of the complete seed (`SEED_DB=conduit_box bash seed/make-seed.sh` from the repo
root, as a Postgres superuser; it must print `OK`) and the load generator at `/tmp/conduit-lg/loadgen`
(`go build -o /tmp/conduit-lg/loadgen ./cmd/loadgen` in `bench/`). Load runs change the database, and a database
that has absorbed many runs makes Postgres slower and drifts between runs, so compare runs on fresh copies:
`TEMPLATE=conduit_box` makes `cpusplit.sh` copy the template to `conduit_run` before each run (6.5 s), and `IPS=3`
spreads the load generator over 127.0.0.1–3 (one address has about 28,000 ephemeral ports). The checks take
`DATABASE_URL` (or a URL argument for batchcheck); otherwise they use `conduit_full`.

| Command | What it does |
|---|---|
| `bash scripts/loadtest.sh <label> <users> [WORKERS]` | scoring-style run: overall result, verdict, CPU split; JSON with a per-second timeline in `/tmp/conduit-lg/<label>.json` |
| `TEMPLATE=conduit_box IPS=3 STAGES=0 bash scripts/cpusplit.sh <users>` | app user/sys µs, Postgres µs and context switches per request on a fresh copy of the seed. Without `STAGES=0`, the per-stage ns table above too |
| `PYTHONPATH=. .venv/bin/python scripts/diffsql.py` | compares every Postgres-built response (reads, and writes inside rolled-back transactions) with the spec's reference SQL (should print 0 mismatches) |
| `PYTHONPATH=. .venv/bin/python scripts/batchcheck.py` | runs every batched statement and its single statement on the same random requests and compares the bytes (should print 0 mismatches) |
| `PYTHONPATH=. .venv/bin/python scripts/profile.py` | single-thread CPU per endpoint, plus cProfile output |
| `.venv/bin/python scripts/codeccheck.py`, `scripts/tokencheck.py` | every JSON codec / token adapter against the default |

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
