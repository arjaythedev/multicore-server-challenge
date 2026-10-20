# Conduit: Kotlin (Ktor + Vert.x PostgreSQL client)

**Front: direct.**

## Goal

A fast server, but written the way we would write a normal production service: clear layers, common libraries,
readable code. No shortcuts that only make sense in a benchmark: no caching, every login checks bcrypt, every request
checks the token, every response reads Postgres. Every optimization below was measured; ideas that didn't help were
dropped.

## Stack

| | |
|---|---|
| Runtime | JDK 27 (Temurin, `install.sh`), Kotlin 2.4 |
| HTTP | Ktor 3.6 on Netty (native epoll transport) |
| Database | Vert.x PostgreSQL client 5.2 (non-blocking, pipelined) with Kotlin coroutines, plain SQL |
| JSON | kotlinx.serialization 1.11 |
| Auth | Ktor Authentication with auth0 java-jwt 4.6, HS256 |
| bcrypt | Bouncy Castle 1.86, cost 10 |
| Build | Maven 3.9 (checked-in wrapper) |

```bash
./build.sh   # -> target/conduit.jar + target/lib/
./start.sh   # needs DATABASE_URL, JWT_SECRET; optional HOST, PORT, DB_POOL_SIZE
```

## Code layout

```
src/main/kotlin/conduit/
├── Main.kt            wires everything together and starts the server
├── domain/            business objects and rules (validation, who may edit what, login check),
│                      repository interfaces. Plain Kotlin, no framework code.
├── application/       one service per area (users, profiles, articles, comments, tags).
│                      Services only coordinate: load, ask the domain, save.
└── infrastructure/
    ├── postgres/      repository implementations, SQL, database client
    ├── security/      bcrypt and JWT
    └── web/           routes, request/response JSON, authentication, error responses
```

Dependencies point inwards: `domain` and `application` don't know about Ktor, Vert.x or JSON.

## What we changed and why

The box is CPU-bound: the app and Postgres share 8 cores. So the work was about using less CPU per request.

**No Nginx in front (biggest single effect)**
- The server takes the clients' connections itself on `HOST:PORT` (0.0.0.0:80 on the box). Nginx (proxy plus gzip)
  cost about 0.17 ms of CPU per request, about as much as the app's own work per request; without it the same box
  handled about 29% more requests per second. Each open connection costs the server little: 40,000 of them added about 190 MB.

**Database**
- The Vert.x PostgreSQL client instead of JDBC with HikariCP. It doesn't block a thread while Postgres works, and it
  pipelines: it sends the next statement over a connection before the previous result is back. So 16 connections
  (2 per core) serve all requests. Compared with JDBC and 32 connections: about 25% less Postgres CPU, 12% less CPU
  per request in total, and about 13% more users before the limit. 8 connections were too few, 24 and 32 no better
  than 16.
- No request needs a transaction (which would need a connection to itself): each write is one statement, except
  creating an article, which first adds any new tags in a statement of its own, then inserts the article and links
  its tags in one statement.
- One SQL statement per request for all reads and the common writes. A list page and its total count, or "find
  the article and add the favorite", go in one round trip instead of two or three.
- A list page picks its 10 article ids first, then loads tags, favorite counts etc. only for those 10. Before, Postgres
  also did that work for the rows skipped by `OFFSET`.
- Tag names are looked up by primary key instead of joining the whole tag table for every article.
- Each connection reuses its query plans (`plan_cache_mode=force_generic_plan`) instead of planning every query
  again: 17% less Postgres CPU. JIT and parallel workers are off; they only add overhead for small queries.
- No TLS when the database runs on the same machine; it only costs CPU there.

**App**
- Token checks call java-jwt from a small Ktor authentication provider (no regex check of the header, no second
  parse of the token), and the feed doesn't re-check `following` (every feed author is followed).
- bcrypt (about 50 ms of CPU per check) runs on its own pool with half the cores, so a burst of logins can't take
  every core away from Postgres. Nothing else blocks a request thread.
- Fixed 2 GB heap: far fewer garbage collections (21 instead of 73 per minute).
- Bouncy Castle for bcrypt: the fastest of the Java libraries we compared (51 ms per check instead of 61 ms).

**Tried and dropped**
- No measurable gain: writing JSON as raw bytes, other garbage collectors (Parallel, ZGC), a custom bcrypt or JWT
  implementation, running each request on its connection's own event loop (Ktor's `shareWorkGroup`). Before
  Vert.x: virtual threads, or more threads than connections for JDBC.
- jasync-sql instead of the Vert.x client: about 30% more CPU per request and about 30% fewer requests per second
  at full load. It doesn't pipeline, and it parses results from text.

## Results

Measured locally (see below), each run after a warm-up, next to the Java example from `examples/java` (Spring Boot,
reference SQL, behind Nginx as its README says) on the same machine:

| | This server | Java example |
|---|---:|---:|
| Most users that passed | 18,000 (19,000 failed) | 4,500 (6,000 failed) |
| Requests per second at that load | 15,700 | 5,900 |
| CPU per request at that load | 0.49 ms | 1.06 ms |
| p95 at 6,000 users | 17 ms | 542 ms |

The absolute numbers are from this machine, not the box: the Java example held 21,000 users in the video, on
other hardware. The ratio is what carries over: about 4 times the users at less than half the CPU per request.

## Where the CPU goes now

Measured per endpoint, then weighted by how often the load test calls it:

| | Share of CPU |
|---|---:|
| Article lists and the feed | ~37% |
| Article page and its comments | ~27% |
| Login (bcrypt) | ~16% |
| Tag list | ~11% |
| Profiles, writes, the rest | ~9% |

Postgres is a bit less than half of the CPU; the lists and the feed are its expensive part. In the app, every
request costs about 0.16 ms (HTTP, routing, token check, database round trip), most of the app's CPU apart from
bcrypt.

## How we measured

A local Docker setup that mimics the box: app and Postgres 18 (with the box's Postgres config) share 8 cores, the
load generator runs on 8 other cores, with the full seed. We compare the CPU time per request of two versions at
the same load, and check the maximum load that still passes. The conformance suite runs after every change.

## Behaviour notes

- Request bodies are read as JSON whatever the `Content-Type`. Malformed JSON, a missing wrapper object or a
  non-string field gives 422. A body over 1 MB gives 413. A missing or invalid token gives 401 before the body is
  read; only a declared `Content-Length` over 1 MB is refused before that.
- Creating an article isn't one transaction (SPEC.md asks for one): new tags are added first, in their own statement.
  If the article insert then fails, those tags stay without an article.
- `Authorization: Token <jwt>`: no header means anonymous on public routes; a wrong scheme or invalid token is 401.
- Unknown paths and wrong methods return a JSON 404. A malformed percent-encoding in the query string gives 400.
- Passwords longer than 72 bytes give 422 (bcrypt would cut them off).
