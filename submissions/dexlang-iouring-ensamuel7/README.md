# DexLang (generated C, io_uring)

Front: direct

| | |
|---|---|
| **Language** | [DexLang](https://github.com/ensamuel7/dex) `v0.9.28`: statically typed, compiles to C, which `cc` builds into a native binary |
| **Framework** | None. DexLang's own `http`, `db`, `json` and `crypto` standard library modules |
| **Server** | The `http` module's io_uring backend (`http.uring()`), one event loop per process, `http.fork(n)` processes sharing port 80 through `SO_REUSEPORT` |
| **Postgres driver** | libpq (Ubuntu's `libpq-dev`), through the `db` module: prepared statements, one connection per process |
| **Password hashing** | bcrypt cost 10 through libxcrypt (`crypto.bcryptHash` / `crypto.bcryptVerify`) |
| **Build toolchain** | Go 1.27.2 to build the compiler, then `cc` (gcc 13) on the C it emits |
| **Nginx or direct** | **Direct**, on `0.0.0.0:80` |

What runs is one native binary: no interpreter, no garbage collector, no
framework. The program is `server.dx` (handlers, auth, JSON) and `queries.dx`
(the SQL), and everything below it is the language's standard library.

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

**Writes and logins answer at once.** Writes run on the worker's connection as
they arrive, each committed before its response. A bcrypt login (about 60 ms of
CPU) holds only its own worker.

**io_uring with direct descriptors**: accepts, receives and sends are queued on
a ring and submitted together, receives use a kernel buffer ring, and an idle
keep-alive connection holds no read buffer. The idle timeout is 75 s.

## The SQL

The responses are exactly the reference SQL's. Every read statement is written
once with its arguments as expressions: the per-request form binds `$1`, `$2`,
..., and the batched form puts the request's row from `unnest` in their place,
so a batch runs the same query for each request. Each rewrite of a list or
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
  `TimeZone=UTC`, `DateStyle=ISO` and `jit=off` for its own session. A batched
  statement's estimated cost is high enough that Postgres would otherwise
  JIT-compile every execution, about 300 ms of compiling for 10 ms of work.

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
| batched | 42,000 | 10,714 | 283 ms | 427 ms | 0% | 88% | pass |

At 42,000 users Postgres uses 52% of the box and the server 34%, about half of
that bcrypt. Past about 45,000 users the two load boxes ran out of CPU, so the
4-vCPU ceiling was not reached. The CPU per request is 1.75 times lower than
one statement per request. The one-statement version scored 34,000 users on the
benchmark box (#157), so this one should land somewhere near 60,000. That is an
estimate, not a measurement.

## What the language gained from this challenge

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
queries.dx   the SQL
dex.mod      module file: dex 0.9.28
install.sh   root, once: build-essential, pkg-config, libpq-dev, libcrypt-dev,
             libssl-dev, libcurl, libsqlite3-dev, and Go 1.27.2 (sha256-checked)
build.sh     builds the dex compiler from the pinned v0.9.28 tag through the Go
             module proxy (checksum-verified), then compiles server.dx
start.sh     raises the open-file limit and runs two workers per core
```
