# C + io_uring, no framework

**Front: direct.** The server listens on `0.0.0.0:80` itself and holds every user's keep-alive connection, so
none of the box's CPU goes to Nginx.

| Piece | Version |
|---|---|
| Language | C (gnu11), GCC 13.3 from Ubuntu 24.04 (`build-essential`) |
| I/O | io_uring via liburing 2.5 (Ubuntu 24.04 `liburing-dev`) |
| HTTP/1.1, JSON, JWT (HS256), SHA-256 | hand-written, in `src/` |
| Postgres driver | hand-written wire-protocol v3 client (`src/pg.c`): SCRAM-SHA-256, prepared statements, pipelining |
| bcrypt | `src/bcrypt.c` (4-lane interleaved, see below), libxcrypt 4.4.36 as the fallback for other hash formats |

`install.sh` installs `build-essential liburing-dev libcrypt-dev` from the Ubuntu archive. `build.sh` is a single
`gcc` call. `start.sh` runs `bin/conduit`, configured by `DATABASE_URL`, `JWT_SECRET`, `HOST` and `PORT`.

## Design

The CPU budget is the whole game: Postgres, bcrypt and the server share 8 vCPUs, and the score is the number of
users the box serves before p95/p99 break. So the server is built to cost as little as possible per request and
per idle connection, and to make each request cost Postgres as little as possible.

- **Event loops: 2 threads, each with its own io_uring, its own `SO_REUSEPORT` listener and its own Postgres
  connections.** Nothing is shared between them. Accepts are multishot. Each connection has one multishot
  readiness poll and is read with `recv()` into the thread's scratch buffer, so an idle keep-alive connection
  owns no buffer: about 200 bytes of user memory per connection (80,000 connections: 17 MB RSS).
  Provided-buffer rings would save the `recv()`, but the Ubuntu 24.04 kernel (6.8.0-142) rejects them.
- **One Postgres round trip per request.** Each request's statements go out as one batch (Bind/Execute per
  statement, one Sync), and batches from many requests are pipelined on the same connection without waiting
  for each other's replies. Each batch is its own implicit transaction, committed at its Sync, and the response
  is sent only after Postgres's ReadyForQuery for it, so writes are committed before we answer (rule 6).
- **Every statement is prepared once per connection at startup**, results come back in text format, and rows
  are copied straight into the JSON response (timestamps reformatted, `text[]` turned into a JSON array).
- **bcrypt runs on its own threads** so a ~45 ms hash never stalls an event loop.

## Postgres: where the CPU goes and what was done about it

Measured with `pg_stat_statements` (on a dev copy only), `pgbench` A/B runs of each variant and `perf` on the
backends under load. All rewrites return the same answers as SPEC.md's SQL: besides the 197 conformance checks,
a differential test sends 1,742 read requests (all list filters, deep offsets, the heaviest feeds, anonymous and
logged in) to the Go reference and to this server on the same full-seed database and compares the JSON: 0
differences.

- **Lists are one statement, and the per-article subqueries run only for the rows returned.** SPEC's list query
  computes tags, favorite count and the two `EXISTS` for every row the index walk produces, including the rows
  `OFFSET` then throws away (page 5 evaluates them for 50 rows to return 10). Here the page's article ids are
  picked first (`LIMIT/OFFSET` on the bare index walk, in a `LATERAL` subquery) and the subqueries run for those
  10 rows only. The capped count is in the same statement. pgbench: 1.7x the throughput of SPEC's pair.
- **Tag names by primary key.** `ARRAY(SELECT t.name FROM article_tags at JOIN tags t ...)` gets a generic plan
  that hashes all 200 tags for every article; `ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)
  ...)` does two index probes per tag. This alone is 1.33x on list throughput.
