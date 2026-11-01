# C# on raw epoll (xeonfx)

Front: direct

- Language: C# 14 on .NET 10 (SDK 10.0.402), compiled ahead of time with NativeAOT
- Postgres: its own wire-protocol client, no driver
- bcrypt: cost 10, `$2a$`, `$2b$` and `$2y$` hashes, on threads of its own

No web framework, no thread pool, and nothing allocated per request once warm. The box's 8 cores are shared with
Postgres, which spends most of them, so the design spends as little Postgres work and server CPU per request as it
can.

## How it runs

- **A few epoll loops, a quarter of the cores** (2 on 8 vCPUs), so Postgres keeps the rest. Each loop has its own
  listener on port 80 (SO_REUSEPORT spreads the connections) and its own clients. Sockets are called through libc
  directly; `recv` and `send` skip the GC transition.
- **Requests are parsed in place.** The method, path, query, token and body are slices of the receive buffer, and
  responses are written as bytes straight into one buffer per loop, head and body leaving in one `send`.
- **Rows become JSON with no objects.** Results come back in binary; each text column is copied into the response
  (escaped where JSON needs it) and timestamps are formatted from Postgres's microseconds.
- **The loops share their Postgres connections.** Every loop queues its reads and writes in one shared read queue and
  one write queue (a short lock each), and whichever loop has an idle connection runs them. The answer goes back to
  the loop holding the client through a lock-free inbox and an eventfd.

## Postgres

- **Reads run in batches, one statement per kind.** An idle read connection takes what waits in the read queue,
  up to 512 reads, once the oldest has waited 2 ms. Each kind of read in the batch (article, comments, profile,
  current user, login, tags, and each kind of list) is one statement whose parameters are arrays of the batch's
  distinct keys, `unnest(...) WITH ORDINALITY`, so requests in the same batch for the same slug, username, page
  or viewer share one row. Nothing is kept after its batch.
- **Then each article once.** A second round enriches every article the batch found, once, with its tag list,
  favorites count and author, and reads the signed-in viewers' favorited and following flags with one index scan
  per viewer. Both rounds run in one `REPEATABLE READ READ ONLY` transaction, so every answer sees one snapshot.
- **A failed batch goes again read by read.** If a statement fails, the batch rolls back and each read runs again in
  a batch of its own, so only the read that fails alone gets the error. A read whose connection drops runs once
  more elsewhere, then gets 503.
- **Writes are group-committed.** A writer sends the writes waiting from all loops as one transaction, so one WAL
  flush commits all of them. If one write fails, it gets its error only after it has run on committed data alone;
  the others go again. Deadlocks run again, up to 3 times. A group whose connection drops may have committed, so
  its writes get 503 and never run twice.
- **About one read connection per core and one writer**, 9 in all on 8 cores. Every statement is prepared once per
  connection and planned once (`plan_cache_mode=force_generic_plan`, JIT and parallel workers off).

## Settings

Measured on the contest box shape at 160,000 users, as constants in `Hub.cs` and `Passwords.cs`. Loops and read
connections follow the core count.

| Setting | On 8 cores | |
| --- | --- | --- |
| Epoll loops | cores / 4, so 2 | 3 and 4 cost more CPU per request |
| Read connections | cores, so 8 | 6 and 12 held fewer users |
| Group-commit connections | 1 | |
| Read batch window | 5 ms | beat 1 and 2 ms: larger batches cost Postgres less per request |
| bcrypt threads | 4 | 8 took CPU from Postgres |

## bcrypt

bcrypt never runs on a loop. Four threads each take up to four waiting hashes at once and run
them interleaved (Blowfish waits on memory, so four lanes cost little more than one), then hand each result back
to its loop through its inbox. The kernel shares CPU per runnable thread, so with too few threads logins
starve behind Postgres's backends on a full box. A thread holding a lone hash waits up to 50 ms for others to join it, and a hash
whose client has hung up is dropped and its connection closed. The queue is bounded, and past it a request gets a 503 at once. A login with an unknown
email still checks a dummy hash, so its timing doesn't show which emails exist.

## Files

`Program.cs` starts the loops. `Hub.cs` holds the shared queues. `Loop*.cs` hold the event loop, HTTP, routes,
read batches (`Loop.Batch.cs`, with `Batch.cs` and `KeySet.cs`), write groups and replies. `Pg.cs` and `Scram.cs` are the Postgres client, and `Sql.cs` holds the statements. `Body.cs`, `Query.cs`,
`Route.cs`, `Jwt.cs`, `Json.cs` and `Errors.cs` handle requests and responses. `Bcrypt*.cs`,
`BlowfishConstants.cs` and `Passwords.cs` are bcrypt, and `Native.cs` holds the libc calls.
