# Swift, io_uring, Postgres, and a batch planner

Front: direct

| | |
|---|---|
| Language | Swift 6.4.1 in Swift 6 language mode, no Foundation, stdlib linked statically |
| Framework | none. io_uring through liburing 2.15 |
| Driver | my own PostgreSQL wire client: SCRAM-SHA-256, extended protocol, pipelining, binary rows |
| bcrypt | my own C implementation with an x86-64 assembly kernel, cost 10, five hashes in lockstep |

The server has three kinds of threads, and none of them ever blocks on Postgres.

- **Reactors**, one per two CPUs, speak HTTP on io_uring. They parse requests, check the JWT on every request, validate
  bodies, and hand the rest to a lane. They share nothing but the lanes.
- **Planners**, three of them, own the Postgres connections. Each takes the requests gathering in its lanes and turns
  them into batches.
- **Hashing threads** run bcrypt at low priority, so a login never holds up a request that isn't one.

## Reads travel in batches

Requests wait in one of three lanes: fast (tags, the current user, profiles, login lookups), comments, and lists
(articles, list pages and feeds). When a lane has waited long enough and one of its connections is idle, the planner
takes everything in it and runs one statement per kind of read, with arrays of distinct keys. Forty readers of the same
article cost one row. Nothing outlives the batch, and no batch starts before its requests arrive, so every request
reads Postgres while it is being served.

Lists take two round trips. The first finds the ids, and the second reads each distinct article's tags and favorite
count once, each author once, and only those favorites and follows that the batch's viewers can see. Tags are read in
every batch that shows them. Rows are rendered to JSON once, and each response is put together from those pieces.

One planner across all reactors matters more than anything else here. Keeping a planner per reactor cost half as much
again in Postgres CPU per request, because each batch only saw a part of the requests.

## Writes share a commit

A write is one statement that finds its own target. Everything that gathers while one commit is on its way goes out
next as a single pipeline with one Sync, so it shares one transaction and one WAL flush. Each response waits for
`ReadyForQuery`. If a statement fails, Postgres rolls the group back, and each member retries alone, so one bad write
can't fail its neighbours. Text that Postgres would refuse never reaches a batch: the reactor checks for NUL and invalid
UTF-8 first.

## bcrypt

Logins are one request in a thousand, and at 54,000 requests a second they took a quarter of the box. That made bcrypt
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

C and assembly appear only where Swift can't go: liburing's macros, socket setup and the bcrypt kernel. At 54,000
requests a second the threads split the CPU clearly: about two cores for bcrypt, under one for the HTTP reactors, and a
third of a core for the planners.

## Where things live

| | |
|---|---|
| `Sources/Server/Ring.swift` | the reactors: rings, accepts, receives, sends |
| `Sources/Server/Conduit.swift` | routing and validation for the 19 endpoints |
| `Sources/Server/Planner.swift` | planner threads, Postgres I/O, what the threads share |
| `Sources/Server/Batch.swift` | lanes, the read planner, rows, responses |
| `Sources/Server/Writes.swift` | group commit, hashing jobs |
| `Sources/Server/Statements.swift` | every SQL statement |
| `Sources/Server/Postgres.swift` | startup, SCRAM, wire format |
| `Sources/CBcrypt` | bcrypt, its assembly kernel and the hashing threads |
