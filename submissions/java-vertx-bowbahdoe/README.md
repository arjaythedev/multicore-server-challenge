# Conduit: Java (Vert.x)

**Front: direct.**

Pure Java on Vert.x: Vert.x's HTTP server on Netty's native epoll transport, and the Vert.x PostgreSQL client. No
framework beyond that and no native code; bcrypt, JWT and JSON output are plain Java.

On this workload Postgres does most of the work, so most of what's here is about spending less Postgres CPU per
request: reads are answered in large batches, where everything concurrent requests have in common is read once.

# Stack

| | |
|---|---|
| Runtime | JDK 27 (Temurin, `install.sh`), compiled with `--release 25`; G1 with a fixed 4 GB heap |
| HTTP | Vert.x core 5.2.2: one HTTP server per event loop, Netty 4.2.19.Final native epoll |
| Database | Vert.x PostgreSQL client 5.2.2, pipelined, prepared statements cached; SCRAM-SHA-256 login via `com.ongres.scram:scram-client` 3.4 |
| JSON | `dev.mccue:json` 2024.11.20 for request bodies; responses written by hand straight into a buffer |
| Auth | HS256 JWTs checked by hand (`javax.crypto.Mac`): `alg`, signature and `exp` on every request |
| bcrypt | Own implementation, cost 10, four hashes interleaved (see below) |
| Build | Maven 3.9.16 (checked-in wrapper) |

# Design

## Reads: lanes

Reads from every event loop go into one queue. Read lanes, each a thread with its own Postgres connection, take
turns collecting it: one lane gathers for up to 10 ms while the others run what they gathered, so a batch is every
read that arrived in that window, of every endpoint. A batch is answered in two pipelined round trips:

1. **Phase A**: one statement per kind of read in the batch, each taking arrays of the batch's *distinct* keys
   (`unnest(...) WITH ORDINALITY`): one global page per (limit, offset), one capped count and page per tag, author
   or favoriter, one lookup per slug, username, email or user id. The list statements return their counts and their
   pages together.
2. **Phase B**: over the union of every article phase A found, across all endpoints: each article's tags, favorite
   count and author once, the names of those tags, and the `favorited` / `following` flags each viewer needs, as one
   primary key scan per viewer (`= ANY (...)`).

Each response is then assembled in Java from those rows and handed back to the event loop that owns the request.

Only requests already waiting share a batch, every value in a response is read from Postgres while that request is
waiting, and nothing outlives the batch. The window costs up to 10 ms of latency; in exchange, the newest page, the
tag list and a popular article's author and favorite count are read once per batch instead of once per request.

This design is the one [rust-epoll-WorriedArrow](../rust-epoll-WorriedArrow) describes, ported to Java and Vert.x.

## Writes

Each event loop has its own write connection, so no read waits behind a commit. Every write is one statement: CTEs
do the checks and the change, and `RETURNING` (with subqueries) gives back the response's data in the same round trip.

## bcrypt

Logins and sign-ups are a fraction of a percent of requests but, at cost 10, tens of milliseconds of CPU each.
They run on one dedicated thread, four at a time: a single bcrypt is a long chain of dependent S-box loads, and four
independent hashes advanced in the same loop give the core four chains to overlap (about 2.6x the throughput of
Bouncy Castle per core). The thread waits up to 100 ms to fill its four. A hash whose client has already hung up is
dropped instead of computed. Every hash still does every round, and every login verifies against the stored hash.

## Postgres session settings

Startup parameters on the app's own connections, nothing server-wide: `plan_cache_mode = force_generic_plan` (the
statements are planned once, not on every execution), `jit = off`, `max_parallel_workers_per_gather = 0` and
`enable_memoize = off` (overhead for small queries).

# Settings

Defaults suit the 8-vCPU box; all are optional environment variables.

| Variable | Default | |
|---|---|---|
| `EVENT_LOOPS` | cores | event loops, each with its own HTTP server |
| `READ_LANES` | cores | read lanes (connections); `0` answers every read with its own statement instead |
| `READ_WINDOW_US` | 10000 | how long a lane gathers a batch |
| `READ_MAX` | 4096 | batch size cap |
| `DB_READ_CONNS`, `DB_WRITE_CONNS` | 1, 1 | connections per event loop |
| `BCRYPT_THREADS` | 1 | bcrypt threads |
| `BCRYPT_WINDOW_MS` | 100 | how long a bcrypt thread waits to fill its four |

Postgres connections: `READ_LANES + EVENT_LOOPS × (DB_READ_CONNS + DB_WRITE_CONNS)`, 24 by default.

# Getting started

## Prerequisites

* Java 27 (`install.sh` installs it to `/opt/jdk`)

## Usage

```
$ ./build.sh
$ DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 ./start.sh
```
