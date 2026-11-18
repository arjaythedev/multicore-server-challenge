# Conduit API in Python

Front: direct

uvloop + httptools + asyncpg + orjson, no web framework. The server listens on `$HOST:$PORT` itself (`0.0.0.0:80` on
the box) and holds every user's keep-alive connection, so the ~11% of the CPU that Nginx would use is left for the app
and Postgres.

It passes all 197 conformance steps on Postgres 16 and 18, and the normalized transcript is byte-identical to
`bench/cmd/conformance/golden-dev.jsonl`.

## Versions

Pinned in `requirements.txt` (made from `requirements.in`).

* CPython 3.14.6, from python-build-standalone via uv 0.11.32. `install.sh` checks the uv tarball's SHA-256.
* uvloop 0.23.0
* httptools 0.9.0, under a hand-written `asyncio.Protocol` (`conduit/httpd.py`)
* asyncpg 0.32.0
* orjson 3.13.0 for request bodies, user objects and JWT claims. Article, comment and profile JSON is built by Postgres.
* bcrypt 5.0.0 (pyca), cost 10
* JWT: HS256 checked in `conduit/auth.py` with `hmac` and `orjson`, no JWT library

All of them have cp314 wheels, so `build.sh` never needs a compiler.

## Processes and connections

`python -m conduit` is a supervisor that forks the workers, about 3 per 4 CPUs, so 6 on the 8 vCPU box. A worker is a
single-threaded uvloop event loop with its own `SO_REUSEPORT` socket, so the kernel spreads connections over the
workers (24,000 idle connections split 8,000 each over 3 workers), and with its own Postgres connections, 4 per CPU in
total (30 on the box, well under the 95 allowed). A worker that dies is restarted. bcrypt takes about 78 ms of CPU per
hash and runs in a 2-thread pool per worker. pyca/bcrypt releases the GIL, so hashing doesn't block the event loop.

I kept the connection count low on purpose. Under the same overload Postgres used 7-10% less CPU per request with 4
connections per core than with 10-12, since fewer backends are runnable at once. On the 4 vCPU test VM 2 to 4 workers
were within noise of each other and 6 to 8 were slightly worse, which is why it's 3/4 of the CPUs.

Nothing is hard-coded for 8 vCPUs. Workers and connections come from `os.process_cpu_count()` (so affinity and cpusets
count) with the ratios fixed: at least 2 workers, never more than 90 connections in total.

| vCPUs | workers | connections per worker | connections in total |
|---|---|---|---|
| 1 | 2 | 2 | 4 |
| 2 | 2 | 4 | 8 |
| 4 | 3 | 5 | 15 |
| 8 | 6 | 5 | 30 |
| 16 | 12 | 5 | 60 |
| 32 | 24 | 3 | 72 |
| 64+ | 45 | 2 | 90 |

`workers x connections <= 90` holds for every CPU count from 1 to 129, and the `WORKERS` / `DB_CONNECTIONS` overrides
(for local experiments, not set on the box) are capped the same way. I could only measure up to 4 vCPUs. With the
server and Postgres confined to 2 CPUs with `taskset` it started 2 workers and 8 connections and sustained ~3.5k req/s,
which is ~1.75k per CPU, the same as on 4 vCPUs. One CPU gave ~1.6k req/s. So the 8 vCPU numbers are extrapolated, not
measured.

RAM needs no tuning. A worker uses ~35 MB, an idle keep-alive connection ~2.5 KB (50k users is ~125 MB), and Postgres's
4 GB of `shared_buffers` plus the page cache hold the whole 2.35 GB database.

## Where the speed comes from

1. One round trip, and finished JSON. The reference runs 2-3 statements per request. Here every hot endpoint is one
   statement, and the read endpoints return the finished document: `json_build_object` / `json_agg` build it inside
   Postgres, asyncpg returns the bytes unparsed (a pass-through codec for `json`) and they go to the socket as they
   are. Python never decodes a row or runs a JSON encoder on a read path. I measured the alternative, fetching rows and
   encoding with orjson: its Python side costs ~3x as much as Postgres building the JSON does.
2. No TLS to Postgres (`ssl=False`). asyncpg's default (`prefer`) negotiates TLS with Ubuntu's Postgres even on
   loopback, and then every query and result is encrypted at both ends. Turning it off saved ~20% of the app's CPU and
   ~8% of Postgres's.
3. Generic plans (`plan_cache_mode = force_generic_plan`, set per session on our own connections). Planning these
   statements takes longer than running them (0.8-3 ms against ~0.5 ms) and `auto` kept re-planning. I checked the
   generic plan of every statement with `EXPLAIN (GENERIC_PLAN)` on Postgres 16 and 18: index-driven nested loops, no
   seq scans or hash joins. The sessions also get `jit = off` and `max_parallel_workers_per_gather = 0`.
