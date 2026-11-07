# Swift, io_uring, Postgres, and a shared read dispatcher

Front: direct

**This entry is a fork of [`swift-iouring-Tabonx`](../swift-iouring-Tabonx) (#207) by @Tabonx**, used under the
repository's MIT license. Nearly all of the code is theirs: the io_uring reactors, the Postgres wire client, the batch
planner and its SQL, group commit, and the bcrypt kernel. What this fork changes is how read batches get Postgres
connections, an idea that comes from theCatWisel's #154 and the work-conserving lanes in `zig-iouring-nick-potts`.
The sections after "What changed" are Tabonx's description, updated where the fork differs.

| | |
|---|---|
| Language | Swift 6.4.1 in Swift 6 language mode, no Foundation, stdlib linked statically |
| Framework | none. io_uring through liburing 2.15 |
| Driver | Tabonx's PostgreSQL wire client: SCRAM-SHA-256, extended protocol, pipelining, binary rows |
| bcrypt | Tabonx's C implementation with an x86-64 assembly kernel, cost 10, five hashes in lockstep |

## What changed

In Tabonx's entry, each lane owns its connections, and each lane-group has its own planner thread: fast and writes
(2 connections), comments (2), and lists (4). Lists hold articles, list pages and feeds together. When the lists lane
backs up, it can't use an idle comments connection, and an article page waits behind feed batches.

Here:

- **Feeds get a lane of their own.** The feed is the most expensive read per request, so article pages and list pages
  no longer wait behind it. There are four lanes: fast, comments, lists, feeds.
- **One read planner owns all eight read connections, and any connection serves any lane.** Each time a connection
  frees up, it goes to the ready lane whose oldest request has waited longest. A lane under its usual cap (2, 2, 3, 2)
  goes first, but a lane at its cap may still take a spare connection if it has the oldest request. At most seven read
  batches run at once, which leaves one core for the reactors and bcrypt.
- **Writes have their own planner thread** with their one connection, so the read planner's ticks never wait on
  commits.

Local comparison: an arm64 Docker VM with 12 CPUs, server and Postgres pinned to 8, the full seed, and the repo's
`loadgen` on the other 4. Users were 40,000 with think time ×0.05. These runs are not the benchmark box, and the load
generator shares the machine, so take only the direction from them:

| | req/s | p50 | p95 | p99 |
|---|--:|--:|--:|--:|
| swift-iouring-Tabonx, run 1 | 107,754 | 168 ms | 320 ms | 394 ms |
| this fork, run 1 | 116,470 | 149 ms | 250 ms | 313 ms |
| this fork, run 2 | 115,796 | 150 ms | 253 ms | 319 ms |
| swift-iouring-Tabonx, run 2 | 108,592 | 170 ms | 314 ms | 376 ms |

Article pages gain the most (p95 328 → 254 ms in run 2) because they no longer wait behind feeds. Comments give a
little back (187 → 221 ms), since they now share connections with the other lanes. Both servers had 0.16-0.17%
errors, all login timeouts. The ×0.05 think time puts about four times the benchmark's login rate per user onto
CPUs that are already full.

Both pass the conformance suite (197/197).

## Threads

The server has three kinds of threads, and none of them ever blocks on Postgres.

- **Reactors**, one per two CPUs, speak HTTP on io_uring. They parse requests, check the JWT on every request, validate
  bodies, and hand the rest to a lane. They share nothing but the lanes.
- **Planners**, two of them. The read planner owns every read connection and dispatches the lanes' batches onto them.
  The write planner owns the one write connection.
- **Hashing threads** run bcrypt at low priority, so a login never holds up a request that isn't one.

## Reads travel in batches

Requests wait in one of four lanes: fast (tags, the current user, profiles, login lookups), comments, lists (articles
and list pages) and feeds. When a lane has waited long enough and a connection is free, the planner takes everything
in it and runs one statement per kind of read, with arrays of distinct keys. Forty readers of the same article cost
one row. Nothing outlives the batch, and no batch starts before its requests arrive, so every request reads Postgres
while it is being served.

Lists take two round trips. The first finds the ids, and the second reads each distinct article's tags and favorite
count once, each author once, and only those favorites and follows that the batch's viewers can see. Tags are read in
every batch that shows them. Rows are rendered to JSON once, and each response is put together from those pieces.

Tabonx found that one planner across all reactors matters more than anything else here. Keeping a planner per reactor
cost half as much again in Postgres CPU per request, because each batch only saw a part of the requests.

## Writes share a commit

A write is one statement that finds its own target. Everything that gathers while one commit is on its way goes out
next as a single pipeline with one Sync, so it shares one transaction and one WAL flush. Each response waits for
`ReadyForQuery`. If a statement fails, Postgres rolls the group back, and each member retries alone, so one bad write
can't fail its neighbours. Text that Postgres would refuse never reaches a batch: the reactor checks for NUL and invalid
UTF-8 first.

## bcrypt

Logins are one request in a thousand, and in Tabonx's measurements at 54,000 requests a second they took a quarter of the box. That made bcrypt
the largest cost outside Postgres, ahead of all the HTTP work put together.

A hash spends its time on table lookups in one long chain, so it leaves a modern core mostly idle. Five hashes
interleaved round by round on one thread keep its load ports busy, and a pass costs the same with one job or five, so
jobs wait up to 200 ms for company. In C that took 25.8 ms per hash, because a compiler can't keep ten halves of five
Blowfish blocks in registers and spills them. `Sources/CBcrypt/expand0.S` keeps them all there, spends 11 instructions on
a half round, and takes 20.1 ms. The rest of the hash stays in C, and CPUs without BMI2 run all of it there.

## Connections and survival

Accepted sockets are io_uring direct descriptors in a ring's own table, so the process's descriptor limit doesn't apply
to them, and a reactor adds rings as they fill. An open connection that isn't doing anything costs a small fixed slot
and no buffers. There is at most one request in flight per connection, so memory under overload is bounded by the
number of connections. When Postgres connections die, their requests get a 500 and the planners reconnect once a second.

Reactors and planners run under `SCHED_BATCH` at nice 5, so they let Postgres run first and find fuller batches when
they get the CPU back. Postgres session settings are `plan_cache_mode=force_generic_plan`, `jit=off`, no parallel
workers, no Memoize and a larger `work_mem`.

## The Swift part

There is no `String` on a request's way through. A request is a set of `ByteView`s pointing into the receive buffer,
and output goes into a `~Copyable` `OutBuffer` that the compiler won't let anyone copy. Postgres rows are decoded in
place from their binary form. The threads are plain pthreads started through a small C shim, because Swift's concurrency
runtime would be a second scheduler on top of this one. A lane is a short locked queue that the reactors fill and one
planner drains.

C and assembly appear only where Swift can't go: liburing's macros, socket setup and the bcrypt kernel. In Tabonx's
measurements at 54,000 requests a second the threads split the CPU clearly: about two cores for bcrypt, under one for the HTTP reactors, and a
third of a core for the planners.

## Where things live

| | |
|---|---|
| `Sources/Server/Ring.swift` | the reactors: rings, accepts, receives, sends |
| `Sources/Server/Conduit.swift` | routing and validation for the 19 endpoints |
| `Sources/Server/Planner.swift` | planner threads, Postgres I/O, what the threads share |
| `Sources/Server/Batch.swift` | lanes, the read dispatcher (`dispatch`), the read planner, rows, responses |
| `Sources/Server/Writes.swift` | group commit, hashing jobs |
| `Sources/Server/Statements.swift` | every SQL statement |
| `Sources/Server/Postgres.swift` | startup, SCRAM, wire format |
| `Sources/CBcrypt` | bcrypt, its assembly kernel and the hashing threads |
