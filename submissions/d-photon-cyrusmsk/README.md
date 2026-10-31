# Conduit (RealWorld) in D on photon-http

**Language:** D 2.111 — **Framework:** [photon-http](https://code.dlang.org/packages/photon-http) 0.6.10 on [photon](https://code.dlang.org/packages/photon) 0.19.3 — **Driver:** [dpq2](https://code.dlang.org/packages/dpq2) 1.3.2 async (libpq)

| | |
|---|---|
| `install.sh` | LDC 1.41.0, a checksummed tarball (with its own dub) into `/usr/local/ldc`, plus `libpq-dev` (PGDG, 17+ for the driver's pipeline API), `libbsd-dev`, `libssl-dev`, `zlib1g-dev`, `libmimalloc-dev`, `gcc` and `git` |
| `build.sh` | `dub build --build=release`; every dependency version is pinned in `dub.selections.json` |
| `start.sh` | `exec ./bin/server`, configured only by `DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT` (plus optional `CONNS`); preloads mimalloc when installed (`MIMALLOC=0` skips it) and best-effort raises `ulimit -n` (`RAISE_NOFILE=0` skips it) |

**Front: direct** — the server holds every virtual user's keep-alive connection itself
(`LimitNOFILE=200000`), and no Nginx CPU is spent.

## What it does, and why

### One process, one photon scheduler thread per core

Postgres is capped at `max_connections = 100`, sits on the same CPU set as the server, and every
request has to wait for it, so the interesting question is how much of the database's work a core
can keep flowing.

One process with **one photon scheduler thread per core** (`initPhoton()` reads the CPU affinity
mask, so `taskset` works). Each scheduler gets:

* **its own pool of long-lived, prepared Postgres connections** — a libpq connection belongs to the
  thread that opened it, so a pool is never shared between schedulers;
* **a keeper fiber** (`delay(1.hours)`) so the scheduler stays alive; one global accept-loop fiber
  hands every accepted socket to its own client fiber on a scheduler.

A request is then parsed, queried, rendered and answered by one scheduler, with no lock, channel or
context switch between two threads anywhere on its path. The scheduler count follows the CPU affinity
mask; use `taskset` to change it. `CONNS` is the total connection budget across every scheduler
(default 95, capped at 95, which is what SPEC.md allows; invalid values fall back to 95, and a
value below the scheduler count is rejected at startup).

### No connection is ever dialled twice

Each scheduler opens its connections at startup and prepares every statement on each of them
(`initConnection`, one libpq pipeline). After that a request only ever borrows a connection and runs a statement that
was already parsed and planned by Postgres, so the steady state has no connection setup, no parse,
no plan, no SQL syntax errors: the statements in `source/db.d` are the only ones that exist, and a
typo in one of them fails at startup instead of on the first request.

Writing an article is one transaction: a CTE inserts the article and its tags, a second statement
links the tag rows, and both commit before the response is sent. The endpoint then runs the
full-article select on the same connection.

### Responses and requests go through mir-ion

Responses are typed structs (`UserResponse`, `ArticleOut`, ...) serialized by mir-ion's
`serializeJson`; `MaybeString` is `Algebraic!(string, typeof(null))`, so an absent `bio` or `image`
is JSON `null` rather than `""`. There is no JSON DOM, no reflection pass and no hand-written
escaping: one struct is serialized once and `respondWith` sets `Content-Length` on the way out.

Request bodies are deserialized straight into typed structs by `deserializeJson`; a malformed body
or a wrong field type is a 422. Unknown fields are ignored, and `Nullable!string` distinguishes
"absent" (leave unchanged) from an empty string for `PUT /api/user`.

### Notes from `AGENTS.md`

| the note | here |
|---|---|
| "don't use nginx, let the server serve directly" | **Front: direct**: the process binds `HOST:PORT` itself |
| "prepare sql once, init it and reuse later" | every statement is prepared once per connection at startup (`initConnection` in one pipeline); single-statement endpoints run prepared, multi-statement handlers hold one connection and share one libpq pipeline where the parameters are known |
| "use one reused DB connection" | a fixed set of long-lived connections per scheduler, opened at startup — a request never dials (per scheduler, because a libpq connection is bound to the thread that opened it) |
| "use group commit - many writes - one commit" | each write commits before its response is sent; Postgres groups the concurrent commits itself |
| "for jwt - use jwtlited (the fastest in D)" | `source/auth.d` over jwtlited's OpenSSL `HS256Handler`: it does the crypto and the base64, only the claims are checked here |
| (passwords) | [`passwd`](https://code.dlang.org/packages/passwd) — bcrypt with OpenBSD test vectors, not a hand-rolled implementation |
| (pipelines) | `execPipeline` in `source/db.d`: a list page and its count go out in one flush and come back in order; anything that needs a previous answer stays sequential |
| (responses) | typed structs serialized by mir-ion; request bodies deserialized by mir-ion — no JSON DOM |
| (compile) | `CONFIG=native` (default) or `CONFIG=portable`; native uses `-mcpu=native` |

`vendor/photon-http` is the 0.6.10 source with one parser fix: `reset()` clears the previous
request's `Content-Length`, so a bodyless request that follows a request with a body is parsed
instead of waiting forever for body bytes that will never arrive.

### Nothing that reads data is shared across requests

Per rule 5 there are no response caches, query caches, in-memory table copies, remembered JWT
verifications or remembered password hashes anywhere: the lists, the articles, the profiles, the
counts and the tags are all read from Postgres while the request is served. What is shared is
patterns, not data — connections, prepared statements, and this code.

Authentication stays real too: every password is bcrypt cost 10
([`passwd`](https://code.dlang.org/packages/passwd), which has OpenBSD test vectors), every login
verifies against the stored hash, and every token's HMAC and `exp` are checked with
[jwtlited](https://code.dlang.org/packages/jwtlited) (HS256, no `alg` other than HS256 is accepted).

## Files

| File | |
|---|---|
| `source/app.d` | photon entry point: configuration, scheduler pools, accept and client fibers |
| `source/api.d` | the 19 endpoints, routing, request structs, response structs |
| `source/db.d` | the statements, the per-scheduler async dpq2 pool, the row readers |
| `source/auth.d` | HS256 JWT issue/verify on top of jwtlited |
| `source/bcrypt.d` | bcrypt cost 10 hash/verify on top of the `passwd` package |
| `source/photon/conduit_shim.d` | re-arms photon's socket readiness around libpq's own reads/writes |
| `vendor/photon-http` | photon-http 0.6.10 with the keep-alive parser fix described above |
| `scripts/localtest.sh`, `scripts/loadtest.sh` | local conformance run and load test against the dev seed |

## Running it

```bash
bash seed/make-seed.sh --dev              # 2% seed, ~30 s, needs Go and psql
bash submissions/d-photon-cyrusmsk/install.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_dev \
JWT_SECRET=multicore-server-challenge HOST=127.0.0.1 PORT=3000 \
    submissions/d-photon-cyrusmsk/start.sh
curl localhost:3000/api/tags
```

Conformance (197 steps, all passing):

```bash
bash test/run.sh submissions/d-photon-cyrusmsk     # needs Go, psql, curl
```
