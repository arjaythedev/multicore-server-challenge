# Scala / Netty: own HTTP server, own Postgres client

Front: direct

| | |
|---|---|
| Language / runtime | Scala 3.10.0 on JDK 25 (Eclipse Temurin 25.0.4.1, checksummed in `install.sh`), sbt 1.13.0 |
| HTTP | Netty 4.2.19 (io_uring, epoll where the kernel doesn't allow it), own HTTP/1.1 decoding: no Netty codec |
| Postgres | own client for the PostgreSQL wire protocol 3.0 over Netty (SCRAM-SHA-256, extended query protocol, binary rows, pipelining): no JDBC |
| JSON | own: request bodies parsed strictly, responses written straight from Postgres's binary rows |
| bcrypt, JWT | own bcrypt (cost 10, `$2a$`/`$2b$`/`$2y$`; Blowfish's constants computed from pi at startup), HS256 in per-thread buffers |
| Dependencies | Netty only (`build.sbt`, pinned); tests: munit, and Jackson and Spring Security's BCrypt as references |

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

## Optimizations

Postgres takes most of the CPU (about two thirds of what a request costs), so the server is built first to cost
Postgres as little as possible, then to cost little itself. The numbers below were measured on a local copy of the box
at half its size: Postgres and the server on 4 vCPUs, the challenge's load generator on others.

**Postgres's work per request**

- **One statement per request** where the spec's reference SQL has two or three (`Sql.scala`). Outside a transaction
  each statement is its own round trip and its own transaction: a snapshot, a commit, a backend woken up. Look-ups and
  the writes they guard go together (`DELETE ... USING` the look-up in a CTE, `INSERT ... SELECT` from the slug);
  favorite/unfavorite is the write and the read in one Sync; a new article is its insert, its tags and the read back
  in one Sync.
- **A list's page is cut first.** The page's ids come from the bare index walk (`OFFSET/LIMIT` on it), and the
  per-article work (tags, favorites count, the viewer's flags, the author) runs for the page's rows only, not for the
  rows `OFFSET` skips; the capped count is in the same statement.
- **Generic plans under a constant bound.** Every statement is prepared once per connection and runs with
  `plan_cache_mode=force_generic_plan`, `jit=off` and no parallel workers (session settings sent with the login). A
  generic plan can't see `LIMIT $2` and plans for a tenth of the table, so every page sits under a constant
  `LIMIT 100`. Tag names are read by primary key, not joined over all tags.
- **Reads that wait go out together.** When reads wait for a connection, those of a kind go out as one statement: the
  request's own SQL in a `LATERAL` subquery over arrays of the requests' parameters, up to 32, each row tagged with
  its request. Each request still gets its own execution and its own rows (rule 5). There is no timer: reads batch
  only when the connections are busy. Near the limit Postgres spends 6-13% less CPU per request.
- **One round in flight per read connection.** An idle read connection takes the 256 oldest waiting reads, whatever
  their kind, each kind's batched, all in one flush, and nothing more until they are answered: 3-8% less CPU per
  request than 16 queries in flight per connection. Taking the oldest, rather than up to 32 of every kind, makes
  every kind wait alike: the two that arrive fastest (the article and the tags) otherwise fell behind under overload.
- **One read connection per CPU** (8 on the box), so that the backends pipelining keeps busy don't take turns on the
  CPUs: Postgres 5-13% less CPU per request than with four per CPU, the server 7% less.
- **Writes on a connection of their own, committed in groups.** Each event loop has a write connection with one
  transaction in flight; the writes that arrive meanwhile go out together, their statements and one Sync: one
  transaction, one commit, one WAL flush for all. Reads never wait behind a commit. Every response is written after
  its group's commit (rule 6), and a group that fails goes out again one write at a time, so that only the one at
  fault fails. p95 18-21 ms against 27-51 with the writes on the read connections, p99 36-47 against 71-108.

**The server's own CPU**

- **Each event loop owns its client connections and its Postgres connections** (one loop per 4 CPUs: 2 on the box). A
  request is decoded, sent to Postgres, answered and written on its loop's thread, with no locks or hand-offs. Queries
  are written into their connection's send buffer and flushed once per pass of the loop; replies come back in order
  and are read in place.
- **Binary rows, straight into JSON.** Every column comes back in binary: numbers, booleans, timestamps (formatted from
  microseconds since 2000), `text[]` tag lists. Text is copied from the receive buffer into the response and escaped
  only when it needs it.
- **HTTP decoded by hand.** Requests are parsed straight from the socket's bytes; a response's status line and headers
  are written in front of its body, one buffer and one write per response. Netty's listening socket accepts until its
  queue is empty, and its registration map is scrambled (Netty's own made every close cost O(connections)).
- **bcrypt off the event loops, four hashes at a time.** A cost-10 hash is ~55 ms of CPU: on an event loop it would
  stall every connection the loop serves. Hashes run on threads of their own, four interleaved round by round so that
  their chains of table loads overlap, with the S-box loads unchecked and Blowfish's 16 rounds unrolled: 15.4 ms of CPU
  per hash. Every hash is still full bcrypt at cost 10.
- **Generational ZGC and a fixed 2 GB heap** (`start.sh`). Each user keeps one connection for the whole run, a few
  objects that settle in the old generation and are written on every request; under the parallel collector young
  pauses grew with the connections (85-330 ms at 80,000 users) and each run's dead connections piled up in the old
  generation. ZGC collects both generations beside the event loops: over ten runs on one process the heap stayed at
  240-400 MB, without pauses to speak of.

## Rules

No caching of any kind across requests: every request reads Postgres while it is served; only connections and
prepared statements are kept. Every token's signature, `alg` and `exp` are checked on every request; every password is
hashed with bcrypt cost 10 and every login verified against its stored hash. Writes are committed before the response.
Nothing in the database is created or altered: only session settings on the server's own connections.

## Settings

All optional, as JVM system properties (`JAVA_TOOL_OPTIONS="-Dconduit.loops=2" bash start.sh`):

| Property | Default | |
|---|---|---|
| `conduit.loops` | CPUs / 4, at least 1 | event loop threads |
| `conduit.pgConnections` | one per CPU, at most 95 with the write connections | read connections to Postgres, split over the loops |
| `conduit.pgWriteConnections` | 1 | write connections per loop (0: writes go on the read connections) |
| `conduit.writeGroupSize` | 128 | the most writes committed in one transaction (1: each its own) |
| `conduit.pgDrain` | true | a read connection takes reads only when idle, then a round of the waiting ones |
| `conduit.pgRoundSize` | 256 | with `pgDrain`: the oldest waiting reads a round takes, whatever their kind; 0: up to `batchSize` of every kind |
| `conduit.pgDepth` | 16 | without `pgDrain`: requests in flight per read connection; more wait in the loop's queue |
| `conduit.batchSize` | 32 | the most waiting reads of a kind sent as one statement (1: none) |
| `conduit.bcryptThreads` | CPUs / 4, at least 1 | bcrypt threads |
| `conduit.bcryptWaitMillis` | 400 | how long a hash waits for others to run four at a time |
| `conduit.bcryptNice` | 0 | the bcrypt threads' nice value (up to 19: they wait whenever Postgres or a loop has work) |
| `conduit.transport` | `io_uring` | or `epoll`; either falls back to NIO off Linux |
| `conduit.maxConnections` | the descriptors | connections held per loop before the longest-idle are closed |
| `conduit.idleTimeoutSeconds` | 75 | the spec asks for at least 65 |
| `conduit.requestDeadlineSeconds` | 30 | how long a request may take to arrive whole before it gets a 408 |
| `conduit.acceptsPerPass` | 1024 | new connections accepted per pass of the accepting loop |
| `conduit.listenBacklog` | 65535 | the listen backlog asked for (the kernel caps it at `net.core.somaxconn`) |
| `conduit.lagMonitor` | false | logs each loop's lag every 10 s |
| `conduit.stats` | false | logs each loop's queries every 10 s: how many waited, the batches |

## Results

Not yet run on the official box. On a local copy of it at half its size (Postgres and the server on 4 vCPUs, the
challenge's load generator on others), at 72,000 users on a database grown by 29 million requests, in three 1-minute
runs: 157-162 µs of CPU per request, the server's 49-51 and Postgres's 108-111; 3.0-3.1 of the 4 cores busy; p95
8-11 ms, p99 21-24 ms, no errors.
