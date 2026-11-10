# DexLang (generated C, io_uring)

Front: direct

| | |
|---|---|
| **Language** | [DexLang](https://github.com/ensamuel7/dex) `v0.9.35`: statically typed, compiles to C, which `cc` builds into a native binary |
| **Framework** | None. DexLang's own `http`, `db`, `json` and `crypto` standard library modules, and [dexqu](https://github.com/ensamuel7/dex-modules/tree/main/dexqu) `v0.2.0`, a SQL query builder written in Dex, for the SQL |
| **Server** | The `http` module's io_uring backend (`http.uring()`), one event loop per process, `http.fork(n)` processes sharing port 80 through `SO_REUSEPORT` |
| **Postgres driver** | libpq (Ubuntu's `libpq-dev`), through the `db` module: prepared statements, one connection per process |
| **Password hashing** | bcrypt cost 10: `crypto.bcryptHash` through libxcrypt, logins checked with `crypto.bcryptVerifyAll` (several passwords side by side) |
| **Build toolchain** | Go 1.27.2 to build the compiler, then `cc` (gcc 13) on the C it emits |
| **Nginx or direct** | **Direct**, on `0.0.0.0:80` |

What runs is one native binary: no interpreter, no garbage collector, no
framework. The program is `server.dx` (handlers, auth, JSON) and `queries.dx`
(the SQL, built with dexqu once at startup), and everything below it is the
language's standard library.

## How it serves

**Processes, not threads.** `start.sh` runs two workers per core (`WORKERS`, 16
on the 8-core box). Before opening anything, the server calls `http.fork(16)`;
each copy then opens its own Postgres connection, prepares its statements and
listens on port 80 with `SO_REUSEPORT`, so the kernel spreads connections across
them. A worker owns its sockets, its connection and its statements outright:
there is no lock, no pool and no handoff anywhere on a request's path. 16
connections stay well under the 95 allowed.

**Reads are answered in batches.** A read handler (`/api/tags`, `/api/user`, a
profile, an article, its comments, and every list and feed) checks its input,
takes a ticket with `http.hold()` and queues what it needs. A worker's batch
stays open for 80 ms from its first request (`http.batchWindow(80)`, `BATCH_MS`),
then the `http.afterBatch` hook runs one statement per kind of read for the
whole batch, with the requests as arrays (`unnest($1::int4[], $2::int8[], ...)`),
and answers each ticket with `http.reply()`. Every request still gets its own
rows from that statement, read while it is being served: nothing is kept after
the batch.

**Writes answer at once.** Writes run on the worker's connection as they
arrive, each committed before its response.

**Logins go to two login lanes.** A bcrypt check is about 60 ms of CPU, and at
this load logins were the largest single cost in the server. Two extra
processes (`http.lanes(2, ...)`, `LOGIN_LANES`) take every worker's logins
through `http.relay()`, the workers taking turns between them. A lane gathers
logins for up to 150 ms (`LOGIN_MS`), looks each user up, then checks the whole
set with `crypto.bcryptVerifyAll`. That runs a full bcrypt cost 10 against each
stored hash, with the Blowfish rounds of several passwords interleaved, so four
passwords take 23 ms of CPU each instead of 64 ms. Every login is still
verified against its own stored hash; nothing about a login is kept.

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
- **The feed knows `following`.** Every feed article is by an author the
  viewer follows, picked through `follows` in the same statement, so
  `following` is `true` without a lookup. The other lists still check it.
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
other boxes, 60 s ramp and 60 s measured, 8 workers:

| version | users | req/s | p95 | p99 | errors | box CPU | |
|---|--:|--:|--:|--:|--:|--:|---|
| one statement per request | 27,000 | 6,926 | 341 ms | 497 ms | 0% | 100% | pass |
| one statement per request | 30,000 | 6,899 | 1,143 ms | 1,402 ms | 0% | 100% | fail |
| batched | 42,000 | 10,723 | 269 ms | 349 ms | 0% | 88% | pass |
| batched, generic plans | 42,000 | 10,751 | 249 ms | 326 ms | 0% | 86% | pass |

The two batched rows ran back to back. At 42,000 users generic plans take
Postgres from 54% of the box to 51%, with the server at 34%, about half of that
bcrypt. Past about 45,000 users the two load boxes ran out of CPU, so the
4-vCPU ceiling was not reached. The batched version without generic plans
scored 76,000 users on the benchmark box (#176).

### Login lanes (4-vCPU box)

The same 4-vCPU box with 16 workers, `loadgen -think-scale 0.1`, 30 s ramp and
60 s measured. The database's files are read into the page cache before each
run, as on the 16 GB benchmark box, where the whole database stays in RAM:

| version | users | req/s | p95 | p99 | errors | |
|---|--:|--:|--:|--:|--:|---|
| batched, generic plans | 8,000 | 12,909 | 462 ms | 620 ms | 0% | pass |
| batched, generic plans | 10,000 | 12,363 | 812 ms | 1,140 ms | 0% | fail |
| login lanes | 8,000 | 15,004 | 229 ms | 282 ms | 0% | pass |
| login lanes | 10,000 | 16,219 | 368 ms | 449 ms | 0% | pass |
| login lanes, feed `following` | 10,000 | 16,136 | 371 ms | 452 ms | 0% | pass |

At 10,000 users the box is out of CPU (server about 1.4 cores, Postgres about
2.4), so the feed change, which makes the feed statement 5 to 7% cheaper,
doesn't move the latency.

## What the language gained from this challenge

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
- `crypto.bcryptVerifyAll` (v0.9.35): bcrypt for several passwords at once,
  the lanes interleaved, at 2.7 times the throughput of one at a time, with the
  same answers as `bcryptVerify`.
- `http.lanes(n, fn)` and `http.relay(lane, payload)`: extra processes that
  every worker can hand a request to, each answering its own batch.
- `json.encode` writes `string?` and other optional fields as `null` or their
  value. It used to write a raw pointer.
- Functions named after C keywords (`register`) compile.

## Files

```
server.dx    routes, handlers, auth, JSON
queries.dx   the SQL, built with dexqu
dex.mod      module file: dex 0.9.35, requires dexqu v0.2.0
dex.sum      dexqu's checksum
install.sh   root, once: build-essential, pkg-config, libpq-dev, libcrypt-dev,
             libssl-dev, libcurl, libsqlite3-dev, and Go 1.27.2 (sha256-checked)
build.sh     builds the dex compiler from the pinned v0.9.35 tag through the Go
             module proxy (checksum-verified), downloads dexqu (checked
             against dex.sum), then compiles server.dx
start.sh     raises the open-file limit and runs two workers per core
```