- **Look-up-then-act pairs travel together**: favorite/unfavorite (write, then the article), follow, delete
  article/comment (owner check, then the guarded delete), update article (one `UPDATE ... RETURNING` CTE that
  also reads the tags/favorites/follows it doesn't modify), create comment (`INSERT ... SELECT` from the slug), and
  create article (insert, tags, article_tags via `currval`, then the article, all before one Sync). Comments are
  one statement (`LEFT JOIN LATERAL`), so a missing article and an empty thread are told apart without a second
  query.
- **Session settings on our own connections** (sent in the startup message; allowed by rule 2):
  `plan_cache_mode = force_generic_plan` (Postgres otherwise keeps re-planning several statements; pgbench A/B:
  +41% list, +12% article throughput), `jit = off`, `max_parallel_workers_per_gather = 0`.
- **Fewer connections than allowed: 4 per vCPU (32 on the box).** Each connection is a Postgres process
  competing for the same cores; on 6 CPUs, 24 connections beat 16 (idle CPU) and 48/90 (lower throughput, higher
  p99, and bcrypt starved into timeouts).

What's left in Postgres is real query work: `perf` shows 85% of its CPU in the executor (B-tree descents, buffer
lookups) and 9% in the kernel. Tried and dropped: letting several read-only requests share one Sync
(transaction + flush per group instead of per request). It saved no CPU in the full system and serialized reads
on one backend, raising p99.

## bcrypt: 4 hashes per core at once

Logins grow with users (each user starts a session every ~15 minutes; a quarter of those log in), so at the
user counts this server reaches, cost-10 bcrypt is about a third of all CPU after Postgres's share. A bcrypt hash
is ~1.07 million Blowfish encryptions, each a chain of dependent table lookups, so one hash leaves most of a core
idle waiting on load latency. `src/bcrypt.c` computes up to 4 independent hashes at once in one thread,
interleaving their encryptions so the chains overlap: on an i5-9500, 23.9 ms of CPU per hash instead of
libxcrypt's 46 ms. Every hash is still full bcrypt at cost 10 and every login is verified against its stored
hash (rule 7); only the scheduling changes. One bcrypt thread at a time lets a login wait up to 150 ms for others
to fill its batch (logins are ~0.1% of requests; the wait buys CPU for everything else).
`bin/conduit --bcrypt-selftest` checks it against libxcrypt on random passwords and salts.

## Results so far (not the official box)

Ubuntu 24.04 VM (kernel 6.8.0-142, Postgres 18 and Nginx set up by `box/setup-box.sh`, full seed) on an
Intel i5-9500, 6 vCPUs: Postgres + server pinned to 4, the load generators to 2.

| Users (think time) | Open connections | req/s | p50 | p95 | p99 | errors | server RSS |
|---|---|---|---|---|---|---|---|
| 6,000 (x0.1) | 6,000 | 14,548 | 32 ms | 75 ms | 97 ms | 0 | 10 MB |
| 80,000 (x2) | 80,000 | 10,615 | 1.1 ms | 5.9 ms | 11.8 ms | 0 | 17 MB |
| 150,000 (x4) | ~149,000 | 9,952 | 1.0 ms | 5.1 ms | 11.5 ms | 0 | 28 MB |

On these 4 cores the ceiling is about 14k req/s, CPU-bound (~73% Postgres, ~14% bcrypt, ~13% kernel TCP; this
server's own code is a few percent). At the real 7 s think time that is roughly 55k users per 4 such cores.
Connections cost almost nothing, so on the 8-vCPU box the limit is CPU, not the connection count; the hard cap
is the unit's `LimitNOFILE=200000`.

## Tuning knobs (environment, all optional)

| Variable | Default | Meaning |
|---|---|---|
| `THREADS` | 2 (1 below 4 CPUs) | event-loop threads |
| `DB_CONNS` | 4 x CPUs, max 95 | Postgres connections, split over the threads |
| `BCRYPT_THREADS` | CPUs / 2 | bcrypt threads |
| `BCRYPT_LANES` | 4 | hashes per bcrypt batch |
| `BCRYPT_WAIT_MS` | 150 | how long a login may wait for its batch to fill |
| `PG_SESSION` | `plan_cache_mode=force_generic_plan,jit=off,max_parallel_workers_per_gather=0` | session settings |

## Rules

No data is cached across requests (the only things kept are connections, prepared statements and the HMAC key
schedule of `JWT_SECRET`). Every request reads Postgres while it is served; every token's signature and `exp` are
checked on every request; every password is hashed with bcrypt cost 10 and every login verified against the
stored hash; writes are committed before the response. Nothing outside our own connections is changed: only
session-level settings, no schema or server changes.