4. The page size is a literal in the list statements. With `LIMIT $n` a generic plan has to assume a page is 10% of the
   table, and then a hash join over a seq scan of `users` comes within 1% of the estimated cost of the index probes a
   10-row page really needs, although it's ~100x slower. I saw the planner sit right on that edge. So each list
   statement carries its `LIMIT` (one prepared statement per distinct `limit`, and clients use a handful) and the
   nested loop wins by a huge margin whatever `ANALYZE` samples. Throughput is the same as with the parameter.
5. Cheaper SQL with the same answers (compared with the reference SQL, see below):
   * The per-article sub-selects of the list queries run for the rows of the page only, not for the rows `OFFSET`
     skips (the reference runs them for those too). The global and author lists read the page's columns straight from
     the index scan instead of probing `articles` again.
   * Tag names come from a scalar sub-select per `article_tags` row, an index probe on `tags_pkey`. A join there got
     turned into a seq scan plus a hash of all 200 tags for every article.
   * The feed skips the `author.following` look-up, because it's true for every row.
   * The capped count is `CASE WHEN EXISTS (... OFFSET 999 LIMIT 1) THEN 1000 ELSE count(*)`. Skipping 999 index
     entries is cheaper than aggregating 1,000.
   * Favorite, follow and comment writes are single statements with data-modifying CTEs. Since we know the viewer's row
     exists afterwards (or doesn't), `favoritesCount` is "everyone else" plus or minus the viewer.
   * `POST /api/articles` inserts new tags in name order, so two publishes with overlapping new tags can't deadlock.
6. A thin HTTP layer. One `HttpProtocol` per connection, status lines and headers prebuilt, one `transport.write` per
   response, and an eager task start so the handler runs straight away up to its first wait on the database. It
   answers pipelined requests in order and handles `Expect: 100-continue`, chunked bodies, an early 413 for oversized
   bodies, and closes connections that were idle for 5 minutes. Routing is a few `bytes` comparisons. HTTP and routing
   together cost ~20 us of CPU per request.
7. JWT in ~4 us: `hmac.digest` (OpenSSL one-shot) over the signing input, `binascii` for base64url, claims through
   orjson. The signature, `alg = HS256`, `exp` and `nbf` (if present) are checked on every request.
8. After start-up everything is `gc.freeze()`d and the gen-0 threshold is raised, so the collector doesn't walk the
   code and connection state while serving. Worker RSS stayed flat at 33 MB over 880k requests.

## Numbers

These are from my 4 vCPU test VM, not the box. The load generator, the server and Postgres all share those 4 vCPUs, so
read them as relative numbers, not a prediction of the score. Full seed, `loadgen run` with `-think-scale 0.2` (think
times and sessions 5x shorter, so the same mix at 5x the request rate per user), 30 s measured, Postgres 18.6 with SSL
on as Ubuntu ships it, and the config from `box/pg-conf.sh`:

| 5,400 users at 5x speed | req/s | p50 | p95 | p99 | pass? |
|---|---|---|---|---|---|
| `examples/go` (direct, no Nginx) | 4,087 - 4,147 | 560 - 590 ms | 860 - 900 ms | 1.09 - 1.10 s | no |
| this server | 6,364 - 6,421 | 78 - 80 ms | 185 - 215 ms | 240 - 290 ms | yes |

That's ~1.55x the Go example's throughput on the same machine: ~550 us of CPU per request (Postgres ~330, the app ~220)
against ~850 us. Of the app's ~220 us, ~120 us is Python and ~100 us is bcrypt. At the workload's login rate (24.5% of
sessions log in, one hash each) bcrypt alone is about 15% of the server's CPU, and rule 7 doesn't let me make it
cheaper.

## What didn't help

* Fetching rows and building the JSON in Python with orjson. It uses more CPU in total than Postgres-built JSON.
* A set-based list query (page ids first, then `= ANY(array)` scans for tags, favorites and follows). The generic plan
  falls apart into seq scans and merge joins and is ~80x slower. Correlated sub-selects hold up.
* Planner switches (`enable_memoize`, `enable_hashjoin`, ...). No consistent gain, and one setting produced a 45 ms plan.
* More Postgres connections or more workers than above, lowering the priority of the bcrypt threads (worse tail
  latency), and libxcrypt's bcrypt instead of pyca's (same speed).

## The rules

1. Python, no framework.
2. Postgres 18 is the only peer. The only dependencies are asyncpg, bcrypt, httptools, orjson and uvloop. The only
   server settings used are session-level ones, passed as connection start-up parameters (`jit`, `TimeZone`,
   `plan_cache_mode`, `max_parallel_workers_per_gather`, `application_name`). No `ALTER SYSTEM`, no
   `ALTER DATABASE|ROLE ... SET`. The connection count is capped at 90 whatever the environment says. I counted it in
   `pg_stat_activity`.
3. Only `SELECT` / `INSERT` / `UPDATE` / `DELETE` on the existing tables (see `conduit/sql.py`). No DDL, extensions or
   functions, and `grep` finds no `CREATE|ALTER|DROP|TRUNCATE|GRANT` in the code.
4. 197/197 on Postgres 16 and 18 with `test/run.sh` after `install.sh`, transcript identical to `golden-dev.jsonl`.
5. See the next section.
6. Every write is an autocommit statement, or for `POST /api/articles` one explicit transaction whose `COMMIT` is
   awaited. `synchronous_commit` is never touched, nothing is unlogged, and there's no group commit. asyncpg finishes
   a statement only when Postgres has answered `ReadyForQuery`, which is after the commit. I tested it by crashing:
   right after the response to each of 7 kinds of write (comment, favorite, unfavorite, follow, article with tags,
   `PUT /api/user`, registration) I `kill -9`'d the postmaster and restarted it. Every write survived, while a control
   run with `synchronous_commit = off` lost the commit in 5 of 5 rounds. No app session is ever left
   `idle in transaction`.
7. bcrypt cost 10 for every registration, password change and login. The stored hashes are `$2b$10$...` with a salt
   per user, and a password over 72 bytes is refused, not truncated. A login compares against the hash that is in the
   table at that moment. Every token's HS256 signature and `exp` are checked on every request. `alg` has to be `HS256`
   (`none`, HS384, RS256, `hs256` and a missing `alg` all give 401). A token without `exp`, with a string `exp`, with a
   `sub` that isn't a plain decimal number above zero, or not sent as `Token <jwt>` gets 401 as well.
8. Nothing in the code mentions the load generator, seeded users or any data value. The only constants in responses are
   error messages, and the booleans described below, which SQL works out. `grep` finds none of `loadgen`,
   `password123`, `user-agent`.
9. 6 workers x ~35 MB. 24,000 idle connections cost another ~60 MB.
10. `Front: direct`, at the top of this file.
11. `install.sh` (as root) installs uv 0.11.32 from its GitHub release with the SHA-256 checked, and CPython 3.14.6.
    `build.sh` (normal user) runs `uv pip sync` on the 5 pinned wheels in `requirements.txt`, which have no
    dependencies of their own. Nothing prebuilt is committed. `GET /api/tags` answers about a second after `start.sh`.
12. No sysctl, CPU pinning or priorities. Only in-process settings: pool sizes, worker and thread counts, GC thresholds.

## Rule 5: what survives a request

This is everything that outlives a request:

| What | Why it's allowed |
|---|---|
| The Postgres connections (a stack per worker) and the queue of requests waiting for one | "Connection pools ... are fine" |
| asyncpg's prepared statements, and the generic plans Postgres keeps for them | "prepared statements ... cache ... query plans, not data" |
| The statement text for each page size from 1 to 100, built once at import into an immutable tuple | It's query text, what a prepared statement is made from |
| Constants: error messages, status lines, the JWT secret, the bcrypt cost | Not data from the database |
| The HTTP `Date:` header string, refreshed once a second | A clock |
| The HTTP parser state of a connection (url, `Authorization`, body) | Reset at the start of every message, so a token can't carry over to the next request on that connection. I tested that. |

No dict, list or set holds rows, responses, tokens, user ids or hashes. There's no memoization, no request coalescing
and no "last seen" anything. A JWT is parsed, its HMAC recomputed and its `exp` compared with the clock on every
request. Every login runs `bcrypt.checkpw` against the `password_hash` that request read from `users`. Every response
body comes from a Postgres statement run for that request.

A few response values are worked out in SQL instead of being read back. They're all computed inside the statement from
rows that statement read, which "any SQL you like" allows:

* favorite / unfavorite: a statement can't see its own write, so `favoritesCount` is the count of other users' rows
  from `favorites` plus or minus the viewer, and `favorited` is the known state afterwards.
* follow / unfollow: `following` is the state afterwards, as in the spec. For a new comment `author.following` is
  `false`, as in the spec.
* the feed: every row is there because the viewer follows its author, so `author.following` is `true`.

I also wrote a script to test this from the outside. It isn't part of the submission. It had 76 checks, run against a
live server on a throwaway copy of the dev seed. Each check changes Postgres behind the server's back with plain SQL
and needs the very next request, on a keep-alive connection that had just seen the old value, to see the change. It
covered tags added and removed, an article's title, body, slug and favorites, articles inserted and deleted straight in
the table (global, tag, author and favorited lists), follows (profile and feed), comments inserted, edited and deleted,
a user's bio and email, a user deleted while holding a valid token (401 at once), a user's `password_hash` replaced
(old password 401 at once, new one 200), a token that was accepted and 2 s later rejected on `exp`, and a valid token
followed by a tampered copy followed by the valid one again. It also counted statement executions in
`pg_stat_statements`: 200 identical requests to each read endpoint cause at least 200 executions, and 20 identical
logins cost 1.5 s of server CPU (20 bcrypt verifications at ~78 ms), not 0.
