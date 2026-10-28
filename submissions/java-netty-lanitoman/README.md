# Java / Netty: batched reads on our own Postgres client

Front: direct

| | |
|---|---|
| Runtime | Java 25 (Eclipse Temurin 25.0.4.1, checksummed in `install.sh`) |
| HTTP | Netty 4.2.17 (epoll) with our own HTTP/1.1 parser |
| Postgres | our own wire-protocol client (SCRAM-SHA-256, extended protocol, binary rows, pipelining); no JDBC |
| JSON | written straight from Postgres's binary rows; request bodies parsed with jackson-core 2.21.2 |
| bcrypt / JWT | our own bcrypt (cost 10, six hashes interleaved, inner loop in C); HS256 via the JDK |
| Build | Maven 3.9.11 (checksummed), versions pinned in `pom.xml` |

Postgres shares the eight CPUs and runs out first, so the design minimises the work Postgres does per request.

## Request flow

1. An HTTP event loop (2 threads) parses the request, verifies the token and validates the input.
2. Reads join a queue for their kind (article, list, feed, ...); writes go to a write connection; logins and
   sign-ups go to a bcrypt worker first.
3. A Postgres event loop (2 threads) parses the reply in place and renders JSON directly from the binary rows.

## Batched reads

Much of a cheap statement's cost is per statement, so reads of the same kind are sent together as **one
statement**, their parameters passed as arrays:

```sql
WITH r AS MATERIALIZED (
  SELECT * FROM unnest($1::int4[], $2::int8[], $3::text[], $4::int4[], $5::int8[]) AS r(i, viewer, key, lim, off))
...
```

Each result row carries its request index `i`. There is no timer: requests queue only while every read connection
is busy, and a free connection takes the longest-waiting kind (up to 64 requests). At low load batches hold one
request; under load they grow on their own.

Within a statement, each distinct article's author, tags and favourite count, each article's comments, and each
tag's count are read once. A batch returns one *shared* row per distinct article plus small per-request rows with
the viewer's `favorited`/`following`; the server renders each shared row once and copies the fragment into every
response that shows it. Nothing is kept between statements.

## Writes

16 connections of their own, so commits waiting on WAL flushes never delay reads; concurrent commits share
flushes. Every write is one round trip (data-modifying CTEs, or the change and its read-back pipelined in one
implicit transaction).

## SQL

- Generic plans (`plan_cache_mode = force_generic_plan`), planned once per connection.
- Small-to-big lookups use `LATERAL (... OFFSET 0)`, so they are always index probes.
- Pages are cut before joins and capped with a constant `LIMIT 100`, which keeps generic-plan estimates small.
- Capped counts stop at 1000; where 1000 is typical, `OFFSET 999` checks for a 1000th row instead of counting.
- Under a code-point collation (`C`, `C.UTF-8`, detected at startup) the server sorts tag names itself.

## bcrypt

Two workers collect up to six hashes (waiting up to 400 ms) and compute them interleaved, at full cost 10, which
halves the CPU per hash. The key-schedule loop is [native/bcrypt_lanes.c](native/bcrypt_lanes.c), called through
Java's foreign function API; without a C compiler, or if it disagrees with the Java version at startup, four Java
lanes are used instead. A self-test checks against a known hash at startup. The workers run at nice 10, so
Postgres and the event loops get the CPU first.

## Overload

- Client connections are capped below the file descriptor limit (the limit less 1% and 1000): at the cap the
  server stops accepting until some connections close, so it never runs out of descriptors. A failed accept pauses
  accepting for 100 ms.
- Nothing opens files while serving: the time-zone data and logging configuration are loaded at startup, and log
  records go to stderr through a handler that never throws, so an error report can't end an event loop.
- bcrypt workers survive any failure and answer 500 instead.

## Rules

- No caching: every response is read from Postgres while the request is served.
- Every login verifies bcrypt cost 10; every request verifies the token's HS256 signature, `alg` and `exp`.
- Writes commit before the response. Session settings only. 26 connections.

## Configuration

Required: `DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT` (see [.env.example](.env.example)). Optional:

| Variable | Default | |
|---|---|---|
| `HTTP_THREADS` | 2 | HTTP event loops |
| `PG_THREADS` | 2 | Postgres event loops (0: share the HTTP loops) |
| `DB_READ_CONNS` | 10 | read connections |
| `DB_WRITE_CONNS` | 16 | write connections |
| `BATCH_MAX` | 64 | max requests per batch |
| `BCRYPT_THREADS` | 2 | bcrypt workers |
| `BCRYPT_BATCH_WINDOW_MS` | 400 | how long a worker waits to fill a batch |
| `BCRYPT_NICE` | 10 | worker CPU priority (0: normal) |
| `MAX_CONNECTIONS` | fd limit − 1% − 1000 | client connections at most |

`java -jar target/conduit.jar --print-sql` prints every prepared statement.
