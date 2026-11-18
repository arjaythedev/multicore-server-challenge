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
  a favorite or an unfavorite is its write, then once committed its article read in the next read round, where the
  round's other reads share what it reads (in the write's Sync it was a statement of its own); a new article is its
  insert, its tags and the read back in one Sync.
- **A list's page is cut first.** The page's ids come from the bare index walk (`OFFSET/LIMIT` on it), and the
  per-article work (tags, favorites count, the viewer's flags, the author) runs for the page's rows only, not for the
  rows `OFFSET` skips; the capped count is in the same statement.
- **Generic plans under a constant bound.** Every statement is prepared once per connection and runs with
  `plan_cache_mode=force_generic_plan`, `jit=off` and no parallel workers (session settings sent with the login). A
  generic plan can't see `LIMIT $2` and plans for a tenth of the table, so every page sits under a constant
  `LIMIT 100`. A single article's tag names are read by primary key, not joined over all tags; a batch's, from one
  hash of all 200 tags for all its articles.
- **Reads that wait go out together.** When reads wait for a connection, those of a kind go out as one statement: the
  request's own SQL in a `LATERAL` subquery over arrays of the requests' parameters, up to 128, each row tagged with
  its request. Near the limit Postgres spends 6-13% less CPU per request.
- **Reads wait for company.** A read waits up to 15 ms for others before an idle connection takes the waiting reads,
  unless 2,048 wait first; reads that already waited that long for a busy connection go as soon as one is free. Without
  it the batches were what arrived while every connection was busy, a few of each kind. Near the limit Postgres spends
  another 9-11% less CPU per request at 10 ms, and every run passed at a load where 2 of 5 had without it; 15 ms, with
  rounds of up to 512, another 6.5%, the packed batches (below) paying with their size.
- **What a batch's requests have in common, read once.** The requests that wait together share what they read within
  the statement, and nothing outlives it (rule 5). Most requests for the global list ask for its first page: its
  batch walks each distinct page once for its ids (a batch of about 30 requests asks for 5 at most), then reads each
  distinct article once with its tags, favorites count and author; only `favorited` and `following` are the
  request's own, and the count runs once. Each distinct page once took a third of the global list's buffers off, and
  6% of all the statements' (the tag and author lists' pages and counts once per distinct filter too, each filter's
  name resolved to its id once; where most counts reach the cap of 1,000, as every tag's does, the count asks whether
  a 1,000th row exists rather than counting to it: the tag list's statement 11-15% less time). Postgres spends 90 µs
  per request in batches of 4 instead of 138, 54 in batches of 16 instead of 140 (pgbench, with the load's pages);
  under a saturating load, 6% less CPU per request (93.7 against 100 µs). The batch's rows are packed: a row per
  distinct article, then a row per request with its page's ids and, as arrays, those it favorited and the authors
  it follows, each from one index probe for its whole page; the server writes each article's JSON once and copies it
  into every page that has it, with that viewer's two flags. 44 µs per request in batches of 16, 23 in batches of 64
  (pgbench). The feed and the tag lists are packed the same way (the feed's `following` is true without a probe):
  near the limit Postgres spends 9.5% less CPU per request. The feed's count is capped at 1,000, and most viewers
  follow an author with that many articles: a batch checks the authors most followed among its viewers once, and a
  viewer who follows one of them counts 1,000 without walking 1,000 index entries (a feed batch 10% cheaper). Those
  authors also cut the page short: one of them alone has `limit + offset` articles at least as new as its
  `limit + offset`-th, so no older article can be on the page of a viewer who follows it, and each followed author's
  walk stops there (a feed batch of 16 another 16% cheaper, of 64 25%). The
  author and favorites lists are packed too, so every list goes the same way, and so are the comments: each distinct
  article's read once per batch (the hottest articles, the ones requests repeat, have the longest threads), each
  request's `following` one probe for its article's commenters: 14% fewer buffers for the comments. A batch names its articles' tags from
  one hash of the 200 tags rather than a probe per tag: 12% fewer buffers read under the load, 16-24% fewer in each
  list's batches. The tag list has no parameter: it runs once
  per batch, for every request in it (in a batch each request's own run cost 29 µs, its 200 rows; shared, the whole
  batch costs about 34), and its JSON is written once, by the batch's first request, the others copying its bytes
  (writing the 200 names into each response was 1.7% of the server's CPU).
- **A round's articles, read once whatever kind showed them.** A round's lists, feeds and article pages, when they
  are of two kinds or more, go out as one plan in two phases on its connection: first each kind's distinct pages and
  counts and the rows of its pages' articles (an article page's by its slug), each distinct page's ids as one array
  its requests share (a row per request and article, grouped back per request, cost the global list's statement 40%
  more time and the others 6-8%); then, once for the round, what those
  articles need whatever kind showed them: their tag ids and favorites counts, each distinct author's profile, the
  tags in name order (the server names and orders each article's tags), and the viewers' `favorited` and
  `following`, one index scan per viewer (the server groups the pairs by viewer and sends each viewer's as a slice of
  one array: grouped in SQL, by an aggregate per viewer, the statement took 12% longer for the same rows). Each
  article's JSON is put together once and copied into every response
  that shows it, with its viewer's two flags. The plan goes first in its round, so that Postgres runs the round's
  other statements while the server reads the first phase and sends the second (last, the backend waited for it, and
  at saturation p95 rose). With Postgres and the server at 3.8 of their 4 cores, 5-10% more requests a second than
  each kind's batch on its own, p95 377 ms against 481, 13% fewer buffers per request and 3-5.5% less of
  Postgres's CPU at the same speed; below saturation 6-11% fewer buffers, Postgres's CPU per request the same or
  less.
- **One queue of reads for the process.** Every event loop's reads wait in one queue for every read connection,
  not each loop's for its own: a batch holds every waiting read of its kind, not half of them. On two loops, as on
  the box, 40 reads per batched statement instead of 21, and Postgres spends 9% less CPU per request (49-50 µs
  against about 54 at the same speed); p95 at that load is 41 ms against 25-36, the rounds now filling to 512.
- **One round in flight per read connection.** An idle read connection takes the 2,048 oldest waiting reads, whatever
  their kind, each kind's batched, all in one flush, and nothing more until they are answered: 3-8% less CPU per
  request than 16 queries in flight per connection. Taking the oldest, rather than up to 32 of every kind, makes
  every kind wait alike: the two that arrive fastest (the article and the tags) otherwise fell behind under overload.
  Up to 2,048 since a round shares its articles across kinds: at saturation p95 289 and 282 ms against 645 and 344
  with 512, Postgres's CPU per request 4% less.
- **One read connection per CPU** (8 on the box), so that the backends pipelining keeps busy don't take turns on the
  CPUs: Postgres 5-13% less CPU per request than with four per CPU, the server 7% less.
- **Writes on a connection of their own, committed in groups.** Each event loop has a write connection with one
  transaction in flight; the writes that arrive meanwhile go out together, their statements and one Sync: one
  transaction, one commit, one WAL flush for all. Reads never wait behind a commit. Every response is written after
  its group's commit (rule 6), and a group that fails goes out again one write at a time, so that only the one at
  fault fails. p95 18-21 ms against 27-51 with the writes on the read connections, p99 36-47 against 71-108. A
  group's favorites, unfavorites, follows, unfollows and comments go as one statement per kind over arrays of their
  parameters, the group ordered by kind when no two of its writes are one client's.

**The server's own CPU**

- **Each event loop owns its client connections and its Postgres connections** (one loop per 4 CPUs: 2 on the box).
  A request is decoded and its response written on its loop's thread, and a connection, a client's or Postgres's, is
  only ever used on its own loop's. Queries are written into their connection's send buffer and flushed once per pass
  of the loop; replies come back in order and are read in place. The one thing the loops share is the queue of reads
  (above), behind a lock: a round taken by another loop's connection goes to that loop, which reads its replies and
  renders its responses, then hands each loop its responses as one task per pass.
- **Binary rows, straight into JSON.** Every column comes back in binary: numbers, booleans, timestamps (formatted from
  microseconds since 2000), `text[]` tag lists. Text is copied from the receive buffer into the response, scanned
  eight bytes at a time for a byte that needs escaping, and escaped only when it has one. What a round's requests
  share (each article's JSON, a batch's comments) is written into buffers kept from round to round, whatever their
  size: grown anew from 16 KB each round they cost 3% of the server's CPU at saturation in zeroing and copying.
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
| `conduit.pgRoundSize` | 2048 | with `pgDrain`: the oldest waiting reads a round takes, whatever their kind; 0: up to `batchSize` of every kind |
| `conduit.pgSharedReads` | true | every loop's reads wait in one queue for every read connection (false: each loop's for its own) |
| `conduit.pgPlan` | true | a round's lists, feeds and article pages, of two kinds or more, in two phases: what their articles need read once for the round (false: each kind's batch on its own) |
| `conduit.pgDepth` | 16 | without `pgDrain`: requests in flight per read connection; more wait in the queue |
| `conduit.batchSize` | 128 | the most waiting reads of a kind sent as one statement (1: none) |
| `conduit.pgGatherMicros` | 15000 | with `pgDrain`: how long the oldest waiting read waits for others before a free connection takes the waiting reads (unless a round's worth wait); 0: at once |
| `conduit.bcryptThreads` | CPUs / 2, at least 1 | bcrypt threads |
| `conduit.bcryptWaitMillis` | 400 | how long a hash waits for others to run four at a time |
| `conduit.bcryptNice` | 0 | the bcrypt threads' nice value (up to 19: they wait whenever Postgres or a loop has work) |
| `conduit.transport` | `io_uring` | or `epoll`; either falls back to NIO off Linux |
| `conduit.maxConnections` | the descriptors | connections held per loop before the longest-idle are closed; with none idle, the server stops accepting until one is |
| `conduit.idleTimeoutSeconds` | 75 | the spec asks for at least 65 |
| `conduit.requestDeadlineSeconds` | 30 | how long a request may take to arrive whole before it gets a 408 |
| `conduit.acceptsPerPass` | 1024 | new connections accepted per pass of the accepting loop |
| `conduit.listenBacklog` | 65535 | the listen backlog asked for (the kernel caps it at `net.core.somaxconn`) |
| `conduit.lagMonitor` | false | logs each loop's lag every 10 s |
| `conduit.stats` | false | logs each loop's queries every 10 s: how many waited, the batches |

## Results

Not yet run on the official box. On a local copy of it at half its size (Postgres and the server on 4 vCPUs, the
challenge's load generator on others), at 92,000 users on a fresh copy of the full seed, in three 1-minute runs: all
three passed, at 23,900-24,200 requests a second; 107-125 µs of CPU per request, the server's 46-52 and Postgres's
61-73; 2.6-3.0 of the 4 cores busy; p95 64-245 ms, p99 102-336 ms, no errors.
