# Conduit (RealWorld) in D on vibe.d

**Language:** D 2.111 — **Framework:** [vibe.d](https://vibed.org) 2 (vibe-http 1.5.1,
vibe-core 2.14.0) — **Driver:** [dpq2](https://code.dlang.org/packages/dpq2) 1.1.7 through
[vibe-d-postgresql](https://code.dlang.org/packages/vibe-d-postgresql) 3.1.3 (libpq)

| | |
|---|---|
| `install.sh` | LDC 1.41.0, a checksummed tarball (with its own dub) into `/usr/local/ldc`, plus `libpq-dev`, `libbsd-dev`, `zlib1g-dev`, `gcc` and `git` |
| `build.sh` | `dub build --build=release`; every dependency version is pinned in `dub.selections.json` |
| `start.sh` | `exec ./bin/conduit-vibed`, configured only by `DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT` (plus optional `THREADS`, `CONNS`) |

**Front: direct** — the server holds every virtual user's keep-alive connection itself
(`LimitNOFILE=200000`), and no Nginx CPU is spent.

## What it does, and why

### One process, one event loop thread per core

Postgres is capped at `max_connections = 100`, sits on the same 8 cores, and every request has to
wait for it, so the interesting question is how much of the database's work a core can keep flowing.

One process with **one vibe-core event loop thread per core**. Each thread gets:

* **its own listening socket on the same port** (`SO_REUSEPORT`): the kernel spreads the tens of
  thousands of keep-alive connections over the threads, and each thread serves its own connections
  for their whole life;
* **its own pool of long-lived, prepared Postgres connections** — a vibe.d connection belongs to
  the thread that created it (the connection pool asserts this), so a shared pool would have to
  lock or hand a fiber a connection bound to a foreign event loop.

A request is then parsed, queried, rendered and answered by one core, with no lock, channel or
context switch between two threads anywhere on its path. `THREADS` overrides the thread count,
`CONNS` caps the connections (default 95, which is what SPEC.md allows).

### No connection is ever dialled twice

`Db.warmUp()` opens all of a thread's connections at startup and prepares every statement on each of
them (`initConnection`). After that a request only ever borrows a connection and runs a statement
that was already parsed and planned by Postgres, so the steady state has no connection setup, no
parse, no plan, no SQL syntax errors: the 32 statements in `source/db.d` are the only ones that
exist, and a typo in one of them fails at startup instead of on the first request.

Writing an article is a **single statement** (a CTE chain: `newid` → article insert → tag insert →
tag-link insert), so it is one round trip and one implicit transaction, and it commits before the
response is sent — Postgres groups the concurrent commits itself.

### Every response is written as JSON by hand

`source/json.d` is a growable byte buffer with the handful of writers these responses need. The
article row format is already nearly the response:

* text columns are copied straight into the response (they arrive as UTF-8 from the text result
  format, so no field is re-encoded unless it can contain a quote or a control character);
* `favoritesCount` is copied as the integer Postgres printed;
* `timestamptz` columns are rewritten `YYYY-MM-DD HH:MM:SS.ffffff+00` → `YYYY-MM-DDTHH:MM:SS.mmmZ`
  (truncated, never rounded) in place;
* `text[]` becomes a JSON array without building an intermediate structure.

There is no JSON DOM, no reflection, and no second pass over the body: one buffer, one pass, one
`writeBody()` call, which sets `Content-Length` on the way out.

### Notes from `AGENTS.md`

| the note | here |
|---|---|
| "don't use nginx, let the server serve directly" | **Front: direct**: the process binds `HOST:PORT` on all its threads |
| "prepare sql once, init it and reuse later" | 32 statements, prepared once per connection at startup (`initConnection`); 31 of the 32 endpoints are one statement, and writing an article is one CTE |
| "use one reused DB connection" | a fixed set of long-lived connections per thread, opened at startup — a request never dials (per-thread, because a vibe.d connection is fiber-bound to its thread) |
| "use group commit - many writes - one commit" | a write is one statement, so its transaction is committed before the response is written, and Postgres groups the concurrent commits it gets |
| "for jwt - use jwtlited (the fastest in D)" | `source/jwt.d` is a thin layer over jwtlited's `HS256Handler`: it does the crypto, only the three claims are checked here |
| (passwords) | [`passwd`](https://code.dlang.org/packages/passwd) 0.3 — bcrypt with OpenBSD test vectors, not a hand-rolled implementation |

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
| `source/app.d` | process setup: config, event loop threads, listeners, error page |
| `source/api.d` | the 19 endpoints, routing, request bodies, response building |
| `source/db.d` | the statements, the per-thread pool, the row readers |
| `source/json.d` | the response byte buffer and the JSON writers |
| `source/body.d` | a small strict JSON reader for request bodies |
| `source/bcrypt.d` | bcrypt cost 10 hash/verify on top of the `passwd` package |
| `source/jwt.d` | HS256 issue/verify on top of jwtlited |
| `scripts/localtest.sh`, `scripts/loadtest.sh` | local conformance run and load test against the dev seed |

Every module carries `unittest` blocks (bcrypt against the seeded hash, JWT against tokens
minted the way the harness mints them, the JSON writers, the request-body parser, the slug).
`dub test` would also run the dependencies' tests, and one of those — vibe-d-postgresql's —
calls into libpq at constructor time, which segfaults when libpq is loaded dynamically the
way this project loads it; the conformance suite is the gate here.

## Running it

```bash
bash seed/make-seed.sh --dev              # 2% seed, ~30 s, needs Go and psql
bash submissions/d-vibe-cyrusmsk/install.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_dev \
JWT_SECRET=multicore-server-challenge HOST=127.0.0.1 PORT=3000 \
    submissions/d-vibe-cyrusmsk/start.sh
curl localhost:3000/api/tags
```

Conformance (197 steps, all passing):

```bash
bash test/run.sh submissions/d-vibe-cyrusmsk     # needs Go, psql, curl
```

## Measured

Against the Go reference server (`examples/go`) on the same laptop, same dev seed, same load
generator, `Front: direct` vs Go's `Front: nginx`:

| users | Go: req/s (p50/p95/p99) | this: req/s (p50/p95/p99) |
|---|---|---|
| 6 000 | 1601 (0.4/1.0/1.8 ms) | 1601 (1.1/21.9/29 ms) |
| 8 000 | 2143 (0.4/1.5/2.5 ms) | 2118 (2.2/116/234 ms) |
| 12 000 | 3208 (0.4/3.0/5.6 ms) | fails (p95 116 ms, 28 % connect timeouts) |
| 16 000 | 4248 (0.4/4.1/9.6 ms) | — |

Go stays at ~0.4 ms median per request up to its ceiling; this server is ~2.5× the CPU per
request and stops scaling near 8 000 users on the same box. In the closed-loop workload
req/s tracks the user count (~0.27/user), so those columns are mostly a statement about how
much CPU each request costs — Go's `net/http` plus pgx costs far less than vibe-http's request
parsing, the fibers and dpq2/libpq's row access. The published video scores are 22 000 (Go),
21 000 (Java), 19 000 (Rust) and 10 000 (Python) users on 8 vCPUs, i.e. roughly 5.5k, 5.2k, 4.7k
and 2.5k req/s at the workload's ~0.25 req/s per user.

Two things the measurements did change: `vibe-http`'s default `keepAliveTimeout` (10 s) is raised
to 120 s here so the load generator's idle sockets are never closed under it, and the response
buffer starts at 4 KB instead of 64 KB (the size of the biggest list page), which alone cut p95
at 8 000 users from 165 ms to 116 ms. A per-thread reusable response buffer and dropping the
unused `a.id` column from the article queries were both tried and neither moved the numbers, so
neither is in.
