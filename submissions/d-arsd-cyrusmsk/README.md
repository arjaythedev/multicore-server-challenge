# Conduit (RealWorld) in D on arsd.cgi + arsd.postgres

**Language:** D 2.111 — **Framework:** [arsd.cgi](https://code.dlang.org/packages/arsd-official)
12.1.2 in `embedded_httpd_hybrid` mode (its own fiber-based HTTP server, no libevent
trampoline) — **Driver:** [arsd.postgres](https://code.dlang.org/packages/arsd-official)
12.1.2 (libpq) — **JSON:** [asdf](https://code.dlang.org/packages/asdf) 0.8.0

| | |
|---|---|
| `install.sh` | LDC 1.41.0, a checksummed tarball (with its own dub) into `/usr/local/ldc`, plus `libpq-dev` (arsd.postgres), `libbsd-dev` (the bcrypt package), `libmimalloc-dev`, `gcc`, `curl`, `xz-utils` |
| `build.sh` | `dub build --build=release --compiler=ldc2`; every dependency version is pinned in `dub.selections.json` |
| `start.sh` | `exec ./bin/server`, configured only by `DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT` (optional `ARSD_THREADS`, `ARSD_FIBER_STACK`); preloads mimalloc when installed (`MIMALLOC=0` skips it) |

**Front: direct** — the server binds `HOST:PORT` itself and holds every keep-alive
connection; no Nginx CPU is spent.

## What it does, and why

### One thread per core, one connection per thread, no shared state

`RequestServer` runs in fiber (`hybrid`) mode: every worker thread accepts its own
connections and serves each one on a fiber. `useFork = true` (arsd's default): with
`useFork = false` arsd leaves the shared listening socket blocking, so the worker
threads park in `accept()` and the pool collapses under load — `useFork = true` is what
makes each thread's listener non-blocking. The thread count is `min(2 * cores + 1, 90)`
(`ARSD_THREADS` overrides it).

A libpq call is blocking, so a connection belongs to exactly one thread and a request
that touches the database keeps running on that thread — fibers never migrate. Each
thread opens **one** long-lived `PostgreSql` connection for its whole life; requests on
a thread serialize on that connection behind the fiber scheduler. Nothing is shared
between threads except immutable configuration, so no pool lock and no connection
handoff ever happens.

### No connection is ever dialled twice

The connection is opened once per thread, and `SET TIME ZONE 'UTC'` + `SET jit=off` are
applied at connect time. Every statement is a fixed string; `arsd.postgres` substitutes
the `?n` placeholders as escaped SQL literals (zero-based, single digit per the driver),
so there is no per-request parse and no plan cache to fight.

### JSON via asdf

Responses are plain `struct`s in `source/model.d` (`UserDto`, `ArticleDto`,
`CommentDto`, `ProfileDto`, …) serialized with asdf's `serializeToJson`; request bodies
are deserialized with asdf's `deserialize`. An update's optional fields are
`Nullable!string`: `null` or absent stays unset (leave the column unchanged), a present
string — including `""` — sets it, and a wrong type fails `deserialize` → 422. The
`tag_list` column is a JSON array from `json_agg`; asdf parses it into `string[]` so the
serializer emits it as a JSON array. No hand-rolled parser and no byte-level JSON
writers. `createdAt`/`updatedAt` are formatted to RFC 3339 by Postgres itself.

### The empty-string / SQL-NULL problem

libpq returns an empty `text` as a zero-length C string, and arsd's `copyCString` makes
that a **null** D string — the same value it produces for a real SQL NULL. So a column
that is `''` and a column that is `NULL` are indistinguishable once they are in a row.

The conformance suite requires both to round-trip (`{"bio": ""}` must answer `"bio": ""`,
while an unset `bio` must answer `null`), so the nullable text columns (`bio`, `image`)
are tagged in SQL to keep the distinction:

```sql
CASE WHEN bio IS NULL THEN E'\x01N' ELSE E'\x01V' || bio END AS bio
```

`cellNullable` in `source/api.d` decodes that: `0x01 N` → null, `0x01 V` + rest → the
string (empty when nothing follows). The tag is injective, so a value can never be
mistaken for a NULL.

### Notes from `AGENTS.md`

| the note | here |
|---|---|
| "don't use nginx, let the server serve directly" | **Front: direct** — the process binds `HOST:PORT` itself |
| "prepare sql once, init it and reuse later" | the statements live as `enum` strings in `source/db.d` and are sent verbatim each request with escaped literals; one connection is opened once per thread and reused for its life |
| "use one reused DB connection" | exactly one long-lived connection per worker thread (one per thread because a blocking libpq call would otherwise stall another thread's fiber) |
| "use group commit - many writes - one commit" | each write is a single statement (article create is one CTE chain) and commits before its response is sent; Postgres groups the concurrent commits itself |
| "for jwt - use jwtlited (the fastest in D)" | `source/auth.d` over jwtlited's `HS256Handler`: it does the HMAC and base64url, only the three claims are checked here |
| (passwords) | [`passwd`](https://code.dlang.org/packages/passwd) — bcrypt cost 10 with OpenBSD test vectors, not hand-rolled |

No response cache, query cache, in-memory table copy or remembered JWT verification:
lists, articles, profiles, counts and tags are always read from Postgres while the
request is served.

## Files

| File | |
|---|---|
| `source/app.d` | process setup: config, thread count, `RequestServer` |
| `source/api.d` | the 19 endpoints, routing, request parsing, row → DTO |
| `source/db.d` | the SQL statements, connection URL, escape helpers |
| `source/model.d` | the asdf wire structs for requests and responses |
| `source/auth.d` | HS256 issue/verify on top of jwtlited |
| `source/bcrypt.d` | bcrypt cost 10 hash/verify on top of the `passwd` package |

## Running it

```bash
bash seed/make-seed.sh --dev              # 2% seed, ~30 s, needs Go and psql
bash submissions/d-arsd-cyrusmsk/install.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_dev \
JWT_SECRET=multicore-server-challenge HOST=127.0.0.1 PORT=3000 \
    submissions/d-arsd-cyrusmsk/start.sh
curl localhost:3000/api/tags
```

Conformance (197 steps, all passing):

```bash
bash test/run.sh submissions/d-arsd-cyrusmsk     # needs Go, psql, curl
```

Load testing on the challenge box was left to the harness (not run here).
