# DexLang (generated C, io_uring)

Front: direct

| | |
|---|---|
| **Language** | [DexLang](https://github.com/ensamuel7/dex) `v0.9.27`: statically typed, compiles to C, which `cc` builds into a native binary |
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

**Processes, not threads.** `start.sh` runs 48 workers (`WORKERS`). Before
opening anything, the server calls `http.fork(48)`; each copy then opens its own
Postgres connection, prepares its statements and listens on port 80 with
`SO_REUSEPORT`, so the kernel spreads connections across them. A worker owns
its sockets, its connection and its statements outright: there is no lock, no
pool and no handoff anywhere on a request's path. 48 connections stay well
under the 95 allowed.

**A worker waits on Postgres in its own time.** Each handler runs its
statements on the worker's connection and blocks until the answer comes back.
With 48 workers on 8 cores there are always others ready to run, so the cores
stay busy with Postgres's work, which is the expensive part of every request
here. A bcrypt login (about 60 ms of CPU) holds only its own worker.

**io_uring with direct descriptors**: accepts, receives and sends are queued on
a ring and submitted together, receives use a kernel buffer ring, and an idle
keep-alive connection holds no read buffer. The idle timeout is 75 s.

## The SQL

The responses are exactly the reference SQL's. Each rewrite of a list or
article query was run against the reference statement over the same 300 random
parameter sets on the full seed, and the outputs compared byte for byte.

- **Pick the page first, then decorate it.** The reference list query computes
  tags, favorite counts and both `EXISTS` for every row `OFFSET` skips, so page 5
  builds 50 rows to return 10. Each list here selects the page's ids first, from
  the index that orders it (`articles_pkey`, `articles_author_idx`,
  `article_tags_tag_idx`, `favorites_pkey`, or the feed's lateral walk), and
  decorates only those rows: 33% less time for the global list, 15–20% for the
  others.
- **Tags by key.** `ARRAY(SELECT (SELECT name FROM tags WHERE id = at.tag_id) …
  ORDER BY 1)` looks each tag up through `tags_pkey`, where the reference join
  hashed all 200 tags once per article.
- **One statement per list.** The capped `articlesCount` is joined onto the page
  (`count LEFT JOIN LATERAL page`), so a list is one round trip instead of two.
- **One statement for comments.** The article lookup and its newest 100
  comments are one `LEFT JOIN LATERAL`: no row means 404, a row without a
  comment means an empty list.
- **No TLS to a database on the same box.** The connection adds
  `sslmode=disable` (libpq otherwise negotiates TLS even over `127.0.0.1`), and
  `TimeZone=UTC`, `DateStyle=ISO` as connection options, so timestamps come back
  in a fixed text form that is cut to milliseconds without parsing.

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
other boxes, 60 s ramp and 60 s measured:

| users | req/s | p95 | p99 | errors | |
|--:|--:|--:|--:|--:|---|
| 27,000 | 6,926 | 341 ms | 497 ms | 0% | pass |
| 30,000 | 6,899 | 1,143 ms | 1,402 ms | 0% | fail |

Postgres uses about two thirds of the box's CPU and is what runs out. On the
8-core box that extrapolates to roughly 55,000 users.

## What the language gained from this challenge

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
dex.mod      module file: dex 0.9.27
install.sh   root, once: build-essential, pkg-config, libpq-dev, libcrypt-dev,
             libssl-dev, libcurl, libsqlite3-dev, and Go 1.27.2 (sha256-checked)
build.sh     builds the dex compiler from the pinned v0.9.27 tag through the Go
             module proxy (checksum-verified), then compiles server.dx
start.sh     raises the open-file limit and runs 48 workers
```
