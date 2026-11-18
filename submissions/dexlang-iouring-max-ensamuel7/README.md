# DexLang (generated C, io_uring, read lanes)

Front: direct

| | |
|---|---|
| **Language** | [DexLang](https://github.com/ensamuel7/dex) `v0.9.30`: statically typed, compiles to C, which `cc` builds into a native binary |
| **Framework** | None. DexLang's own `http`, `db`, `json` and `crypto` standard library modules, and [dexqu](https://github.com/ensamuel7/dex-modules/tree/main/dexqu) `v0.2.0`, a SQL query builder written in Dex, for the SQL |
| **Server** | The `http` module's io_uring backend (`http.uring()`), one event loop per process, `http.fork(n)` processes sharing port 80 through `SO_REUSEPORT`, and `http.lanes(n, serve)` read processes behind them |
| **Postgres driver** | libpq (Ubuntu's `libpq-dev`), through the `db` module: prepared statements, one connection per process |
| **Password hashing** | bcrypt cost 10 through libxcrypt (`crypto.bcryptHash` / `crypto.bcryptVerify`) |
| **Build toolchain** | Go 1.27.2 to build the compiler, then `cc` (gcc 13) on the C it emits |
| **Nginx or direct** | **Direct**, on `0.0.0.0:80` |

What runs is one native binary: no interpreter, no garbage collector, no
framework. The program is `server.dx` (handlers, auth, JSON) and `queries.dx`
(the SQL, built with dexqu once at startup), and everything below it is the
language's standard library.

## How it serves

This is the same server as `dexlang-iouring-ensamuel7`, with one change: reads
are batched across every worker, not per worker.

**Workers.** `start.sh` runs two workers per core (`WORKERS`, 16 on the 8-core
box). The server calls `http.fork(16)`; each copy opens its own Postgres
connection for writes and logins and listens on port 80 with `SO_REUSEPORT`, so
the kernel spreads connections across them.

**Read lanes.** Before forking the workers, the server calls
`http.lanes(6, serve)`, which starts six lane processes. Each lane listens on its
own unix socket and owns one Postgres connection with the batched read
statements prepared. A read handler (`/api/tags`, `/api/user`, a profile, an
article, its comments, and every list and feed) checks its input, then
`http.relay(lane, payload)` sends the request to its lane and the worker goes
on serving other connections. Each kind of read has its own lane, so nothing
waits behind a slower kind:

| lane | reads |
|--:|---|
| 0 | global, by tag, by author, favorited lists |
| 1 | feed |
| 2 | comments |
| 3 | article |
| 4 | tags |
| 5 | profile, current user |

A lane collects requests from all 16 workers for 20 ms (`http.batchWindow(20)`,
`BATCH_MS`) from its first request, then calls `serve` with the batch. `serve`
runs one statement per kind of read with the requests as arrays
(`unnest($1::int4[], $2::int8[], ...)`) and answers each request with
`http.reply()`. The answer goes back over the socket to the worker holding the
connection, which sends it. Every request still gets its own rows from that
statement, read while it is being served: nothing is kept after the batch.

One lane batch takes in what used to be 16 separate worker batches, so a
distinct filter, page or article is read once for the whole box rather than
once per worker. If a lane process dies, the requests waiting on it are
answered 503, and the lane is not restarted.

**Writes and logins answer at once.** Writes run on the worker's connection as
they arrive, each committed before its response. A bcrypt login (about 60 ms of
CPU) holds only its own worker. That's 16 worker connections and 6 lane
connections, well under the 95 allowed.

**io_uring with direct descriptors**: accepts, receives and sends are queued on
a ring and submitted together, receives use a kernel buffer ring, and an idle
keep-alive connection holds no read buffer. The idle timeout is 75 s.

## The SQL

The responses are exactly the reference SQL's. Every statement is built with
dexqu when the server starts, then prepared once. A read is built once from its
arguments as expressions: the per-request form gets named parameters
(`q.param("viewer")`), and the batched form gets the request's row from
`unnest` (`q.col("r.v")`), so a batch runs the same query for each request.
Fixed limits stay literal SQL (`q.raw("1000")`) so they don't become parameters
the planner has to guess at. The dexqu port returned the same rows as the
hand-written SQL it replaced in 760 random comparisons. Each rewrite of a list or
article query was run against the reference statement over the same 300 random
parameter sets on the full seed and compared byte for byte, and the shared list
statements against the per-request ones over 300 random batches.

- **A list batch shares what its requests share.** One statement per list kind
  counts each distinct filter once, cuts each distinct page once, and decorates
  each distinct article once (tags, favorite count, author). Only the
  `favorited` and `following` flags are per request.
- **Pick the page first, then decorate it.** The reference list query computes
  tags, favorite counts and both `EXISTS` for every row `OFFSET` skips. Each
  list here selects the page's ids first, from the index that orders it, and
  decorates only those rows.
- **Tags by key.** `ARRAY(SELECT (SELECT name FROM tags WHERE id = at.tag_id) …
  ORDER BY 1)` looks each tag up through `tags_pkey`.
- **One statement for comments.** The article lookup and its newest 100
  comments are one `LEFT JOIN LATERAL`: no row means 404, a row without a
  comment means an empty list.
- **Session settings only.** The connection adds `sslmode=disable`, and sets
  `TimeZone=UTC`, `DateStyle=ISO`, `jit=off` and
  `plan_cache_mode=force_generic_plan` for its own session. A batched
  statement's estimated cost is high enough that Postgres would otherwise
  JIT-compile every execution, about 300 ms of compiling for 10 ms of work.
  Its parameters are arrays, so a custom plan is no better than the generic
  one, and planning it again on every execution was about 17% of Postgres
  CPU.

Article creation runs in one transaction (`BEGIN`, insert, tags, article tags,
`COMMIT`, rolled back on any failure). Unique violations (SQLSTATE 23505) are
422, read with `db.errorCode()`. Nothing is cached: every request reads
Postgres, and every login runs bcrypt against the stored hash.

## Auth

HS256 is verified on every request by recomputing the MAC in base64url and
comparing it in constant time. `alg` must be HS256, `exp` is required, and `sub`
must be a positive integer. New tokens carry `sub`, `iat` and `exp` (30 days).

## Measured

Full seed, a 4-vCPU Synteq VPS (Xeon Platinum 8260) running both the server and
Postgres 18 configured by `box/pg-conf.sh`, the challenge's `loadgen` on two
other boxes, 42,000 users, 60 s ramp and 60 s measured, 8 workers:

| version | req/s | p50 | p95 | p99 | errors | box CPU | server | Postgres |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| per-worker batches (`dexlang-iouring-ensamuel7`) | 10,751 | | 249 ms | 326 ms | 0% | 86% | 34% | 51% |
| read lanes | 11,008 | 33 ms | 161 ms | 410 ms | 0% | 80% | 37% | 42% |

At the same load the lanes take Postgres from 51% of the box to 42%, and p95
from 249 to 161 ms. p99 rose because lane 0 runs its four list statements one
after another for each batch. Past about 45,000 users the two load boxes ran
out of CPU, so the 4-vCPU ceiling was not reached.

## What the language gained from this challenge

- `http.lanes(n, serve)` and `http.relay(lane, payload)` (v0.9.30): lane
  processes that batch requests from every worker. A lane answers with the
  same `http.reply()` a worker uses.
- A program that imports `http` no longer starts its thread pool before
  `http.fork`. Forked children inherited a pool whose threads didn't exist,
  which could deadlock under AddressSanitizer; the pool now starts on the
  first `spawn`.
- dexqu (v0.2.0): `LATERAL` joins, `MATERIALIZED` CTEs, column-list aliases
  such as `unnest(...) AS r(i, v)`, `ARRAY(SELECT ...)`, array casts,
  `returningExpr` on INSERT, and `Query.slots(name)` to bind a prepared
  statement by parameter name.

- `http.hold()` and `http.reply()`: a handler takes a ticket for its request,
  and the batch hook answers it, so one query serves a whole batch.
- `http.batchWindow(ms)`: under io_uring, a batch gathers requests across
  passes of the loop until its first request is `ms` old.
- `http.fork(n)`: split a program into `n` processes sharing one listening port,
  so each opens its own database connection before `listen`.
- `db.bindNull`, `db.isNull` (to tell `NULL` from `""` for `bio` and `image`),
  `db.affected`, and `db.errorCode()` (the SQLSTATE of the last statement).
- Binding a Postgres parameter past the eighth no longer freed uninitialised
  memory.
- `crypto.bcryptHash` and `crypto.bcryptVerify`.
- `json.encode` writes `string?` and other optional fields as `null` or their
  value. It used to write a raw pointer.
- Functions named after C keywords (`register`) compile.

## Files

```
server.dx    routes, handlers, auth, JSON
queries.dx   the SQL, built with dexqu
dex.mod      module file: dex 0.9.30, requires dexqu v0.2.0
dex.sum      dexqu's checksum
install.sh   root, once: build-essential, pkg-config, libpq-dev, libcrypt-dev,
             libssl-dev, libcurl, libsqlite3-dev, and Go 1.27.2 (sha256-checked)
build.sh     builds the dex compiler from the pinned v0.9.30 tag through the Go
             module proxy (checksum-verified), downloads dexqu (checked
             against dex.sum), then compiles server.dx
start.sh     raises the open-file limit and runs two workers per core
```
